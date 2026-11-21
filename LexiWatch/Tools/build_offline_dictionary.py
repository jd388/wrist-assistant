#!/usr/bin/env python3
"""Build a compact, school-oriented offline dictionary from ECDICT CSV."""

from __future__ import annotations

import argparse
import csv
import html
import json
import re
import unicodedata
from pathlib import Path


WORD_PATTERN = re.compile(r"[A-Za-z][A-Za-z .'-]{0,39}")
HAN = re.compile(r"[\u3400-\u9fff]")
ASCII_HTML_TAG = re.compile(r"</?[A-Za-z][^>]{0,80}>")
NETWORK_LABEL = re.compile(r"(?:\[|［|【)\s*网络\s*(?:\]|］|】)")
BRACKETED_METADATA = re.compile(
    r"\[[^\[\]]*\]|［[^［］]*］|【[^【】]*】|<[^<>]*>"
)
FORM_METADATA_MARKER = (
    r"(?:的?变形|(?:的)?(?:过去式|过去分词|现在分词|第三人称单数|"
    r"比较级|最高级|复数)(?:和(?:过去分词|现在分词))?(?:形式)?)"
)
PARENTHETICAL_FORM_METADATA = re.compile(
    rf"[（(][^（）()]{{0,160}}{FORM_METADATA_MARKER}[^（）()]{{0,80}}[）)]",
    re.IGNORECASE,
)
BARE_FORM_METADATA = re.compile(
    rf"(?:[A-Za-z][A-Za-z .'-]{{0,60}}\s*)?{FORM_METADATA_MARKER}",
    re.IGNORECASE,
)
BROKEN_PRONUNCIATION_VARIANT_MARKER = re.compile(
    r"\s*;\s*\(\?@\)\s*"
)
DELIMITER_FAMILIES = {
    "(": ("paren", ")"),
    "（": ("paren", "）"),
    "[": ("square", "]"),
    "［": ("square", "］"),
    "{": ("curly", "}"),
    "｛": ("curly", "｝"),
    "《": ("angle", "》"),
}
DELIMITER_CLOSERS = {
    ")": "paren",
    "）": "paren",
    "]": "square",
    "］": "square",
    "}": "curly",
    "｝": "curly",
    "》": "angle",
}
SOURCE_POS_PREFIX = re.compile(
    r"^(?P<pos>interj|abbr|adv|adj|aux|prep|pron|conj|num|art|int|vi|vt|ad|n|v|a)"
    r"(?:\.\s*|\s+)(?P<gloss>.+)$",
    re.IGNORECASE,
)
IRRECOVERABLE_ASCII_MARKER = re.compile(
    r"(?<=[\u3400-\u9fff])NE[0-9A-F]{3,}\b"
)
POS_LABELS = {
    "a": "adj.",
    "abbr": "abbr.",
    "ad": "adv.",
    "adj": "adj.",
    "adv": "adv.",
    "art": "art.",
    "aux": "aux.",
    "conj": "conj.",
    "int": "interj.",
    "interj": "interj.",
    "n": "n.",
    "num": "num.",
    "prep": "prep.",
    "pron": "pron.",
    "v": "v.",
    "vi": "vi.",
    "vt": "vt.",
}
LEARNING_TAGS = {"zk", "gk", "cet4", "cet6", "ky", "ielts", "toefl", "gre"}
REVERSE_METADATA_KEYWORDS = {
    # ECDICT domain/language abbreviations can also appear in parentheses
    # rather than square brackets. A one-character reverse key is both too
    # ambiguous for the Watch and liable to be source metadata.
    "医",
    "化",
    "法",
    "计",
    "经",
    "建",
    "农",
}
PHRASAL_PARTICLES = {
    "along",
    "apart",
    "around",
    "aside",
    "away",
    "back",
    "down",
    "forth",
    "forward",
    "in",
    "off",
    "on",
    "out",
    "over",
    "round",
    "through",
    "up",
}
PATTERN_PREPOSITIONS = {
    "about",
    "after",
    "against",
    "at",
    "before",
    "behind",
    "beneath",
    "beside",
    "between",
    "beyond",
    "by",
    "for",
    "from",
    "into",
    "of",
    "onto",
    "to",
    "toward",
    "towards",
    "under",
    "upon",
    "with",
    "without",
}
PLACEHOLDER_TOKENS = {
    "do",
    "doing",
    "one",
    "oneself",
    "sb",
    "somebody",
    "someone",
    "something",
    "sth",
}

# Some one-particle forms are grammatically a verb + governed preposition,
# rather than a particle verb. Keeping the distinction lets the watch label
# depend on / provide sb with sth as sentence patterns, not as loose phrases.
VERB_PATTERN_OVERRIDES = {
    ("agree", "on"),
    ("apologize", "for"),
    ("apply", "for"),
    ("believe", "in"),
    ("concentrate", "on"),
    ("depend", "on"),
    ("engage", "in"),
    ("focus", "on"),
    ("insist", "on"),
    ("participate", "in"),
    ("prevent", "from"),
    ("provide", "with"),
    ("rely", "on"),
    ("result", "in"),
    ("succeed", "in"),
}

# These six are much more useful to a learner looking up give than ordinary
# give + noun collocations. The order is deliberately stable and testable.
SPECIAL_EXPRESSION_ORDER = {
    "give": ["give up", "give in", "give away", "give out", "give off", "give back"]
}
SPECIAL_PATTERN_ORDER = {"give": ["give to"]}

# ECDICT's raw glosses are comprehensive but too noisy for a watch face. Keep
# the highest-value `give` usages concise and preserve the distinction between
# a meaning-changing particle verb and the sentence frame it accepts.
CURATED_RELATED_EXPRESSIONS = {
    "give": [
        {
            "text": "give up",
            "kind": "phrasalVerb",
            "chinese": "放弃；戒除；认输",
            "example": None,
            "exampleChinese": None,
            "priority": 0,
        },
        {
            "text": "give in",
            "kind": "phrasalVerb",
            "chinese": "屈服；让步；上交",
            "example": None,
            "exampleChinese": None,
            "priority": 1,
        },
        {
            "text": "give away",
            "kind": "phrasalVerb",
            "chinese": "赠送；泄露；暴露",
            "example": None,
            "exampleChinese": None,
            "priority": 2,
        },
        {
            "text": "give out",
            "kind": "phrasalVerb",
            "chinese": "分发；发出；耗尽",
            "example": None,
            "exampleChinese": None,
            "priority": 3,
        },
        {
            "text": "give off",
            "kind": "phrasalVerb",
            "chinese": "发出（光、热、气味等）",
            "example": None,
            "exampleChinese": None,
            "priority": 4,
        },
        {
            "text": "give back",
            "kind": "phrasalVerb",
            "chinese": "归还；使恢复",
            "example": None,
            "exampleChinese": None,
            "priority": 5,
        },
        {
            "text": "give sb sth / give sth to sb",
            "kind": "verbPattern",
            "chinese": "给某人某物",
            "example": None,
            "exampleChinese": None,
            "priority": 6,
        },
        {
            "text": "give up doing sth",
            "kind": "verbPattern",
            "chinese": "放弃做某事",
            "example": None,
            "exampleChinese": None,
            "priority": 7,
        },
    ]
}
LINK_LEARNING_ORDER = {
    link: priority
    for priority, link in enumerate(
        (
            "up",
            "out",
            "off",
            "in",
            "on",
            "back",
            "down",
            "away",
            "over",
            "through",
            "around",
            "forward",
            "after",
            "for",
            "from",
            "to",
            "with",
            "of",
            "about",
            "into",
            "upon",
        )
    )
}
CHINESE_ALIASES = {
    "hello": ["你好", "您好", "哈喽", "喂"],
    "goodbye": ["再见"],
    "thanks": ["谢谢"],
    "thank": ["感谢"],
    "sorry": ["对不起", "抱歉"],
    "please": ["请"],
    "stimulate": ["刺激", "促进"],
}


def positive_int(value: str) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return 0
    return number if number > 0 else 0


def rank(row: dict[str, str]) -> tuple[int, int, int, int, str]:
    tags = set(row["tag"].split())
    tagged = 0 if tags & LEARNING_TAGS else 1
    oxford_or_collins = 0 if row["oxford"] == "1" or positive_int(row["collins"]) else 1
    frequencies = [number for number in (positive_int(row["bnc"]), positive_int(row["frq"])) if number]
    frequency = min(frequencies, default=10_000_000)
    return tagged, oxford_or_collins, frequency, len(row["word"]), row["word"].casefold()


def has_irrecoverable_source_artifact(value: str) -> bool:
    """Return true when OCR replaced a character rather than adding markup.

    A black square is a recoverable source separator, while a private-use,
    replacement, or box-drawing character usually stands in for an unknown
    source glyph. Dropping only that affected sense is safer than presenting a
    plausible-looking but damaged translation.
    """

    return IRRECOVERABLE_ASCII_MARKER.search(value) is not None or any(
        0x2500 <= ord(character) <= 0x257F
        or 0xE000 <= ord(character) <= 0xF8FF
        or ord(character) == 0xFFFD
        or unicodedata.category(character) in {"Cs", "Co", "Cn"}
        for character in value
    )


def clean_delimiters(value: str) -> str:
    """Keep balanced delimiters and discard only unpaired delimiter glyphs.

    OCR commonly mixes full-width and ASCII forms (for example ``(人名）``)
    or leaves a trailing close delimiter. Matching by delimiter family lets us
    repair the former deterministically, while unmatched open/close glyphs are
    removed instead of being shown as dictionary content. When a close glyph
    skips over a different unmatched family, the skipped opens are removed and
    the close is paired with the nearest compatible opener.
    """

    output: list[str] = []
    stack: list[tuple[str, int, str]] = []
    for character in value:
        opening = DELIMITER_FAMILIES.get(character)
        if opening is not None:
            family, _ = opening
            stack.append((family, len(output), character))
            output.append(character)
            continue

        family = DELIMITER_CLOSERS.get(character)
        if family is None:
            output.append(character)
            continue

        matching_index = next(
            (index for index in range(len(stack) - 1, -1, -1) if stack[index][0] == family),
            None,
        )
        if matching_index is None:
            continue

        while len(stack) - 1 > matching_index:
            _, output_index, _ = stack.pop()
            output[output_index] = ""

        _, _, opener = stack.pop()
        output.append(DELIMITER_FAMILIES[opener][1])

    for _, output_index, _ in stack:
        output[output_index] = ""
    return "".join(output)


def has_substantive_chinese(value: str) -> bool:
    """Require a Chinese gloss, not a source label or inflection pointer."""

    without_metadata = BRACKETED_METADATA.sub(" ", value)
    without_metadata = PARENTHETICAL_FORM_METADATA.sub(" ", without_metadata)
    without_metadata = BARE_FORM_METADATA.sub(" ", without_metadata)
    return HAN.search(without_metadata) is not None


def reverse_lookup_text(value: str) -> str:
    """Remove display-only source metadata before extracting Chinese keys."""

    network_label = NETWORK_LABEL.search(value)
    if network_label is not None:
        prefix = value[: network_label.start()]
        separator = max(
            prefix.rfind("；"),
            prefix.rfind(";"),
            prefix.rfind("\\n"),
            prefix.rfind("\n"),
        )
        value = prefix[:separator] if separator >= 0 else ""
    cleaned = BRACKETED_METADATA.sub(" ", value)
    cleaned = PARENTHETICAL_FORM_METADATA.sub(" ", cleaned)
    cleaned = BARE_FORM_METADATA.sub(" ", cleaned)
    return re.sub(r"\s+", " ", cleaned).strip()


def remove_dangling_gloss_colons(value: str) -> str:
    """Drop OCR/source colons that introduce no following explanation."""

    return re.sub(r"[:：](?=\s*(?:[;；]|$))", "", value)


def clean_source_text(value: str) -> str:
    value = html.unescape(value)
    value = ASCII_HTML_TAG.sub(" ", value)
    cleaned: list[str] = []
    for character in value:
        code_point = ord(character)
        category = unicodedata.category(character)
        if character in {"■", "▶"}:
            cleaned.append("；")
        elif (
            0x2500 <= code_point <= 0x257F
            or 0xE000 <= code_point <= 0xF8FF
            or code_point == 0xFFFD
            or category in {"Cc", "Cf", "Cs", "Co", "Cn"}
        ):
            cleaned.append(" ")
        else:
            cleaned.append(character)
    return clean_delimiters(re.sub(r"\s+", " ", "".join(cleaned)).strip())


def clean_translation_lines(value: str, limit: int) -> list[str]:
    lines: list[str] = []
    for raw_line in value.replace("\\r", "").split("\\n"):
        if (
            has_irrecoverable_source_artifact(raw_line)
            or NETWORK_LABEL.search(raw_line) is not None
        ):
            continue
        line = remove_dangling_gloss_colons(clean_source_text(raw_line))
        if line and has_substantive_chinese(line):
            lines.append(line)
    return lines[:limit]


def clean_lines(value: str, limit: int) -> str:
    return "；".join(clean_translation_lines(value, limit))


def normalized_part_of_speech(value: str) -> str:
    key = value.casefold().strip().rstrip(".")
    return POS_LABELS.get(key, value.strip())


def cleaned_pronunciation(value: str) -> str:
    """Preserve both variants while dropping ECDICT's broken `(?@)` marker."""

    return BROKEN_PRONUNCIATION_VARIANT_MARKER.sub("; ", value.strip())


def structured_meanings(row: dict[str, str]) -> list[dict[str, object]]:
    """Split ECDICT's compact translation into explicit grammatical senses."""

    grouped: list[tuple[str, list[str]]] = []
    fallback_pos = normalized_part_of_speech(row["pos"])
    for line in clean_translation_lines(row["translation"], 4):
        match = SOURCE_POS_PREFIX.match(line)
        if match is None:
            part_of_speech = fallback_pos
            gloss = line
        else:
            part_of_speech = normalized_part_of_speech(match.group("pos"))
            gloss = match.group("gloss").strip(" ：;；")
        if not gloss or not has_substantive_chinese(gloss):
            continue

        existing = next((item for item in grouped if item[0] == part_of_speech), None)
        if existing is None:
            grouped.append((part_of_speech, [gloss]))
        elif gloss not in existing[1]:
            existing[1].append(gloss)

    return [
        {
            "partOfSpeech": part_of_speech,
            "chinese": "；".join(glosses),
            "collocations": [],
            "example": None,
            "exampleChinese": None,
        }
        for part_of_speech, glosses in grouped
    ]


def aliases(exchange: str, headword: str) -> list[str]:
    """Return real ECDICT inflection forms, never its compact type codes.

    ``exchange`` uses ``1:`` for a compressed description of which forms are
    present (for example ``1:dp``).  That payload is metadata, not an alias.
    The remaining documented keys contain actual spellings.  Compare aliases
    case-insensitively so duplicate display variants such as ``djs``/``DJs``
    cannot create duplicate search hits.
    """

    form_keys = {"0", "3", "d", "f", "i", "p", "r", "s", "t"}
    results: list[str] = []
    seen: set[str] = {headword.casefold()}
    for item in exchange.split("/"):
        if ":" not in item:
            continue
        key, value = item.split(":", 1)
        if key not in form_keys:
            continue
        value = value.strip()
        folded = value.casefold()
        if (
            len(value) >= 2
            and WORD_PATTERN.fullmatch(value) is not None
            and folded not in seen
        ):
            seen.add(folded)
            results.append(value)
    return results[:8]


def chinese_keywords(translation: str) -> list[str]:
    results: list[str] = []
    for keyword in re.findall(
        r"[\u3400-\u9fff]{1,12}",
        reverse_lookup_text(translation),
    ):
        if keyword not in REVERSE_METADATA_KEYWORDS and keyword not in results:
            results.append(keyword)
    return results[:24]


def normalized_expression_tokens(value: str) -> list[str]:
    value = value.casefold().replace("’", "'")
    return [token.strip(".,:;!?()[]") for token in value.split() if token.strip(".,:;!?()[]")]


def is_placeholder_sequence(tokens: list[str]) -> bool:
    """Allow grammar notation, while rejecting lexical give a hand-style tails."""
    return all(
        token in PLACEHOLDER_TOKENS
        or token in PATTERN_PREPOSITIONS
        or token in PHRASAL_PARTICLES
        or token in {"one's", "somebody's", "someone's"}
        for token in tokens
    )


def related_expression_candidate(
    base: str, row: dict[str, str]
) -> tuple[str, str, str] | None:
    """Return (text, kind, dedupe key) for a strict phrase/pattern candidate."""
    text = re.sub(r"\s+", " ", row["word"].strip())
    tokens = normalized_expression_tokens(text)
    if len(tokens) < 2 or tokens[0] != base or len(tokens) > 6:
        return None

    tail = tokens[1:]
    first = tail[0]
    first_is_link = first in PHRASAL_PARTICLES or first in PATTERN_PREPOSITIONS
    first_is_placeholder = first in PLACEHOLDER_TOKENS or first in {
        "one's",
        "somebody's",
        "someone's",
    }
    if not first_is_link and not first_is_placeholder:
        return None

    # A lexical object after a link is normally a collocation (depend on a
    # thread, give away the racket), not the reusable expression itself.
    if first_is_link and len(tail) > 1 and not is_placeholder_sequence(tail[1:]):
        return None

    if first_is_placeholder:
        links = [token for token in tail[1:] if token in PATTERN_PREPOSITIONS]
        if not links or not is_placeholder_sequence(tail):
            return None
        governed = links[-1]
        return text, "verbPattern", f"{base}|verbPattern|{governed}"

    pair = (base, first)
    if first in PATTERN_PREPOSITIONS or pair in VERB_PATTERN_OVERRIDES:
        kind = "verbPattern"
        # Prefer a detailed sb/sth form over the bare ECDICT key later.
        return text, kind, f"{base}|{kind}|{first}"

    kind = "phrasalVerb"
    return text, kind, f"{base}|{kind}|{' '.join(tail)}"


def expression_source_rank(row: dict[str, str]) -> tuple[int, int, int, int, str]:
    tags = set(row["tag"].split())
    tagged = 0 if tags & LEARNING_TAGS else 1
    trusted = 0 if row["oxford"] == "1" or positive_int(row["collins"]) else 1
    frequencies = [number for number in (positive_int(row["bnc"]), positive_int(row["frq"])) if number]
    frequency = min(frequencies, default=10_000_000)
    tokens = normalized_expression_tokens(row["word"])
    return tagged, trusted, frequency, len(tokens), row["word"].casefold()


def expression_rank(base: str, text: str, kind: str, row: dict[str, str]) -> tuple[object, ...]:
    special = SPECIAL_EXPRESSION_ORDER.get(base, [])
    special_patterns = SPECIAL_PATTERN_ORDER.get(base, [])
    normalized = " ".join(normalized_expression_tokens(text))
    if normalized in special:
        return 0, special.index(normalized), *expression_source_rank(row)
    if normalized in special_patterns:
        return 1, special_patterns.index(normalized), *expression_source_rank(row)
    source_rank = expression_source_rank(row)
    tail = normalized_expression_tokens(text)[1:]
    link_priority = min(
        (LINK_LEARNING_ORDER.get(token, len(LINK_LEARNING_ORDER)) for token in tail),
        default=len(LINK_LEARNING_ORDER),
    )
    # Source learning/trust/frequency evidence must decide before the UI kind.
    # The particle order only breaks the many all-zero ECDICT phrase ties, so
    # useful school forms such as look up are not lost to alphabetic order.
    return (
        2,
        source_rank[0],
        source_rank[1],
        source_rank[2],
        link_priority,
        source_rank[3],
        0 if kind == "phrasalVerb" else 1,
        source_rank[4],
    )


def build_related_expressions(
    candidates: list[dict[str, str]], selected: list[dict[str, str]]
) -> dict[str, list[dict[str, object]]]:
    selected_bases = {
        row["word"].casefold()
        for row in selected
        if re.fullmatch(r"[A-Za-z]+", row["word"].strip())
    }
    grouped: dict[
        str,
        dict[
            str,
            tuple[tuple[object, ...], tuple[object, ...], dict[str, str], str, str],
        ],
    ] = {
        base: {} for base in selected_bases
    }

    for row in candidates:
        raw_tokens = normalized_expression_tokens(row["word"])
        if len(raw_tokens) < 2 or raw_tokens[0] not in selected_bases:
            continue
        base = raw_tokens[0]
        candidate = related_expression_candidate(base, row)
        if candidate is None:
            continue
        text, kind, key = candidate
        candidate_rank = expression_rank(base, text, kind, row)
        previous = grouped[base].get(key)
        # If ranks are otherwise comparable, the explicit sb/sth form carries
        # more grammatical information than a bare preposition entry. This is
        # only a same-signature dedupe rule; it must not outrank source quality
        # when different expressions compete for the eight display slots.
        detail_bonus = -sum(token in PLACEHOLDER_TOKENS for token in raw_tokens)
        selection_rank = candidate_rank[0], detail_bonus, *candidate_rank[1:]
        if previous is None or selection_rank < previous[1]:
            grouped[base][key] = candidate_rank, selection_rank, row, text, kind

    result: dict[str, list[dict[str, object]]] = {}
    for base, values in grouped.items():
        ordered = sorted(values.values(), key=lambda value: value[0])[:8]
        result[base] = [
            {
                "text": text,
                "kind": kind,
                "chinese": clean_lines(row["translation"], 3)[:240],
                "example": None,
                "exampleChinese": None,
                "priority": priority,
            }
            for priority, (_, _, row, text, kind) in enumerate(ordered)
        ]

    for base, expressions in CURATED_RELATED_EXPRESSIONS.items():
        if base in selected_bases:
            result[base] = [dict(expression) for expression in expressions]
    return result


def convert(
    row: dict[str, str], priority: int, related_expressions: list[dict[str, object]]
) -> dict[str, object]:
    word = row["word"].strip()
    meanings = structured_meanings(row)
    chinese = "；".join(str(meaning["chinese"]) for meaning in meanings)
    tags = row["tag"].split()
    level = " ".join(tags) if tags else None
    return {
        "id": word.casefold(),
        "headword": word,
        "pronunciation": (
            f"/{cleaned_pronunciation(row['phonetic'])}/"
            if cleaned_pronunciation(row["phonetic"])
            else None
        ),
        "aliases": aliases(row["exchange"], word) + CHINESE_ALIASES.get(word.casefold(), []),
        "keywords": chinese_keywords(chinese),
        "meanings": meanings,
        "relatedExpressions": related_expressions,
        "level": level,
        "priority": priority,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--limit", type=int, default=30_000)
    args = parser.parse_args()

    candidates: list[dict[str, str]] = []
    with args.csv.open(encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            word = row["word"].strip()
            if WORD_PATTERN.fullmatch(word) is None or not structured_meanings(row):
                continue
            candidates.append(row)

    candidates.sort(key=rank)
    selected = candidates[: args.limit]

    # These are important smoke-test and recovery words even if a future source
    # revision changes frequency ranks.
    required = {"hello", "apple", "school", "student", "word", "learn"}
    selected_words = {row["word"].casefold() for row in selected}
    if missing := required - selected_words:
        by_word = {row["word"].casefold(): row for row in candidates}
        selected.extend(by_word[word] for word in sorted(missing) if word in by_word)

    related_by_word = build_related_expressions(candidates, selected)
    entries = sorted(
        (
            convert(row, priority, related_by_word.get(row["word"].casefold(), []))
            for priority, row in enumerate(selected)
        ),
        key=lambda entry: str(entry["headword"]).casefold(),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(entries, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"wrote {len(entries)} entries to {args.output}")


if __name__ == "__main__":
    main()
