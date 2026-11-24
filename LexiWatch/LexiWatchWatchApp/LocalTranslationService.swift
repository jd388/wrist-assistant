import CoreML
import Darwin
import Foundation

// Core ML's async API is available on watchOS but its Objective-C model class
// is not annotated Sendable yet. This service keeps each model actor-isolated
// and never performs overlapping predictions on the same instance.
extension MLModel: @retroactive @unchecked Sendable {}

struct LocalTranslation: Equatable, Sendable {
    enum Source: String, Sendable {
        case model
        case deterministicNumber

        var label: String {
            switch self {
            case .model: "本地翻译"
            case .deterministicNumber: "即时转换"
            }
        }

        var systemImage: String {
            switch self {
            case .model: "memorychip.fill"
            case .deterministicNumber: "number.square.fill"
            }
        }
    }

    enum Direction: String, Sendable {
        case chineseToEnglish = "zh-en"
        case englishToChinese = "en-zh"

        var label: String {
            switch self {
            case .chineseToEnglish: "中文 → 英文"
            case .englishToChinese: "英文 → 中文"
            }
        }
    }

    let original: String
    let translated: String
    let direction: Direction
    let source: Source

    init(
        original: String,
        translated: String,
        direction: Direction,
        source: Source = .model
    ) {
        self.original = original
        self.translated = translated
        self.direction = direction
        self.source = source
    }

    var routeLabel: String {
        switch source {
        case .model: direction.label
        case .deterministicNumber: "数字 → 英文"
        }
    }
}

enum LocalTranslationError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case inputTooLong
    case modelMissing
    case modelLoadFailed
    case inferenceFailed
    case outputTooLong
    case unstableOutput
    case unsafeOutput

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "无法处理这次输入。"
        case .inputTooLong:
            "内容太长，自动分段后仍超出手表处理范围，请分两次翻译。"
        case .modelMissing:
            "本地翻译模型不完整，请重新安装应用。"
        case .modelLoadFailed:
            "本地翻译模型暂时无法载入，请稍后重试。"
        case .inferenceFailed:
            "本地模型没有生成可靠结果，原句已保留。"
        case .outputTooLong:
            "本地模型没有正常结束生成，已停止显示不完整结果。"
        case .unstableOutput:
            "本地模型生成了异常重复内容，已拦截这次结果。"
        case .unsafeOutput:
            "本地模型生成了明显异常的文本，已拦截这次结果。"
        }
    }
}

enum LocalTranslationProfile: String, CaseIterable {
    case standard
    case quickMT

    static let preferenceKey = "dictionaryTranslationProfile"

    var title: String {
        switch self {
        case .standard: "轻量 · 约 7800 万参数"
        case .quickMT: "进阶 · 约 2 亿参数"
        }
    }

    private struct Validation: Decodable {
        let machine: String
        let watchOS: String
        let computeUnits: String
    }

    static func available(in bundle: Bundle = .main) -> [Self] {
        var profiles: [Self] = [.standard]
        if quickMTValidation(in: bundle) != nil,
           bundle.url(forResource: "QuickMTEncoder", withExtension: "mlmodelc") != nil,
           bundle.url(forResource: "QuickMTDecoder", withExtension: "mlmodelc") != nil,
           bundle.url(forResource: "QuickMTSource", withExtension: "spmlex") != nil,
           bundle.url(forResource: "QuickMTTarget", withExtension: "spmlex") != nil {
            profiles.append(.quickMT)
        }
        return profiles
    }

    private static func quickMTValidation(in bundle: Bundle) -> Validation? {
        guard let url = bundle.url(forResource: "QuickMTValidation", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Validation].self, from: data) else { return nil }
        var system = utsname()
        guard uname(&system) == 0 else { return nil }
        let machine = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return values.first { $0.machine == machine && $0.watchOS == version }
    }

    static func quickMTComputeUnits(in bundle: Bundle) -> MLComputeUnits {
        quickMTValidation(in: bundle)?.computeUnits == "cpuAndNeuralEngine" ? .cpuAndNeuralEngine : .cpuOnly
    }
}

/// Runs both translation directions entirely inside the Watch app.
///
/// Only one encoder/decoder pair is retained at a time so switching direction
/// releases the other direction's large Core ML weights.
actor LocalTranslationService {
    private struct ModelNames {
        let encoder: String
        let decoder: String
        let tokenizer: String
        var targetTokenizer: String? = nil
    }

    private struct LoadedModels {
        let direction: LocalTranslation.Direction
        let profile: LocalTranslationProfile
        let encoder: MLModel
        let decoder: MLModel
        let tokenizer: SentencePieceTokenizer
        let targetTokenizer: SentencePieceTokenizer
    }

    private static let maximumTokens = 32
    private static let maximumSegments = 8
    private static let chineseToEnglishSegmentTokens = 18
    private static let englishToChineseSegmentTokens = 28

    private let bundle: Bundle
    private let translationGate = CancellationAwareSerialGate()
    private var loadedModels: LoadedModels?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func translate(_ query: String) async throws -> LocalTranslation {
        try await translationGate.withExclusiveAccess {
            try await self.performTranslation(query)
        }
    }

    private func performTranslation(_ query: String) async throws -> LocalTranslation {
        try Task.checkCancellation()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalTranslationError.invalidRequest }

        let direction: LocalTranslation.Direction = DictionarySearchEngine.containsChinese(trimmed)
            ? .chineseToEnglish
            : .englishToChinese
        let preferred = UserDefaults.standard.string(forKey: LocalTranslationProfile.preferenceKey)
            .flatMap(LocalTranslationProfile.init(rawValue:)) ?? .standard
        let profile = direction == .englishToChinese &&
            LocalTranslationProfile.available(in: bundle).contains(preferred) ? preferred : .standard
        do {
            return try await performTranslation(trimmed, direction: direction, profile: profile)
        } catch is CancellationError {
            throw CancellationError()
        } catch where profile != .standard {
            return try await performTranslation(trimmed, direction: direction, profile: .standard)
        }
    }

    private func performTranslation(
        _ trimmed: String, direction: LocalTranslation.Direction, profile: LocalTranslationProfile
    ) async throws -> LocalTranslation {
        let models = try await models(for: direction, profile: profile)
        try Task.checkCancellation()

        do {
            let segmentTokenLimit = direction == .chineseToEnglish
                ? Self.chineseToEnglishSegmentTokens
                : Self.englishToChineseSegmentTokens
            let segments = try translationSegments(
                trimmed,
                tokenizer: models.tokenizer,
                tokenLimit: segmentTokenLimit,
                addsSourceEnd: models.profile == .standard
            )
            var translatedSegments: [String] = []
            translatedSegments.reserveCapacity(segments.count)
            for segment in segments {
                try Task.checkCancellation()
                translatedSegments.append(
                    try await translateSegment(
                        segment,
                        direction: direction,
                        models: models
                    )
                )
            }

            let translated = translatedSegments.joined(
                separator: direction == .chineseToEnglish ? " " : ""
            )
            if hasObviousOutputAnomaly(translated, original: trimmed) {
                throw LocalTranslationError.unsafeOutput
            }
            guard isPlausible(
                translated,
                original: trimmed,
                direction: direction
            ) else {
                throw LocalTranslationError.inferenceFailed
            }

            return LocalTranslation(
                original: trimmed,
                translated: translated,
                direction: direction
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalTranslationError {
            throw error
        } catch {
            throw LocalTranslationError.inferenceFailed
        }
    }

    private func translateSegment(
        _ source: String,
        direction: LocalTranslation.Direction,
        models: LoadedModels
    ) async throws -> String {
        var sourceIDs = models.tokenizer.encode(source, addEndOfSequence: models.profile == .standard)
        guard !sourceIDs.isEmpty, sourceIDs.count <= Self.maximumTokens else {
            throw LocalTranslationError.inputTooLong
        }

        let paddingID = models.tokenizer.paddingTokenID
        sourceIDs.append(
            contentsOf: repeatElement(
                paddingID,
                count: Self.maximumTokens - sourceIDs.count
            )
        )
        let sourceMask = sourceIDs.map { $0 == paddingID ? Int32(0) : Int32(1) }
        let sourceIDArray = try multiArray(sourceIDs, dataType: .int32)
        let sourceMaskArray = try multiArray(sourceMask, dataType: .int32)
        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: sourceIDArray),
            "attention_mask": MLFeatureValue(multiArray: sourceMaskArray),
        ])
        let encoderOutput = try await models.encoder.prediction(from: encoderInput)
        guard let hiddenStates = encoderOutput
            .featureValue(for: "encoder_hidden_states")?
            .multiArrayValue else {
            throw LocalTranslationError.inferenceFailed
        }

        let generated = try await decode(
            with: models.decoder,
            tokenizer: models.targetTokenizer,
            decoderStartsWithBOS: models.profile == .quickMT,
            hiddenStates: hiddenStates,
            sourceMask: sourceMaskArray
        )
        let translated = models.targetTokenizer.decode(generated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hasObviousOutputAnomaly(translated, original: source) {
            throw LocalTranslationError.unsafeOutput
        }
        guard isPlausible(
            translated,
            original: source,
            direction: direction
        ) else {
            throw LocalTranslationError.inferenceFailed
        }
        return translated
    }

    private func translationSegments(
        _ source: String,
        tokenizer: SentencePieceTokenizer,
        tokenLimit: Int,
        addsSourceEnd: Bool
    ) throws -> [String] {
        if tokenizer.encode(source, addEndOfSequence: addsSourceEnd).count <= tokenLimit {
            return [source]
        }

        var remaining = Array(source)
        var result: [String] = []
        while !remaining.isEmpty {
            var low = 1
            var high = remaining.count
            var largestFittingCount = 0
            while low <= high {
                let middle = (low + high) / 2
                let candidate = String(remaining.prefix(middle))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty,
                   tokenizer.encode(candidate, addEndOfSequence: addsSourceEnd).count <= tokenLimit {
                    largestFittingCount = middle
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }

            guard largestFittingCount > 0 else {
                throw LocalTranslationError.inputTooLong
            }

            var splitCount = largestFittingCount
            if largestFittingCount < remaining.count {
                let earliestNaturalBreak = max(0, largestFittingCount / 2 - 1)
                for index in stride(
                    from: largestFittingCount - 1,
                    through: earliestNaturalBreak,
                    by: -1
                ) where isNaturalBreak(remaining[index]) {
                    splitCount = index + 1
                    break
                }
            }

            let segment = String(remaining.prefix(splitCount))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            remaining.removeFirst(splitCount)
            while remaining.first?.isWhitespace == true {
                remaining.removeFirst()
            }
            guard !segment.isEmpty else { continue }
            result.append(segment)
            guard result.count <= Self.maximumSegments else {
                throw LocalTranslationError.inputTooLong
            }
        }
        return result
    }

    private func isNaturalBreak(_ character: Character) -> Bool {
        character.isWhitespace || ".!?。！？；;，,:：、".contains(character)
    }

    private func models(
        for direction: LocalTranslation.Direction, profile: LocalTranslationProfile
    ) async throws -> LoadedModels {
        if let loadedModels, loadedModels.direction == direction, loadedModels.profile == profile {
            return loadedModels
        }

        // Release the previous direction before loading the next large pair.
        loadedModels = nil
        let names = modelNames(for: direction, profile: profile)
        guard let encoderURL = bundle.url(forResource: names.encoder, withExtension: "mlmodelc"),
              let decoderURL = bundle.url(forResource: names.decoder, withExtension: "mlmodelc"),
              let tokenizerURL = bundle.url(forResource: names.tokenizer, withExtension: "spmlex") else {
            throw LocalTranslationError.modelMissing
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = profile == .quickMT
                ? LocalTranslationProfile.quickMTComputeUnits(in: bundle)
                : .cpuAndNeuralEngine
            let encoder = try await MLModel.load(
                contentsOf: encoderURL,
                configuration: configuration
            )
            let decoder = try await MLModel.load(
                contentsOf: decoderURL,
                configuration: configuration
            )
            let tokenizer = try SentencePieceTokenizer(contentsOf: tokenizerURL)
            let targetTokenizer: SentencePieceTokenizer
            if let name = names.targetTokenizer {
                guard let url = bundle.url(forResource: name, withExtension: "spmlex") else {
                    throw LocalTranslationError.modelMissing
                }
                targetTokenizer = try SentencePieceTokenizer(contentsOf: url)
            } else {
                targetTokenizer = tokenizer
            }
            let loaded = LoadedModels(
                direction: direction,
                profile: profile,
                encoder: encoder,
                decoder: decoder,
                tokenizer: tokenizer,
                targetTokenizer: targetTokenizer
            )
            loadedModels = loaded
            return loaded
        } catch let error as LocalTranslationError {
            throw error
        } catch {
            throw LocalTranslationError.modelLoadFailed
        }
    }

    private func decode(
        with decoder: MLModel,
        tokenizer: SentencePieceTokenizer,
        decoderStartsWithBOS: Bool,
        hiddenStates: MLMultiArray,
        sourceMask: MLMultiArray
    ) async throws -> [Int32] {
        let paddingID = tokenizer.paddingTokenID
        var decoderIDs = Array(repeating: paddingID, count: Self.maximumTokens)
        if decoderStartsWithBOS { decoderIDs[0] = tokenizer.beginningOfSequenceTokenID }
        var decoderMask = Array(repeating: Int32(0), count: Self.maximumTokens)
        decoderMask[0] = 1

        let decoderIDArray = try multiArray(decoderIDs, dataType: .int32)
        let decoderMaskArray = try multiArray(decoderMask, dataType: .int32)
        let selectorArray = try multiArray(
            Array(repeating: Int32(0), count: Self.maximumTokens),
            dataType: .float16
        )
        var generated: [Int32] = []
        generated.reserveCapacity(Self.maximumTokens - 1)

        for position in 0 ..< Self.maximumTokens - 1 {
            try Task.checkCancellation()
            try write(decoderIDs, to: decoderIDArray)
            try write(decoderMask, to: decoderMaskArray)
            try writeSelector(position: position, to: selectorArray)

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "decoder_input_ids": MLFeatureValue(multiArray: decoderIDArray),
                "decoder_attention_mask": MLFeatureValue(multiArray: decoderMaskArray),
                "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates),
                "encoder_attention_mask": MLFeatureValue(multiArray: sourceMask),
                "decode_selector": MLFeatureValue(multiArray: selectorArray),
            ])
            let output = try await decoder.prediction(from: input)
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
                throw LocalTranslationError.inferenceFailed
            }
            let nextToken = try argmax(logits)
            if nextToken == tokenizer.endOfSequenceTokenID {
                return generated
            }

            generated.append(nextToken)
            if hasRunawayTokenRepetition(generated) {
                throw LocalTranslationError.unstableOutput
            }
            decoderIDs[position + 1] = nextToken
            decoderMask[position + 1] = 1
        }

        throw LocalTranslationError.outputTooLong
    }

    private func modelNames(for direction: LocalTranslation.Direction, profile: LocalTranslationProfile) -> ModelNames {
        if profile == .quickMT {
            return ModelNames(
                encoder: "QuickMTEncoder", decoder: "QuickMTDecoder",
                tokenizer: "QuickMTSource", targetTokenizer: "QuickMTTarget"
            )
        }
        return switch direction {
        case .chineseToEnglish:
            ModelNames(
                encoder: "LocalZhEnEncoder",
                decoder: "LocalZhEnDecoder",
                tokenizer: "ZhEnTokenizer"
            )
        case .englishToChinese:
            ModelNames(
                encoder: "LocalEnZhEncoder",
                decoder: "LocalEnZhDecoder",
                tokenizer: "EnZhTokenizer"
            )
        }
    }

    private func multiArray(
        _ values: [Int32],
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: Self.maximumTokens)],
            dataType: dataType
        )
        switch dataType {
        case .int32:
            try write(values, to: array)
        case .float16:
            try array.withUnsafeMutableBytes { bytes, _ in
                let destination = bytes.bindMemory(to: Float16.self)
                guard destination.count >= values.count else {
                    throw LocalTranslationError.inferenceFailed
                }
                for index in values.indices {
                    destination[index] = Float16(values[index])
                }
            }
        default:
            throw LocalTranslationError.inferenceFailed
        }
        return array
    }

    private func write(_ values: [Int32], to array: MLMultiArray) throws {
        guard array.dataType == .int32, values.count == array.count else {
            throw LocalTranslationError.inferenceFailed
        }
        try array.withUnsafeMutableBytes { bytes, _ in
            let destination = bytes.bindMemory(to: Int32.self)
            guard destination.count >= values.count else {
                throw LocalTranslationError.inferenceFailed
            }
            for index in values.indices {
                destination[index] = values[index]
            }
        }
    }

    private func writeSelector(position: Int, to array: MLMultiArray) throws {
        guard array.dataType == .float16,
              position >= 0,
              position < array.count else {
            throw LocalTranslationError.inferenceFailed
        }
        try array.withUnsafeMutableBytes { bytes, _ in
            let destination = bytes.bindMemory(to: Float16.self)
            guard destination.count >= array.count else {
                throw LocalTranslationError.inferenceFailed
            }
            destination.initialize(repeating: 0)
            destination[position] = 1
        }
    }

    private func argmax(_ logits: MLMultiArray) throws -> Int32 {
        guard logits.count > 0, logits.strides.last?.intValue == 1 else {
            throw LocalTranslationError.inferenceFailed
        }

        let bestIndex: Int = try logits.withUnsafeBytes { bytes in
            switch logits.dataType {
            case .float16:
                let values = bytes.bindMemory(to: Float16.self)
                guard values.count >= logits.count else {
                    throw LocalTranslationError.inferenceFailed
                }
                return maximumIndex(values.prefix(logits.count))
            case .float32:
                let values = bytes.bindMemory(to: Float.self)
                guard values.count >= logits.count else {
                    throw LocalTranslationError.inferenceFailed
                }
                return maximumIndex(values.prefix(logits.count))
            case .double:
                let values = bytes.bindMemory(to: Double.self)
                guard values.count >= logits.count else {
                    throw LocalTranslationError.inferenceFailed
                }
                return maximumIndex(values.prefix(logits.count))
            default:
                throw LocalTranslationError.inferenceFailed
            }
        }
        guard bestIndex <= Int(Int32.max) else {
            throw LocalTranslationError.inferenceFailed
        }
        return Int32(bestIndex)
    }

    private func maximumIndex<C: Collection>(_ values: C) -> Int where C.Element: Comparable {
        var bestOffset = 0
        var bestValue = values[values.startIndex]
        for (offset, value) in values.enumerated().dropFirst() where value > bestValue {
            bestOffset = offset
            bestValue = value
        }
        return bestOffset
    }

    private func hasRunawayTokenRepetition(_ tokenIDs: [Int32]) -> Bool {
        guard tokenIDs.count >= 4 else { return false }
        if tokenIDs.suffix(4).allSatisfy({ $0 == tokenIDs.last }) {
            return true
        }

        let maximumPatternLength = min(6, tokenIDs.count / 3)
        guard maximumPatternLength >= 2 else { return false }
        for length in 2 ... maximumPatternLength {
            let end = tokenIDs.endIndex
            let latest = tokenIDs[(end - length) ..< end]
            let previous = tokenIDs[(end - 2 * length) ..< (end - length)]
            let earliest = tokenIDs[(end - 3 * length) ..< (end - 2 * length)]
            if latest.elementsEqual(previous), previous.elementsEqual(earliest) {
                return true
            }
        }
        return false
    }

    private func isPlausible(
        _ translated: String,
        original: String,
        direction: LocalTranslation.Direction
    ) -> Bool {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              DictionarySearchEngine.normalize(trimmed)
                != DictionarySearchEngine.normalize(original) else {
            return false
        }

        let containsHan = DictionarySearchEngine.containsChinese(trimmed)
        let containsLatin = trimmed.unicodeScalars.contains {
            (0x0041 ... 0x005A).contains($0.value)
                || (0x0061 ... 0x007A).contains($0.value)
        }
        switch direction {
        case .chineseToEnglish:
            return containsLatin && !containsHan
        case .englishToChinese:
            return containsHan
        }
    }

    private func hasObviousOutputAnomaly(_ translated: String, original: String) -> Bool {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let modelArtifacts = ["<unk>", "<pad>", "</s>", "<s>", "�"]
        if modelArtifacts.contains(where: lowered.contains)
            || containsUnsafeScalars(trimmed)
            || hasRunawayTextRepetition(trimmed) {
            return true
        }

        let originalCount = max(1, original.filter { !$0.isWhitespace }.count)
        let translatedCount = trimmed.filter { !$0.isWhitespace }.count
        return translatedCount > 1_024
            || translatedCount > max(64, originalCount * 8)
    }

    private func containsUnsafeScalars(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if (0xE000 ... 0xF8FF).contains(value) { return true }
            if value < 0x20, scalar != "\n", scalar != "\t" { return true }
            return false
        }
    }

    private func hasRunawayTextRepetition(_ text: String) -> Bool {
        let characters = Array(text.lowercased().filter { !$0.isWhitespace })
        guard characters.count >= 4 else { return false }

        if characters.suffix(4).allSatisfy({ $0 == characters.last }) {
            return true
        }

        let maximumPatternLength = min(20, characters.count / 3)
        guard maximumPatternLength >= 2 else { return false }
        for length in 2 ... maximumPatternLength {
            let end = characters.endIndex
            let latest = characters[(end - length) ..< end]
            let previous = characters[(end - 2 * length) ..< (end - length)]
            let earliest = characters[(end - 3 * length) ..< (end - 2 * length)]
            if latest.elementsEqual(previous), previous.elementsEqual(earliest) {
                return true
            }
        }
        return false
    }
}
