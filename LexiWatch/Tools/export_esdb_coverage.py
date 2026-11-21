#!/usr/bin/env python3
"""Export a deterministic learner-oriented coverage manifest from ESDB.

The manifest contains only word boundaries and inflected/variant spellings.
It never contains dictionary definitions.  The app's Chinese definitions are
still sourced from the separately licensed ECDICT/Victor pipeline.
"""

from __future__ import annotations

import argparse
import sqlite3
import unicodedata
from collections import defaultdict
from pathlib import Path

from build_offline_dictionary import WORD_PATTERN


def ascii_fold(value: str) -> str:
    decomposed = unicodedata.normalize("NFKD", value)
    return "".join(
        character
        for character in decomposed
        if unicodedata.category(character) != "Mn"
    ).casefold().strip()


def accepted_word(value: str) -> str | None:
    folded = ascii_fold(value)
    if WORD_PATTERN.fullmatch(folded) is None:
        return None
    return folded


def export_manifest(
    database: Path,
    output: Path,
    *,
    size: int = 70,
    spellings: tuple[str, ...] = ("A", "B", "Z"),
    variant_level: int = 1,
) -> dict[str, int]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    placeholders = ",".join("?" for _ in spellings)
    query = f"""
        SELECT l.lemma, s.word
        FROM scowl_ AS s
        JOIN lemmas AS l USING (lemma_id)
        WHERE s.size <= ?
          AND s.variant_level <= ?
          AND s.spelling IN ('_', {placeholders})
          AND s.region IN ('', 'US', 'GB')
          AND s.category = ''
          AND l.lemma = lower(l.lemma)
          AND l.base_pos <> 'abbr'
        ORDER BY lower(l.lemma), lower(s.word)
    """

    forms_by_lemma: dict[str, set[str]] = defaultdict(set)
    try:
        for raw_lemma, raw_form in connection.execute(
            query,
            (size, variant_level, *spellings),
        ):
            lemma = accepted_word(raw_lemma)
            form = accepted_word(raw_form)
            if lemma is None:
                continue
            forms_by_lemma[lemma].add(lemma)
            if form is not None:
                forms_by_lemma[lemma].add(form)
    finally:
        connection.close()

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as destination:
        destination.write("# English Speller Database coverage manifest\n")
        destination.write(
            f"# size={size}; spellings={','.join(spellings)}; "
            f"variant_level={variant_level}; lowercase_non_abbreviation_lemmas=true\n"
        )
        destination.write("# lemma<TAB>accepted inflected and variant spellings\n")
        for lemma in sorted(forms_by_lemma):
            forms = sorted(forms_by_lemma[lemma] - {lemma})
            destination.write("\t".join((lemma, *forms)) + "\n")

    return {
        "lemmas": len(forms_by_lemma),
        "forms": sum(len(forms) for forms in forms_by_lemma.values()),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=int, default=70)
    parser.add_argument("--variant-level", type=int, default=1)
    parser.add_argument("--spellings", default="A,B,Z")
    args = parser.parse_args()

    metrics = export_manifest(
        args.database,
        args.output,
        size=args.size,
        spellings=tuple(
            value.strip() for value in args.spellings.split(",") if value.strip()
        ),
        variant_level=args.variant_level,
    )
    print(
        f"wrote {metrics['lemmas']} ESDB lemmas and {metrics['forms']} forms "
        f"to {args.output}"
    )


if __name__ == "__main__":
    main()
