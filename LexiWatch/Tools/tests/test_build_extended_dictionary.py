import csv
import json
import sqlite3
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

import build_extended_dictionary as extended  # noqa: E402


FIELDNAMES = [
    "word",
    "phonetic",
    "definition",
    "translation",
    "pos",
    "collins",
    "oxford",
    "tag",
    "bnc",
    "frq",
    "exchange",
    "detail",
    "audio",
]


def ecdict_row(word: str, translation: str, **values: str) -> dict[str, str]:
    row = {field: "" for field in FIELDNAMES}
    row.update(
        {
            "word": word,
            "translation": translation,
            "bnc": "10000",
            "frq": "10000",
        }
    )
    row.update(values)
    return row


class ExtendedDictionaryBuildTests(unittest.TestCase):
    def test_builds_lazy_entries_and_exact_reverse_lookups(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            coverage = root / "coverage.tsv"
            coverage.write_text(
                "# fixture\napple\tapples\naardvark\taardvarks\taardvark's\n",
                encoding="utf-8",
            )
            core = root / "core.json"
            core.write_text(
                json.dumps([{"headword": "apple"}]),
                encoding="utf-8",
            )
            source = root / "ecdict.csv"
            with source.open("w", encoding="utf-8", newline="") as destination:
                writer = csv.DictWriter(destination, fieldnames=FIELDNAMES)
                writer.writeheader()
                writer.writerow(ecdict_row("apple", "n. 苹果"))
                writer.writerow(
                    ecdict_row(
                        "aardvark",
                        "n. 土豚",
                        phonetic="'ɑ:dvɑ:k",
                    )
                )

            output = root / "extended.sqlite"
            metrics = extended.build_database(coverage, source, core, output)
            self.assertEqual(metrics["extended_entries"], 1)
            self.assertEqual(metrics["total_exact_headword_coverage"], 2)

            connection = sqlite3.connect(output)
            try:
                payload = json.loads(
                    connection.execute(
                        "SELECT payload FROM entries WHERE headword = 'aardvark'"
                    ).fetchone()[0]
                )
                self.assertEqual(payload["meanings"][0]["chinese"], "土豚")
                self.assertIn("aardvarks", payload["aliases"])
                lookup_kinds = dict(
                    connection.execute(
                        "SELECT lookup_key, kind FROM lookups ORDER BY lookup_key"
                    )
                )
                self.assertEqual(lookup_kinds["aardvark"], 0)
                self.assertEqual(lookup_kinds["aardvarks"], 1)
                self.assertEqual(lookup_kinds["土豚"], 2)
                self.assertEqual(
                    connection.execute("PRAGMA integrity_check").fetchone()[0],
                    "ok",
                )
            finally:
                connection.close()

    def test_lookup_normalization_preserves_english_word_boundaries(self) -> None:
        self.assertEqual(extended.normalize_lookup_key("take-off"), "take-off")
        self.assertEqual(extended.normalize_lookup_key("take–off"), "take-off")
        self.assertEqual(
            extended.normalize_tolerant_lookup_key("take-off"),
            "take off",
        )
        self.assertEqual(extended.normalize_lookup_key("takeoff"), "takeoff")
        self.assertEqual(extended.normalize_lookup_key("act on"), "act on")
        self.assertEqual(extended.normalize_lookup_key("Acton"), "acton")
        self.assertEqual(extended.normalize_lookup_key("学 校。"), "学校")

    def test_quarantines_network_metadata_and_case_fold_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            coverage = root / "coverage.tsv"
            coverage.write_text(
                "mixed\nvictimiser\ntantalisingly\nrad\nallspice\n",
                encoding="utf-8",
            )
            core = root / "core.json"
            core.write_text("[]", encoding="utf-8")
            source = root / "ecdict.csv"
            with source.open("w", encoding="utf-8", newline="") as destination:
                writer = csv.DictWriter(destination, fieldnames=FIELDNAMES)
                writer.writeheader()
                writer.writerow(ecdict_row("victimiser", "[网络] 受害者"))
                writer.writerow(
                    ecdict_row(
                        "mixed",
                        "n. 可靠释义\\n[网络] 错误抓取；垃圾释义",
                    )
                )
                writer.writerow(
                    ecdict_row("tantalisingly", "tantalising的变形")
                )
                writer.writerow(ecdict_row("RAD", "[计] 随机存取装置"))
                writer.writerow(ecdict_row("allspice", "[医] 多香果"))

            output = root / "extended.sqlite"
            metrics = extended.build_database(coverage, source, core, output)
            self.assertEqual(metrics["extended_entries"], 2)
            self.assertEqual(
                metrics["selection_audit"]["excluded_network_only_rows"],
                1,
            )
            self.assertEqual(
                metrics["selection_audit"]["excluded_non_substantive_rows"],
                1,
            )
            self.assertEqual(
                metrics["selection_audit"]["excluded_case_mismatch_rows"],
                1,
            )

            connection = sqlite3.connect(output)
            try:
                payloads = {
                    headword: json.loads(payload)
                    for headword, payload in connection.execute(
                        "SELECT headword, payload FROM entries"
                    )
                }
                self.assertEqual(set(payloads), {"allspice", "mixed"})
                self.assertNotIn(
                    "[网络]",
                    json.dumps(payloads, ensure_ascii=False),
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM lookups WHERE lookup_key = '医'"
                    ).fetchone()[0],
                    0,
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT e.headword FROM lookups l "
                        "JOIN entries e USING(entry_id) "
                        "WHERE l.lookup_key = '多香果' AND l.kind = 2"
                    ).fetchone()[0],
                    "allspice",
                )
            finally:
                connection.close()

    def test_bundled_database_metrics_integrity_and_display_safety(self) -> None:
        database = (
            TOOLS.parent
            / "LexiWatchWatchApp"
            / "Resources"
            / "offline_dictionary_extended.sqlite"
        )
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
        try:
            self.assertEqual(
                connection.execute("PRAGMA integrity_check").fetchone()[0],
                "ok",
            )
            self.assertEqual(
                connection.execute("PRAGMA user_version").fetchone()[0],
                extended.SCHEMA_VERSION,
            )
            metadata = dict(connection.execute("SELECT key, value FROM metadata"))
            entry_count = connection.execute(
                "SELECT COUNT(*) FROM entries"
            ).fetchone()[0]
            lookup_count = connection.execute(
                "SELECT COUNT(*) FROM lookups"
            ).fetchone()[0]
            self.assertEqual(
                entry_count,
                int(metadata["entry_count"]),
            )
            self.assertEqual(
                lookup_count,
                int(metadata["lookup_count"]),
            )

            meaning_count = 0
            for headword, payload in connection.execute(
                "SELECT headword, payload FROM entries"
            ):
                entry = json.loads(payload)
                self.assertEqual(headword, headword.casefold())
                meanings = entry.get("meanings", [])
                self.assertTrue(meanings)
                for meaning in meanings:
                    chinese = meaning.get("chinese", "")
                    self.assertTrue(chinese.strip())
                    self.assertNotIn("[网络]", chinese)
                    self.assertTrue(extended.base.has_substantive_chinese(chinese))
                    meaning_count += 1

                for value in self._all_strings(entry):
                    self.assertFalse(
                        self._has_unsupported_display_character(value),
                        f"unsupported display character in {entry.get('headword')}: {value!r}",
                    )
            self.assertGreater(meaning_count, entry_count)
            for unsafe_headword in (
                "victimiser",
                "acrophobic",
                "nonkosher",
                "nontaxable",
                "RAD",
                "KI",
            ):
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM entries WHERE headword = ?",
                        (unsafe_headword,),
                    ).fetchone()[0],
                    0,
                )
            for metadata_key in ("医", "化", "法", "计", "的变形"):
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM lookups WHERE lookup_key = ?",
                        (metadata_key,),
                    ).fetchone()[0],
                    0,
                )

            strict_pairs = dict(
                connection.execute(
                    "SELECT l.lookup_key, e.headword FROM lookups l "
                    "JOIN entries e USING(entry_id) "
                    "WHERE l.kind = 0 AND l.lookup_key IN ('buy-in', 'buy in')"
                )
            )
            self.assertEqual(strict_pairs["buy-in"], "buy-in")
            self.assertEqual(strict_pairs["buy in"], "buy in")
        finally:
            connection.close()

    @staticmethod
    def _all_strings(value: object):
        if isinstance(value, str):
            yield value
        elif isinstance(value, dict):
            for child in value.values():
                yield from ExtendedDictionaryBuildTests._all_strings(child)
        elif isinstance(value, list):
            for child in value:
                yield from ExtendedDictionaryBuildTests._all_strings(child)

    @staticmethod
    def _has_unsupported_display_character(value: str) -> bool:
        return any(
            character in {"■", "▶"}
            or 0x2500 <= ord(character) <= 0x257F
            or ord(character) == 0xFFFD
            or unicodedata.category(character) in {"Cc", "Cf", "Cs", "Co", "Cn"}
            for character in value
        )


if __name__ == "__main__":
    unittest.main()
