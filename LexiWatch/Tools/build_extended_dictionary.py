#!/usr/bin/env python3
"""Build a lazy SQLite extension for LexiWatch's 30k core dictionary."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import sqlite3
import unicodedata
from collections import Counter
from pathlib import Path

import build_offline_dictionary as base


SCHEMA_VERSION = 2
ESDB_COMMIT = "1e5b7d3a72f47a71da5d28686c1dd4b397178485"

STRICT_HEADWORD = 0
STRICT_ALIAS = 1
CHINESE_MEANING = 2
TOLERANT_HEADWORD = 3
TOLERANT_ALIAS = 4


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def contains_han(value: str) -> bool:
    return any("\u3400" <= character <= "\u9fff" for character in value)


def normalize_lookup_key(value: str) -> str:
    """Build the primary key while preserving meaningful English hyphens."""

    folded = "".join(
        character
        for character in unicodedata.normalize("NFKD", value)
        if unicodedata.category(character) != "Mn"
    ).casefold().strip()
    if contains_han(folded):
        return "".join(
            character
            for character in folded
            if not unicodedata.category(character).startswith(("P", "S", "Z", "C"))
        )

    pieces: list[str] = []
    pending_space = False
    for character in folded:
        category = unicodedata.category(character)
        if character.isspace():
            pending_space = True
            continue
        if pending_space and pieces:
            pieces.append(" ")
        if category == "Pd":
            character = "-"
        pieces.append(character)
        pending_space = False
    return "".join(pieces).strip()


def normalize_tolerant_lookup_key(value: str) -> str:
    """Build a secondary phrase key where dashes tolerate whitespace input."""

    strict = normalize_lookup_key(value)
    if contains_han(strict):
        return strict
    return " ".join(strict.replace("-", " ").split())


def load_coverage(path: Path) -> dict[str, list[str]]:
    coverage: dict[str, list[str]] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        values = [value.strip() for value in raw_line.split("\t") if value.strip()]
        if values:
            coverage[values[0].casefold()] = values[1:]
    return coverage


def load_core_words(path: Path) -> set[str]:
    entries = json.loads(path.read_text(encoding="utf-8"))
    return {
        str(entry["headword"]).casefold()
        for entry in entries
        if isinstance(entry, dict) and entry.get("headword")
    }


def load_selected_rows(
    csv_path: Path,
    coverage: dict[str, list[str]],
    core_words: set[str],
) -> tuple[list[dict[str, str]], dict[str, int]]:
    selected: dict[str, dict[str, str]] = {}
    audit: Counter[str] = Counter()
    with csv_path.open(encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            word = row["word"].strip()
            key = word.casefold()
            if key not in coverage or key in core_words:
                continue
            audit["covered_source_rows"] += 1
            # The ESDB manifest contains lowercase non-abbreviation lemmas.
            # A case-folded join must never substitute an uppercase ECDICT
            # acronym/proper name (RAD, KI, Demi) for that lowercase lemma.
            if word != key:
                audit["excluded_case_mismatch_rows"] += 1
                continue
            if base.WORD_PATTERN.fullmatch(word) is None:
                audit["excluded_invalid_headword_rows"] += 1
                continue
            meanings = base.structured_meanings(row)
            if not meanings:
                if base.NETWORK_LABEL.search(row.get("translation", "")):
                    audit["excluded_network_only_rows"] += 1
                else:
                    audit["excluded_non_substantive_rows"] += 1
                continue
            if base.NETWORK_LABEL.search(row.get("translation", "")):
                audit["retained_after_network_sense_removal"] += 1
            previous = selected.get(key)
            if previous is None or base.rank(row) < base.rank(previous):
                selected[key] = row
    audit["selected_rows"] = len(selected)
    return sorted(selected.values(), key=base.rank), dict(audit)


def entry_payload(
    row: dict[str, str],
    priority: int,
    coverage_forms: list[str],
) -> dict[str, object]:
    entry = base.convert(row, priority, [])
    headword = str(entry["headword"])
    aliases = [
        str(alias)
        for alias in entry.get("aliases", [])
        if contains_han(str(alias)) or str(alias) == str(alias).casefold()
    ]
    for form in coverage_forms:
        if (
            form == form.casefold()
            and form.casefold() != headword.casefold()
            and form not in aliases
        ):
            aliases.append(form)
    entry["aliases"] = aliases[:24]
    existing_level = str(entry.get("level") or "").strip()
    entry["level"] = f"{existing_level} ESDB70".strip()
    return entry


def build_database(
    coverage_path: Path,
    csv_path: Path,
    core_dictionary: Path,
    output: Path,
) -> dict[str, object]:
    coverage = load_coverage(coverage_path)
    core_words = load_core_words(core_dictionary)
    selected_rows, selection_audit = load_selected_rows(
        csv_path,
        coverage,
        core_words,
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    connection = sqlite3.connect(output)
    try:
        connection.executescript(
            f"""
            PRAGMA page_size = 4096;
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = MEMORY;
            PRAGMA application_id = 0x4C585754;
            PRAGMA user_version = {SCHEMA_VERSION};

            CREATE TABLE metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE entries (
                entry_id INTEGER PRIMARY KEY,
                headword TEXT NOT NULL COLLATE BINARY UNIQUE,
                normalized_headword TEXT NOT NULL,
                priority INTEGER NOT NULL,
                payload BLOB NOT NULL
            );

            CREATE INDEX entries_normalized_headword
                ON entries(normalized_headword, priority);

            CREATE TABLE lookups (
                lookup_key TEXT NOT NULL,
                entry_id INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                rank INTEGER NOT NULL,
                PRIMARY KEY (lookup_key, entry_id, kind)
            ) WITHOUT ROWID;

            CREATE INDEX lookups_key_rank
                ON lookups(lookup_key, kind, rank, entry_id);
            """
        )

        lookup_rows = 0
        for index, row in enumerate(selected_rows):
            key = row["word"].strip().casefold()
            priority = 30_000 + index
            entry = entry_payload(row, priority, coverage.get(key, []))
            payload = json.dumps(
                entry,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            cursor = connection.execute(
                """
                INSERT INTO entries(headword, normalized_headword, priority, payload)
                VALUES (?, ?, ?, ?)
                """,
                (
                    entry["headword"],
                    normalize_lookup_key(str(entry["headword"])),
                    priority,
                    payload,
                ),
            )
            entry_id = int(cursor.lastrowid)

            best_lookup: dict[tuple[str, int], int] = {}

            def add_lookup(raw_value: object, kind: int, rank: int) -> None:
                value = normalize_lookup_key(str(raw_value))
                if not value:
                    return
                lookup_key = (value, kind)
                best_lookup[lookup_key] = min(best_lookup.get(lookup_key, rank), rank)

            def add_english_lookup(
                raw_value: object,
                strict_kind: int,
                tolerant_kind: int,
                rank: int,
            ) -> None:
                add_lookup(raw_value, strict_kind, rank)
                tolerant = normalize_tolerant_lookup_key(str(raw_value))
                strict = normalize_lookup_key(str(raw_value))
                if tolerant and tolerant != strict:
                    lookup_key = (tolerant, tolerant_kind)
                    best_lookup[lookup_key] = min(
                        best_lookup.get(lookup_key, rank),
                        rank,
                    )

            add_english_lookup(
                entry["headword"],
                STRICT_HEADWORD,
                TOLERANT_HEADWORD,
                priority,
            )
            for alias_index, alias in enumerate(entry.get("aliases", [])):
                if contains_han(str(alias)):
                    add_lookup(alias, CHINESE_MEANING, priority + alias_index)
                else:
                    add_english_lookup(
                        alias,
                        STRICT_ALIAS,
                        TOLERANT_ALIAS,
                        priority + alias_index,
                    )
            for keyword_index, keyword in enumerate(entry.get("keywords", [])):
                add_lookup(
                    keyword,
                    CHINESE_MEANING,
                    priority + keyword_index * 4,
                )

            connection.executemany(
                "INSERT INTO lookups(lookup_key, entry_id, kind, rank) VALUES (?, ?, ?, ?)",
                [
                    (lookup_key, entry_id, kind, rank)
                    for (lookup_key, kind), rank in best_lookup.items()
                ],
            )
            lookup_rows += len(best_lookup)

        metadata = {
            "schema_version": str(SCHEMA_VERSION),
            "entry_count": str(len(selected_rows)),
            "lookup_count": str(lookup_rows),
            "coverage_lemmas": str(len(coverage)),
            "coverage_sha256": sha256(coverage_path),
            "ecdict_sha256": sha256(csv_path),
            "core_dictionary_sha256": sha256(core_dictionary),
            "esdb_commit": ESDB_COMMIT,
            "selector": "ESDB size 70; A/B/Z; variants 1; lowercase; non-abbreviation",
            "excluded_network_only_rows": str(
                selection_audit.get("excluded_network_only_rows", 0)
            ),
            "excluded_non_substantive_rows": str(
                selection_audit.get("excluded_non_substantive_rows", 0)
            ),
            "excluded_case_mismatch_rows": str(
                selection_audit.get("excluded_case_mismatch_rows", 0)
            ),
        }
        connection.executemany(
            "INSERT INTO metadata(key, value) VALUES (?, ?)",
            metadata.items(),
        )
        connection.commit()
        connection.execute("ANALYZE")
        connection.execute("VACUUM")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity check failed: {integrity}")
    finally:
        connection.close()

    return {
        "coverage_lemmas": len(coverage),
        "core_entries": len(core_words),
        "extended_entries": len(selected_rows),
        "total_exact_headword_coverage": len(core_words) + len(selected_rows),
        "lookup_rows": lookup_rows,
        "selection_audit": selection_audit,
        "output_bytes": output.stat().st_size,
        "output_sha256": sha256(output),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("coverage", type=Path)
    parser.add_argument("csv", type=Path)
    parser.add_argument("core_dictionary", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    metrics = build_database(
        args.coverage,
        args.csv,
        args.core_dictionary,
        args.output,
    )
    print(json.dumps(metrics, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
