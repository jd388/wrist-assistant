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
PHRASES = etree.XPath(f".//*[{PHRASE_GROUP}]")
DEFINITION = etree.XPath(f".//*[{has_class('t-def')}]")
MAIN_DEFINITION = etree.XPath(
    f".//*[{has_class('t-def')} and not(ancestor::*[{PHRASE_GROUP}])]"
)
SENSE = etree.XPath(f"ancestor::*[{has_class('t-sn-g')}][1]")
LINK_FRAGMENT = re.compile(r"^HKOUPLINK[0-9a-f]+", re.ASCII)
PLACEHOLDER = re.compile(r"(?<!\w)(?:sb|sth|somebody|something)(?:[./](?:sb|sth))?\.?(?!\w)")
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


def parse_meanings(definitions, part_of_speech: str):
    meanings = []
    for definition in definitions:
        english = text_of(first_class(definition, "t-eng"))
        chinese = text_of(first_class(definition, "t-chn"))
        if not english and not chinese:
            continue
        sense = next(iter(SENSE(definition)), definition.getparent())
        example = first_class(sense, "t-x")
        collocations = list(dict.fromkeys(filter(None, (
            text_of(pattern) for pattern in class_nodes("t-exp")(sense)
        ))))
        meaning = {"partOfSpeech": part_of_speech, "chinese": chinese,
                   "collocations": collocations}
        if english:
            meaning["englishDefinition"] = english
        if example is not None:
            for field, css in (("example", "t-eng"), ("exampleChinese", "t-chn")):
                value = text_of(first_class(example, css))
                if value:
                    meaning[field] = value
        meanings.append(meaning)
    return meanings


def parse_entries(record: str):
    if "data-hkoup-entry" not in record or 't-oalecd10' not in record:
        return
    document = html.fromstring(record)
    for entry in ENTRY(document):
        headword = text_of(first_class(entry, "t-h")).replace("·", "").replace("‧", "")
        if not headword or not any(letter.isalpha() for letter in headword):
            continue
        part_of_speech = text_of(first_class(entry, "t-pos"))
        pronunciations = []
        pronunciation_block = first_class(entry, "t-pron-gs")
        if pronunciation_block is not None:
            pronunciations = list(dict.fromkeys(filter(None, (
                text_of(field) for field in class_nodes("t-phon")(pronunciation_block)
            ))))
        meanings = parse_meanings(MAIN_DEFINITION(entry), part_of_speech)
        if meanings:
            yield headword, " · ".join(pronunciations), meanings, None
        for phrase in PHRASES(entry):
            is_verb = "t-pv-g" in phrase.get("class", "").split()
            raw_title = text_of(first_class(phrase, "t-pv" if is_verb else "t-idm"))
            title = " ".join(raw_title.translate(PHRASE_MARKS).split())
            if not title:
                continue
            meanings = parse_meanings(DEFINITION(phrase), "短语动词" if is_verb else "习语")
            if meanings:
                plain_phrase = " ".join(PLACEHOLDER.sub("", title).split())
                yield title, "", meanings, plain_phrase if " " in plain_phrase else title


def read_entries(mdx_path: Path):
    mdx = MDX(str(mdx_path))
    entries = {}
    keys_to_groups = defaultdict(set)
    links = defaultdict(set)
    phrase_keys = defaultdict(set)
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
        for headword, pronunciation, meanings, plain_phrase in parse_entries(
            record_bytes.decode("utf-8").strip("\x00")
        ):
            group = headword
            payload = entries.setdefault(group, {
                "id": "oxford-10:" + headword, "headword": headword,
                "source": SOURCE, "priority": 0, "meanings": [],
            })
            if pronunciation and "pronunciation" not in payload:
                payload["pronunciation"] = pronunciation
            for meaning in meanings:
                if meaning not in payload["meanings"]:
                    payload["meanings"].append(meaning)
            if plain_phrase is None:
                keys_to_groups[key].add(group)
            else:
                for spelling in (headword, plain_phrase):
                    phrase_keys[normalize_lookup_key(spelling)].add(group)
                    keys_to_groups[spelling].add(group)
    for alias, targets in links.items():
        if normalize_lookup_key(alias) in phrase_keys:
            continue
        for target in targets:
            keys_to_groups[alias].update(keys_to_groups.get(target, ()))
    return entries, keys_to_groups


def write_database(mdx_path: Path, destination: Path):
    entries, keys_to_groups = read_entries(mdx_path)
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
