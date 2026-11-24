#!/usr/bin/env python3
"""Convert the supplied OALECD10 Simplified MDX to LexiWatch's SQLite format.

The converter reads local text records. It does not execute dictionary HTML
or JavaScript, or fetch linked resources.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from functools import cache
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from tempfile import TemporaryDirectory

from lxml import etree, html
from mdict_utils.reader import MDX
from build_extended_dictionary import (
    SCHEMA_VERSION,
    CHINESE_MEANING,
    STRICT_ALIAS,
    STRICT_HEADWORD,
    TOLERANT_ALIAS,
    TOLERANT_HEADWORD,
    contains_han,
    normalize_lookup_key,
    normalize_tolerant_lookup_key,
)

SOURCE = "牛津高阶英汉双解 · 第10版"
LINK = "@@@LINK="


def has_class(value: str) -> str:
    return f"contains(concat(' ',normalize-space(@class),' '), ' {value} ')"


ENTRY = etree.XPath(f".//*[{has_class('t-oalecd10')} and @data-hkoup-entry]")
PHRASE_GROUP = f"{has_class('t-pv-g')} or {has_class('t-idm-g')}"
HOMOGRAPH_MARKER = f"{has_class('t-hm')} or {has_class('t-homonym')}"
HEADWORD_TEXT = etree.XPath(f".//text()[not(ancestor::*[{HOMOGRAPH_MARKER}])]")
PHRASES = etree.XPath(f".//*[{PHRASE_GROUP}]")
DEFINITION = etree.XPath(f".//*[{has_class('t-def')}]")
MAIN_DEFINITION = etree.XPath(
    f".//*[{has_class('t-def')} and not(ancestor::*[{PHRASE_GROUP}])]"
)
SENSE = etree.XPath(f"ancestor::*[{has_class('t-sn-g')}][1]")
EXAMPLE = etree.XPath(f"ancestor::*[{has_class('t-x')}][1]")
LINK_FRAGMENT = re.compile(r"^HKOUPLINK[0-9a-f]+", re.ASCII)
SLOT = r"(?:sb|sth|somebody|something|(?:your|him|her|it|one|them|my)self)"
PLACEHOLDER = re.compile(rf"(?<![\w’']){SLOT}(?:[./]{SLOT})*\.?(?![\w’'])", re.I)
PARENTHETICAL = re.compile(r"\([^()]*\)|（[^（）]*）")
HAN_SEGMENT = re.compile(r"[\u3400-\u9fff]{1,20}")
PHRASE_WORD = re.compile(r"[A-Za-z]+(?:[’'-][A-Za-z]+)*")
PHRASE_MARKS = str.maketrans({"ˈ": None, "ˌ": None, "↔": " "})


@cache
def class_nodes(class_name: str) -> etree.XPath:
    return etree.XPath(f".//*[{has_class(class_name)}]")


def first_class(node, class_name: str):
    return next(iter(class_nodes(class_name)(node)), None)


def text_of(node) -> str:
    if node is None:
        return ""
    return " ".join("".join(node.itertext()).replace("\u00ad", "").split())


def headword_forms(node) -> tuple[str, str | None]:
    if node is None:
        return "", None

    def spelling(text: str) -> str:
        return " ".join(text.translate(str.maketrans("", "", "·‧\u00ad")).split())

    headword = spelling("".join(HEADWORD_TEXT(node)))
    raw = spelling(text_of(node))
    return headword, raw if headword != raw else None


def phrase_keys(title: str) -> set[str]:
    skeleton = phrase_skeleton(title)
    return {value for value in (title, skeleton) if value and " " in value}


def phrase_skeleton(title: str) -> str:
    return " ".join(PLACEHOLDER.sub("", PARENTHETICAL.sub("", title)).split())


def chinese_keys(chinese: str):
    clean = PARENTHETICAL.sub("", chinese)
    for part in re.split(r"[；;、，,／/。]", clean):
        value = part.strip()
        if HAN_SEGMENT.fullmatch(value):
            yield value


def example_fields(example) -> dict:
    if example is None:
        return {}
    return {
        field: value
        for field, css in (("example", "t-eng"), ("exampleChinese", "t-chn"))
        if (value := text_of(first_class(example, css)))
    }


def parse_pronunciations(entry, part_of_speech: str):
    block = first_class(entry, "t-pron-gs")
    if block is None:
        return []
    groups = class_nodes("t-pron-g-blk")(block) or [block]
    pronunciations = []
    for group in groups:
        region = None
        if any(first_class(group, name) is not None for name in ("t-brelabel", "t-audio-gb")):
            region = "uk"
        elif any(first_class(group, name) is not None for name in ("t-namelabel", "t-audio-us")):
            region = "us"
        for field in class_nodes("t-phon")(group):
            if ipa := text_of(field):
                item = {"ipa": ipa, "partOfSpeech": part_of_speech}
                if region:
                    item["region"] = region
                if item not in pronunciations:
                    pronunciations.append(item)
    return pronunciations


def sense_collocations(sense):
    seen = set()
    for tagged in class_nodes("t-cl")(sense):
        if next(iter(SENSE(tagged)), None) is not sense:
            continue
        title = text_of(tagged)
        example = next(iter(EXAMPLE(tagged)), None)
        if example is None or len(PHRASE_WORD.findall(title)) < 2:
            continue
        fields = example_fields(example)
        if not fields.get("example"):
            continue
        key = (title, fields["example"], fields.get("exampleChinese"))
        if key not in seen:
            seen.add(key)
            yield {"text": title, "kind": "fixedPhrase", "chinese": "", "priority": 10, **fields}


def parse_meanings(definitions, part_of_speech: str, headword: str):
    meanings = []
    for definition in definitions:
        english = text_of(first_class(definition, "t-eng"))
        chinese = text_of(first_class(definition, "t-chn"))
        if not english and not chinese:
            continue
        sense = next(iter(SENSE(definition)), definition.getparent())
        example = first_class(sense, "t-x")
        collocations = list(dict.fromkeys(
            value for pattern in class_nodes("t-cf")(sense)
            if next(iter(SENSE(pattern)), None) is sense
            and (value := text_of(pattern).replace("~", headword))
            and value != headword
        ))
        meaning = {"partOfSpeech": part_of_speech, "chinese": chinese,
                   "collocations": collocations}
        if first_class(sense, "t-def") is definition:
            details = list(sense_collocations(sense))
            if details:
                meaning["collocationDetails"] = details
        if english:
            meaning["englishDefinition"] = english
        meaning.update(example_fields(example))
        meanings.append(meaning)
    return meanings


def lexical_collocations(definitions, headword: str):
    for definition in definitions:
        sense = next(iter(SENSE(definition)), None)
        if sense is None or first_class(sense, "t-def") is not definition:
            continue
        for collocation in sense_collocations(sense):
            fields = {key: collocation[key] for key in ("example", "exampleChinese") if key in collocation}
            yield collocation["text"], fields, {
                "partOfSpeech": f"搭配 · {headword} 的相关义项",
                "chinese": text_of(first_class(definition, "t-chn")),
                "englishDefinition": text_of(first_class(definition, "t-eng")),
                "collocations": [],
                **fields,
            }


def collocation_keys(title: str):
    if all(PHRASE_WORD.fullmatch(word) for word in title.split()):
        yield title
        return
    prefix, _, alternatives = title.rpartition(" ")
    if prefix and all(PHRASE_WORD.fullmatch(word) for word in prefix.split()):
        words = alternatives.split("/")
        if 1 < len(words) <= 4 and all(PHRASE_WORD.fullmatch(word) for word in words):
            for word in words:
                yield f"{prefix} {word}"


def pattern_entries(meanings, headword: str):
    for meaning in meanings:
        for pattern in meaning["collocations"]:
            text = phrase_skeleton(pattern.partition(",")[0])
            words = text.split()
            if len(words) < 2 or not all(PHRASE_WORD.fullmatch(word) for word in words):
                continue
            result = {
                "partOfSpeech": f"句型 · {headword} 的相关义项",
                "chinese": meaning["chinese"],
                "englishDefinition": meaning.get("englishDefinition", ""),
                "collocations": [pattern],
            }
            if text.casefold() in meaning.get("example", "").casefold():
                result.update({
                    key: meaning[key] for key in ("example", "exampleChinese") if key in meaning
                })
            yield text, result


def parse_entries(record: str):
    if "data-hkoup-entry" not in record or 't-oalecd10' not in record:
        return
    document = html.fromstring(record)
    for entry in ENTRY(document):
        headword, legacy_headword = headword_forms(first_class(entry, "t-h"))
        if not headword or not any(letter.isalpha() for letter in headword):
            continue
        part_of_speech = text_of(first_class(entry, "t-pos"))
        pronunciations = parse_pronunciations(entry, part_of_speech)
        definitions = MAIN_DEFINITION(entry)
        meanings = parse_meanings(definitions, part_of_speech, headword)
        related = []
        phrases = []
        for phrase in PHRASES(entry):
            is_verb = "t-pv-g" in phrase.get("class", "").split()
            raw_title = text_of(first_class(phrase, "t-pv" if is_verb else "t-idm"))
            title = " ".join(raw_title.translate(PHRASE_MARKS).split())
            if not title:
                continue
            phrase_meanings = parse_meanings(DEFINITION(phrase), "短语动词" if is_verb else "习语", title)
            if not phrase_meanings:
                continue
            first = phrase_meanings[0]
            related.append({
                "text": title,
                "kind": "phrasalVerb" if is_verb else "fixedPhrase",
                "chinese": first["chinese"],
                "partOfSpeech": part_of_speech,
                "priority": 0 if is_verb else 20,
                **{key: first[key] for key in ("example", "exampleChinese") if key in first},
            })
            aliases = phrase_keys(title)
            if is_verb:
                for css in ("t-pv", "t-v"):
                    for variant in class_nodes(css)(phrase):
                        if not SENSE(variant):
                            variant_title = " ".join(text_of(variant).translate(PHRASE_MARKS).split())
                            aliases.update(phrase_keys(variant_title))
                for meaning in phrase_meanings:
                    for pattern in meaning["collocations"]:
                        if pattern.startswith(title + " "):
                            aliases.update(phrase_keys(pattern))
            phrases.append((title, [], phrase_meanings, aliases, [], [], 25, None))
        examples = list(lexical_collocations(definitions, headword))
        rank = 0 if first_class(entry, "t-hkey") is not None else 50
        if meanings:
            yield headword, pronunciations, meanings, None, related, examples, rank, legacy_headword
        yield from phrases


def read_entries(mdx_path: Path):
    mdx = MDX(str(mdx_path))
    entries = {}
    keys_to_groups = defaultdict(set)
    links = defaultdict(set)
    defined_phrases = set()
    study_entries = {}
    reverse_ranks = {}
    homographs = defaultdict(list)
    for key_bytes, record_bytes in mdx.items():
        key = key_bytes.decode("utf-8").strip()
        if record_bytes.startswith(LINK.encode()):
            link = record_bytes.decode("utf-8")[len(LINK):].strip("\x00\r\n ")
            # Resolve the repeated headword / inflection redirect keys without
            # needing the HTML links or anchor tags at lookup time.
            internal_target = LINK_FRAGMENT.match(link)
            if internal_target:
                link = internal_target.group()
            links[key].add(link)
            continue
        for headword, pronunciations, meanings, aliases, related, examples, rank, legacy_headword in parse_entries(
            record_bytes.decode("utf-8").strip("\x00")
        ):
            group = headword
            payload = entries.setdefault(group, {
                "id": "oxford-10:" + headword, "headword": headword,
                "source": SOURCE, "priority": 0, "meanings": [], "relatedExpressions": [],
            })
            if legacy_headword:
                previous = payload.setdefault("aliases", [])
                if legacy_headword not in previous:
                    previous.append(legacy_headword)
                keys_to_groups[legacy_headword].add(group)
                index = legacy_headword.removeprefix(headword).strip()
                if index.isdecimal():
                    homographs[group].append((int(index), meanings, pronunciations))
            if pronunciations:
                payload.setdefault("pronunciation", " · ".join(dict.fromkeys(item["ipa"] for item in pronunciations)))
                accumulated = payload.setdefault("regionalPronunciations", [])
                for pronunciation in pronunciations:
                    if pronunciation not in accumulated:
                        accumulated.append(pronunciation)
            for meaning in meanings:
                if meaning not in payload["meanings"]:
                    payload["meanings"].append(meaning)
            existing = {(item["kind"], item["text"].casefold(), item["partOfSpeech"]) for item in payload["relatedExpressions"]}
            for item in related:
                marker = (item["kind"], item["text"].casefold(), item["partOfSpeech"])
                if marker not in existing:
                    payload["relatedExpressions"].append(item)
                    existing.add(marker)
            reverse_ranks[group] = min(rank, reverse_ranks.get(group, rank))
            if aliases is None:
                keys_to_groups[key].add(group)
            else:
                for spelling in aliases | {headword}:
                    defined_phrases.add(normalize_lookup_key(spelling))
                    keys_to_groups[spelling].add(group)
            for title, _, meaning in examples:
                for spelling in collocation_keys(title):
                    normalized = normalize_lookup_key(spelling)
                    study_entries.setdefault(normalized, (spelling, meaning))
            for spelling, meaning in pattern_entries(meanings, headword):
                normalized = normalize_lookup_key(spelling)
                study_entries.setdefault(normalized, (spelling, meaning))
    # MDX internal keys are hashes. Oxford's tagged ordinal supplies the
    # original sense order when multiple records share the display spelling.
    for group, records in homographs.items():
        records.sort(key=lambda record: record[0])
        payload = entries[group]
        for field, index in (("meanings", 1), ("regionalPronunciations", 2)):
            ordered = []
            for record in records:
                for item in record[index]:
                    if item not in ordered:
                        ordered.append(item)
            if ordered:
                payload[field] = ordered + [item for item in payload.get(field, []) if item not in ordered]
        if primary := next((record[2] for record in records if record[2]), None):
            payload["pronunciation"] = " · ".join(dict.fromkeys(item["ipa"] for item in primary))

    # An example highlight is a presentation candidate only if Oxford also
    # defines that expression. Generated study entries do not qualify.
    authored_phrases = {
        normalize_lookup_key(headword): payload["meanings"][0]["chinese"]
        for headword, payload in entries.items()
        if " " in headword and payload["meanings"][0]["chinese"]
    }
    for payload in entries.values():
        for meaning in payload["meanings"]:
            for detail in meaning.get("collocationDetails", []):
                detail["chinese"] = authored_phrases.get(normalize_lookup_key(detail["text"]), "")

    occupied = {normalize_lookup_key(headword) for headword in entries} | defined_phrases
    for normalized, (headword, meaning) in study_entries.items():
        if normalized in occupied:
            continue
        entries[headword] = {
            "id": "oxford-10:" + headword, "headword": headword,
            "source": SOURCE + " · 词条用法", "priority": 0, "meanings": [meaning],
        }
        defined_phrases.add(normalized)
        keys_to_groups[headword].add(headword)
    for alias, targets in links.items():
        if normalize_lookup_key(alias) in defined_phrases:
            continue
        for target in targets:
            keys_to_groups[alias].update(keys_to_groups.get(target, ()))
    return entries, keys_to_groups, reverse_ranks


def write_database(mdx_path: Path, destination: Path):
    entries, keys_to_groups, reverse_ranks = read_entries(mdx_path)
    if len(entries) < 30_000:
        raise ValueError(f"Only {len(entries):,} headwords parsed. Check the MDX edition and structure.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=destination.parent) as staging:
        stage = Path(staging) / destination.name
        with sqlite3.connect(stage) as db:
            db.executescript(f"""
                PRAGMA user_version = {SCHEMA_VERSION};
                PRAGMA application_id = 0x4C585754;
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE entries (
                    entry_id INTEGER PRIMARY KEY, headword TEXT NOT NULL UNIQUE,
                    normalized_headword TEXT NOT NULL, priority INTEGER NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX entries_normalized_headword ON entries(normalized_headword, priority);
                CREATE TABLE lookups (
                    lookup_key TEXT NOT NULL, entry_id INTEGER NOT NULL, kind INTEGER NOT NULL,
                    rank INTEGER NOT NULL, PRIMARY KEY(lookup_key, entry_id, kind)
                ) WITHOUT ROWID;
                CREATE INDEX lookups_key_rank ON lookups(lookup_key, kind, rank, entry_id);
            """)
            ids = {}
            for entry_id, (headword, payload) in enumerate(sorted(entries.items()), 1):
                ids[headword] = entry_id
                db.execute("INSERT INTO entries VALUES (?, ?, ?, ?, ?)", (
                    entry_id, headword, normalize_lookup_key(headword), 0,
                    json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(),
                ))
                keys_to_groups[headword].add(headword)
            sql = "INSERT OR IGNORE INTO lookups VALUES (?, ?, ?, ?)"
            for key, groups in sorted(keys_to_groups.items()):
                if key.startswith((":", "HKOUPLINK")) or contains_han(key):
                    continue
                strict = normalize_lookup_key(key)
                if not strict:
                    continue
                tolerant = normalize_tolerant_lookup_key(key)
                for group in sorted(groups):
                    exact = strict == normalize_lookup_key(group)
                    db.execute(sql, (strict, ids[group], STRICT_HEADWORD if exact else STRICT_ALIAS, 0))
                    if tolerant != strict:
                        db.execute(sql, (tolerant, ids[group], TOLERANT_HEADWORD if exact else TOLERANT_ALIAS, 0))
            for group, rank in reverse_ranks.items():
                keys = {}
                for position, meaning in enumerate(entries[group]["meanings"]):
                    for key in chinese_keys(meaning["chinese"]):
                        keys.setdefault(key, rank + position * 4)
                db.executemany(sql, (
                    (key, ids[group], CHINESE_MEANING, key_rank) for key, key_rank in keys.items()
                ))
            with mdx_path.open("rb") as source:
                checksum = hashlib.file_digest(source, "sha256").hexdigest()
            db.executemany("INSERT INTO metadata VALUES (?, ?)", [
                ("source", SOURCE), ("source_sha256", checksum),
                ("headwords", str(len(entries))),
            ])
            lookups = db.execute("SELECT COUNT(*) FROM lookups").fetchone()[0]
            if db.execute("PRAGMA integrity_check").fetchone() != ("ok",):
                raise ValueError("Generated SQLite failed integrity check")
        stage.replace(destination)
    print(json.dumps({"headwords": len(entries), "lookups": lookups,
                      "source_sha256": checksum, "bytes": destination.stat().st_size}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mdx", type=Path)
    parser.add_argument("sqlite", type=Path)
    arguments = parser.parse_args()
    write_database(arguments.mdx, arguments.sqlite)
