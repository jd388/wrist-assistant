import Foundation
import Testing
@testable import DictionaryCore

private struct GoldenEncodeCase: Sendable {
    let text: String
    let ids: [Int32]
}

private struct GoldenDecodeCase: Sendable {
    let ids: [Int32]
    let text: String
}

private enum TokenizerFixtureError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(path):
            "Missing exported tokenizer fixture at \(path). Run Tools/export_marian_tokenizer.py first."
        }
    }
}

private func tokenizerFixture(_ direction: String) throws -> SentencePieceTokenizer {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("LexiWatchWatchApp/Resources/Translation")
    let filename = direction == "zh_en" ? "ZhEnTokenizer" : "EnZhTokenizer"
    let url = root.appendingPathComponent(filename).appendingPathExtension("spmlex")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw TokenizerFixtureError.missing(url.path)
    }
    return try SentencePieceTokenizer(contentsOf: url)
}

@Test("Chinese-to-English source IDs exactly match Python SentencePiece")
func chineseSourceGoldenIDs() throws {
    let tokenizer = try tokenizerFixture("zh_en")
    let cases = [
        GoldenEncodeCase(text: "我爱你。", ids: [3, 22_124, 6, 0]),
        GoldenEncodeCase(
            text: "我把作业忘在教室了。",
            ids: [106, 372, 10_455, 7_969, 27, 21_920, 37, 6, 0]
        ),
        GoldenEncodeCase(text: "刺激经济增长。", ids: [3, 8_003, 9_543, 6, 0]),
        GoldenEncodeCase(
            text: "这是一位负责任的老师。",
            ids: [1_215, 2_267, 23_768, 5_995, 6, 0]
        ),
        GoldenEncodeCase(
            text: "  Ａ班\t今天学习英语。  ",
            ids: [71, 2_495, 3_240, 1_082, 3_177, 6, 0]
        ),
    ]

    for golden in cases {
        #expect(tokenizer.encode(golden.text) == golden.ids)
    }
}

@Test("English-to-Chinese source IDs exactly match Python SentencePiece")
func englishSourceGoldenIDs() throws {
    let tokenizer = try tokenizerFixture("en_zh")
    let cases = [
        GoldenEncodeCase(text: "I love you.", ids: [28, 1_741, 39, 6, 0]),
        GoldenEncodeCase(
            text: "I forgot my homework in the classroom.",
            ids: [28, 18_117, 162, 44_026, 11, 3, 42_146, 6, 0]
        ),
        GoldenEncodeCase(
            text: "This is a responsible teacher.",
            ids: [208, 32, 13, 1_384, 12_777, 6, 0]
        ),
        GoldenEncodeCase(
            text: "The policy will stimulate economic growth.",
            ids: [26, 419, 75, 18_138, 293, 1_315, 6, 0]
        ),
        GoldenEncodeCase(
            text: "  Ｉ\tlook forward to the school trip.  ",
            ids: [28, 1_221, 1_800, 9, 3, 1_498, 13_247, 6, 0]
        ),
    ]

    for golden in cases {
        #expect(tokenizer.encode(golden.text) == golden.ids)
    }
}

@Test("Target-side combined vocabulary IDs decode like Python SentencePiece")
func targetDecodeGoldenText() throws {
    let chineseToEnglish = try tokenizerFixture("zh_en")
    let englishCases = [
        GoldenDecodeCase(ids: [24, 608, 23, 4, 0], text: "I love you."),
        GoldenDecodeCase(
            ids: [24, 18_421, 108, 573, 4_376, 12, 5, 17_529, 4, 0],
            text: "I forgot my homework in the classroom."
        ),
        GoldenDecodeCase(
            ids: [360, 20_413, 753, 1_187, 4, 0],
            text: "To stimulate economic growth."
        ),
        GoldenDecodeCase(
            ids: [130, 14, 13, 2_875, 7_529, 4, 0],
            text: "This is a responsible teacher."
        ),
        GoldenDecodeCase(
            ids: [10_059, 71, 4_216, 1_591, 782, 4, 0],
            text: "Class A studies English today."
        ),
    ]
    for golden in englishCases {
        #expect(chineseToEnglish.decode(golden.ids) == golden.text)
    }

    let englishToChinese = try tokenizerFixture("en_zh")
    let chineseCases = [
        GoldenDecodeCase(ids: [20_003, 10, 0], text: "我爱你。"),
        GoldenDecodeCase(
            ids: [5_138, 33_354, 571, 17_263, 3_724, 8_296, 57, 10, 0],
            text: "我在教室里忘写作业了。"
        ),
        GoldenDecodeCase(
            ids: [1_719, 4_227, 17_194, 15_020, 10, 0],
            text: "这是一位负责任的老师。"
        ),
        GoldenDecodeCase(
            ids: [8, 35_113, 97, 11_200, 6_897, 10, 0],
            text: "这项政策将刺激经济增长。"
        ),
        GoldenDecodeCase(
            ids: [105, 7_631, 5_501, 1_852, 5_266, 10, 0],
            text: "我期待这次学校旅行。"
        ),
    ]
    for golden in chineseCases {
        #expect(englishToChinese.decode(golden.ids) == golden.text)
    }
}

@Test("NFKC, whitespace collapse, dummy prefix, and metaspace match the model")
func sentencePieceNormalization() throws {
    let tokenizer = try tokenizerFixture("zh_en")
    #expect(tokenizer.normalizedText("  ＡＢＣ　ﬁancée\t① ℃ Ⅳ  ") == "▁ABC▁fiancée▁1▁°C▁IV")
}

@Test("Adjacent out-of-vocabulary scalars collapse to one unknown token")
func sentencePieceUnknownRun() throws {
    let tokenizer = try tokenizerFixture("zh_en")
    #expect(tokenizer.encode("🫠🫡") == [3, tokenizer.unknownTokenID, 0])
}
