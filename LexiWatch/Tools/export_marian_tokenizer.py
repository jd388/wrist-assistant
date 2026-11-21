#!/usr/bin/env python3
"""Export a Hugging Face Marian tokenizer for the pure-Swift runtime.

The generated ``.spmlex`` file contains a compact scalar trie for source-side
Unigram Viterbi tokenization and the final Marian vocabulary's target-side
ID-to-piece table.  It deliberately stores *combined* ``vocab.json`` IDs,
rather than SentencePiece's private source/target IDs.

Example:

    python Tools/export_marian_tokenizer.py \
      --tokenizer-dir /path/to/marian/tokenizer \
      --output /tmp/zh_en.spmlex \
      --golden-output /tmp/zh_en.golden.json \
      --golden-text '我爱你。' \
      --target-text 'I love you.'

Requires the ``sentencepiece`` Python package used by Transformers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import sentencepiece as sentencepiece_runtime
from sentencepiece import sentencepiece_model_pb2


MAGIC = b"LXSPUNI1"
FORMAT_VERSION = 1

FLAG_ADD_DUMMY_PREFIX = 1 << 0
FLAG_REMOVE_EXTRA_WHITESPACES = 1 << 1
FLAG_ESCAPE_WHITESPACES = 1 << 2

NORMAL = sentencepiece_model_pb2.ModelProto.SentencePiece.NORMAL
UNKNOWN = sentencepiece_model_pb2.ModelProto.SentencePiece.UNKNOWN
CONTROL = sentencepiece_model_pb2.ModelProto.SentencePiece.CONTROL
USER_DEFINED = sentencepiece_model_pb2.ModelProto.SentencePiece.USER_DEFINED
UNUSED = sentencepiece_model_pb2.ModelProto.SentencePiece.UNUSED
BYTE = sentencepiece_model_pb2.ModelProto.SentencePiece.BYTE
UNIGRAM = sentencepiece_model_pb2.TrainerSpec.UNIGRAM


@dataclass
class TrieNode:
    children: dict[int, int] = field(default_factory=dict)
    token_id: int = -1
    score: float = 0.0
    piece_type: int = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tokenizer-dir",
        required=True,
        type=Path,
        help="Directory containing source.spm, target.spm, and vocab.json",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--golden-output",
        type=Path,
        help="Optional JSON file containing Python SentencePiece reference cases",
    )
    parser.add_argument(
        "--golden-text",
        action="append",
        default=[],
        help="Source text to encode into the optional golden JSON (repeatable)",
    )
    parser.add_argument(
        "--target-text",
        action="append",
        default=[],
        help="Target text to encode/decode into the optional golden JSON (repeatable)",
    )
    return parser.parse_args()


def read_model(path: Path) -> sentencepiece_model_pb2.ModelProto:
    model = sentencepiece_model_pb2.ModelProto()
    model.ParseFromString(path.read_bytes())
    if model.trainer_spec.model_type != UNIGRAM:
        raise ValueError(f"{path} is not a SentencePiece Unigram model")
    return model


def build_source_trie(
    model: sentencepiece_model_pb2.ModelProto,
    vocabulary: dict[str, int],
) -> tuple[list[TrieNode], float, int]:
    unknown_pieces = [piece for piece in model.pieces if piece.type == UNKNOWN]
    if len(unknown_pieces) != 1:
        raise ValueError(f"expected exactly one unknown piece, found {len(unknown_pieces)}")
    unknown_piece = unknown_pieces[0].piece
    try:
        unknown_id = vocabulary[unknown_piece]
    except KeyError as error:
        raise ValueError(f"unknown piece {unknown_piece!r} is absent from vocab.json") from error

    normal_scores = [piece.score for piece in model.pieces if piece.type == NORMAL]
    if not normal_scores:
        raise ValueError("Unigram model has no normal pieces")
    unknown_score = min(normal_scores) - 10.0

    nodes = [TrieNode()]
    for piece in model.pieces:
        if piece.type in (UNKNOWN, CONTROL, UNUSED):
            continue
        if piece.type == BYTE:
            raise ValueError("byte_fallback SentencePiece models are not supported")
        if piece.type not in (NORMAL, USER_DEFINED):
            raise ValueError(f"unsupported SentencePiece type {piece.type} for {piece.piece!r}")
        node_index = 0
        for scalar in map(ord, piece.piece):
            child_index = nodes[node_index].children.get(scalar)
            if child_index is None:
                child_index = len(nodes)
                nodes[node_index].children[scalar] = child_index
                nodes.append(TrieNode())
            node_index = child_index

        terminal = nodes[node_index]
        if terminal.token_id != -1:
            raise ValueError(f"duplicate source piece {piece.piece!r}")
        # MarianTokenizer first performs SentencePiece segmentation, then maps
        # the emitted string through its final (sometimes merged) vocab.json.
        # A small number of otherwise valid source pieces can therefore map to
        # the final unknown ID.
        terminal.token_id = vocabulary.get(piece.piece, unknown_id)
        terminal.score = piece.score
        terminal.piece_type = piece.type

    return nodes, unknown_score, unknown_id


def flatten_edges(nodes: list[TrieNode]) -> tuple[list[tuple[int, int, int, float, int]], list[tuple[int, int]]]:
    node_records: list[tuple[int, int, int, float, int]] = []
    edges: list[tuple[int, int]] = []
    for node in nodes:
        first_edge = len(edges)
        children = sorted(node.children.items())
        edges.extend(children)
        node_records.append(
            (first_edge, len(children), node.token_id, node.score, node.piece_type)
        )
    return node_records, edges


def target_table(vocabulary: dict[str, int]) -> list[str | None]:
    if not vocabulary:
        raise ValueError("vocab.json is empty")
    highest_id = max(vocabulary.values())
    table: list[str | None] = [None] * (highest_id + 1)
    for piece, token_id in vocabulary.items():
        if token_id < 0:
            raise ValueError(f"negative token ID {token_id} for {piece!r}")
        if table[token_id] is not None:
            raise ValueError(f"duplicate token ID {token_id} in vocab.json")
        table[token_id] = piece
    return table


def int_id(vocabulary: dict[str, int], token: str) -> int:
    return vocabulary.get(token, -1)


def write_u32(output: bytearray, value: int) -> None:
    output.extend(struct.pack("<I", value))


def write_i32(output: bytearray, value: int) -> None:
    output.extend(struct.pack("<i", value))


def write_f32(output: bytearray, value: float) -> None:
    output.extend(struct.pack("<f", value))


def write_resource(
    destination: Path,
    source_model: sentencepiece_model_pb2.ModelProto,
    vocabulary: dict[str, int],
) -> tuple[int, str]:
    nodes, unknown_score, unknown_id = build_source_trie(source_model, vocabulary)
    node_records, edges = flatten_edges(nodes)
    targets = target_table(vocabulary)

    normalizer = source_model.normalizer_spec
    if normalizer.name not in ("nmt_nfkc", "nfkc"):
        raise ValueError(
            f"unsupported normalizer {normalizer.name!r}; the Swift runtime implements NFKC"
        )

    flags = 0
    if normalizer.add_dummy_prefix:
        flags |= FLAG_ADD_DUMMY_PREFIX
    if normalizer.remove_extra_whitespaces:
        flags |= FLAG_REMOVE_EXTRA_WHITESPACES
    if normalizer.escape_whitespaces:
        flags |= FLAG_ESCAPE_WHITESPACES

    name_bytes = normalizer.name.encode("utf-8")
    output = bytearray(MAGIC)
    write_u32(output, FORMAT_VERSION)
    write_u32(output, flags)
    write_i32(output, unknown_id)
    write_i32(output, int_id(vocabulary, "</s>"))
    write_i32(output, int_id(vocabulary, "<pad>"))
    write_i32(output, int_id(vocabulary, "<s>"))
    write_f32(output, unknown_score)
    write_u32(output, len(node_records))
    write_u32(output, len(edges))
    write_u32(output, len(targets))
    write_u32(output, len(name_bytes))
    output.extend(name_bytes)

    for first_edge, edge_count, token_id, score, piece_type in node_records:
        write_u32(output, first_edge)
        write_u32(output, edge_count)
        write_i32(output, token_id)
        write_f32(output, score)
        output.append(piece_type)
        output.extend(b"\0\0\0")

    for scalar, child_index in edges:
        write_u32(output, scalar)
        write_u32(output, child_index)

    for piece in targets:
        if piece is None:
            write_u32(output, 0xFFFFFFFF)
            continue
        encoded = piece.encode("utf-8")
        write_u32(output, len(encoded))
        output.extend(encoded)

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(output)
    return len(output), hashlib.sha256(output).hexdigest()


def encoded_ids(
    processor: sentencepiece_runtime.SentencePieceProcessor,
    vocabulary: dict[str, int],
    text: str,
    eos_id: int,
    unknown_id: int,
) -> tuple[list[str], list[int]]:
    pieces = processor.encode(text, out_type=str)
    ids = [vocabulary.get(piece, unknown_id) for piece in pieces]
    if eos_id >= 0:
        ids.append(eos_id)
    return pieces, ids


def golden_payload(
    tokenizer_dir: Path,
    vocabulary: dict[str, int],
    source_texts: Iterable[str],
    target_texts: Iterable[str],
) -> dict[str, object]:
    source = sentencepiece_runtime.SentencePieceProcessor(
        model_file=str(tokenizer_dir / "source.spm")
    )
    target = sentencepiece_runtime.SentencePieceProcessor(
        model_file=str(tokenizer_dir / "target.spm")
    )
    unknown_id = int_id(vocabulary, "<unk>")
    eos_id = int_id(vocabulary, "</s>")

    encode_cases = []
    for text in source_texts:
        pieces, ids = encoded_ids(source, vocabulary, text, eos_id, unknown_id)
        encode_cases.append(
            {
                "text": text,
                "normalized": source.normalize(text),
                "pieces": pieces,
                "ids": ids,
            }
        )

    decode_cases = []
    for text in target_texts:
        pieces, ids = encoded_ids(target, vocabulary, text, eos_id, unknown_id)
        decoded_pieces = [piece for piece in pieces if piece in vocabulary]
        decode_cases.append(
            {
                "text": text,
                "pieces": pieces,
                "ids": ids,
                "decoded": target.decode(decoded_pieces),
            }
        )

    return {"encode": encode_cases, "decode": decode_cases}


def main() -> None:
    args = parse_args()
    tokenizer_dir = args.tokenizer_dir.resolve()
    source_path = tokenizer_dir / "source.spm"
    target_path = tokenizer_dir / "target.spm"
    vocab_path = tokenizer_dir / "vocab.json"
    for required in (source_path, target_path, vocab_path):
        if not required.is_file():
            raise FileNotFoundError(required)

    source_model = read_model(source_path)
    # Parsing the target model here catches accidental BPE/non-SPM resources
    # before an otherwise valid-looking runtime file is emitted.
    read_model(target_path)
    vocabulary = json.loads(vocab_path.read_text(encoding="utf-8"))
    if not isinstance(vocabulary, dict) or not all(
        isinstance(piece, str) and isinstance(token_id, int)
        for piece, token_id in vocabulary.items()
    ):
        raise ValueError("vocab.json must map strings to integer IDs")

    byte_count, digest = write_resource(args.output.resolve(), source_model, vocabulary)
    print(f"wrote {args.output}: {byte_count:,} bytes, sha256={digest}")

    if args.golden_output:
        payload = golden_payload(
            tokenizer_dir,
            vocabulary,
            args.golden_text,
            args.target_text,
        )
        args.golden_output.parent.mkdir(parents=True, exist_ok=True)
        args.golden_output.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"wrote {args.golden_output}")


if __name__ == "__main__":
    main()
