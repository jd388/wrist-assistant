import Foundation

/// A watchOS-friendly Marian SentencePiece runtime.
///
/// The matching exporter stores a compact Unicode-scalar trie, source-side
/// Unigram scores, Marian's final combined vocabulary IDs, and the target-side
/// ID-to-piece table. Tokenization therefore does not require Python,
/// Transformers, protobuf, or the SentencePiece C++ library at runtime.
public struct SentencePieceTokenizer: Sendable {
    public enum ResourceError: Error, Equatable, LocalizedError, Sendable {
        case truncated
        case invalidMagic
        case unsupportedVersion(UInt32)
        case invalidUTF8
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .truncated:
                "SentencePiece resource is truncated."
            case .invalidMagic:
                "This is not a LexiWatch SentencePiece resource."
            case let .unsupportedVersion(version):
                "Unsupported SentencePiece resource version: \(version)."
            case .invalidUTF8:
                "SentencePiece resource contains invalid UTF-8."
            case let .invalidValue(message):
                "Invalid SentencePiece resource: \(message)"
            }
        }
    }

    public let unknownTokenID: Int32
    public let endOfSequenceTokenID: Int32
    public let paddingTokenID: Int32
    public let beginningOfSequenceTokenID: Int32

    public var vocabularySize: Int { targetPieces.count }

    private static let magic = Array("LXSPUNI1".utf8)
    private static let formatVersion: UInt32 = 1
    private static let addDummyPrefixFlag: UInt32 = 1 << 0
    private static let removeExtraWhitespacesFlag: UInt32 = 1 << 1
    private static let escapeWhitespacesFlag: UInt32 = 1 << 2
    private static let supportedFlags =
        addDummyPrefixFlag | removeExtraWhitespacesFlag | escapeWhitespacesFlag
    private static let metaspace: UInt32 = 0x2581
    private static let ordinarySpace: UInt32 = 0x20
    private static let userDefinedPiece: UInt8 = 4

    private struct TrieNode: Sendable {
        let firstEdge: Int
        let edgeCount: Int
        let tokenID: Int32
        let score: Float
        let pieceType: UInt8
    }

    private struct TrieEdge: Sendable {
        let scalar: UInt32
        let childIndex: Int
    }

    private struct BestPath: Sendable {
        var score: Float = -.infinity
        var startsAt = -1
        var tokenID: Int32 = -1
        var isUnknownSurface = false

        var isReachable: Bool { startsAt >= 0 || score == 0 }
    }

    private struct ResourceReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func readBytes(count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset <= bytes.count, count <= bytes.count - offset else {
                throw ResourceError.truncated
            }
            defer { offset += count }
            return bytes[offset ..< offset + count]
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < bytes.count else { throw ResourceError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func readUInt32() throws -> UInt32 {
            let value = try readBytes(count: 4)
            return value.enumerated().reduce(into: UInt32(0)) { result, element in
                result |= UInt32(element.element) << UInt32(element.offset * 8)
            }
        }

        mutating func readInt32() throws -> Int32 {
            Int32(bitPattern: try readUInt32())
        }

        mutating func readFloat32() throws -> Float {
            Float(bitPattern: try readUInt32())
        }
    }

    private let nodes: [TrieNode]
    private let edges: [TrieEdge]
    private let targetPieces: [String?]
    private let unknownScore: Float
    private let addDummyPrefix: Bool
    private let removeExtraWhitespaces: Bool
    private let escapeWhitespaces: Bool

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        var reader = ResourceReader(bytes: Array(data))
        guard Array(try reader.readBytes(count: Self.magic.count)) == Self.magic else {
            throw ResourceError.invalidMagic
        }

        let version = try reader.readUInt32()
        guard version == Self.formatVersion else {
            throw ResourceError.unsupportedVersion(version)
        }

        let flags = try reader.readUInt32()
        guard flags & ~Self.supportedFlags == 0 else {
            throw ResourceError.invalidValue("unknown normalizer flags")
        }
        addDummyPrefix = flags & Self.addDummyPrefixFlag != 0
        removeExtraWhitespaces = flags & Self.removeExtraWhitespacesFlag != 0
        escapeWhitespaces = flags & Self.escapeWhitespacesFlag != 0

        unknownTokenID = try reader.readInt32()
        endOfSequenceTokenID = try reader.readInt32()
        paddingTokenID = try reader.readInt32()
        beginningOfSequenceTokenID = try reader.readInt32()
        unknownScore = try reader.readFloat32()

        let nodeCount = Int(try reader.readUInt32())
        let edgeCount = Int(try reader.readUInt32())
        let targetCount = Int(try reader.readUInt32())
        let normalizerNameLength = Int(try reader.readUInt32())

        guard nodeCount > 0, nodeCount <= 10_000_000 else {
            throw ResourceError.invalidValue("invalid trie node count")
        }
        guard edgeCount >= 0, edgeCount <= 10_000_000 else {
            throw ResourceError.invalidValue("invalid trie edge count")
        }
        guard targetCount > 0, targetCount <= 10_000_000 else {
            throw ResourceError.invalidValue("invalid target vocabulary size")
        }
        guard unknownTokenID >= 0, Int(unknownTokenID) < targetCount else {
            throw ResourceError.invalidValue("unknown token ID is out of range")
        }
        guard unknownScore.isFinite else {
            throw ResourceError.invalidValue("unknown score is not finite")
        }

        let normalizerBytes = try reader.readBytes(count: normalizerNameLength)
        guard let normalizerName = String(bytes: normalizerBytes, encoding: .utf8) else {
            throw ResourceError.invalidUTF8
        }
        guard normalizerName == "nmt_nfkc" || normalizerName == "nfkc" else {
            throw ResourceError.invalidValue("unsupported normalizer \(normalizerName)")
        }

        var parsedNodes: [TrieNode] = []
        parsedNodes.reserveCapacity(nodeCount)
        for _ in 0 ..< nodeCount {
            let firstEdge = Int(try reader.readUInt32())
            let currentEdgeCount = Int(try reader.readUInt32())
            let tokenID = try reader.readInt32()
            let score = try reader.readFloat32()
            let pieceType = try reader.readUInt8()
            _ = try reader.readBytes(count: 3)

            guard firstEdge <= edgeCount, currentEdgeCount <= edgeCount - firstEdge else {
                throw ResourceError.invalidValue("trie node has an invalid edge range")
            }
            guard tokenID == -1 || (tokenID >= 0 && Int(tokenID) < targetCount) else {
                throw ResourceError.invalidValue("source token ID is out of range")
            }
            guard score.isFinite else {
                throw ResourceError.invalidValue("source score is not finite")
            }
            parsedNodes.append(
                TrieNode(
                    firstEdge: firstEdge,
                    edgeCount: currentEdgeCount,
                    tokenID: tokenID,
                    score: score,
                    pieceType: pieceType
                )
            )
        }

        var parsedEdges: [TrieEdge] = []
        parsedEdges.reserveCapacity(edgeCount)
        for _ in 0 ..< edgeCount {
            let scalar = try reader.readUInt32()
            let childIndex = Int(try reader.readUInt32())
            guard UnicodeScalar(scalar) != nil else {
                throw ResourceError.invalidValue("trie edge is not a Unicode scalar")
            }
            guard childIndex >= 0, childIndex < nodeCount else {
                throw ResourceError.invalidValue("trie child index is out of range")
            }
            parsedEdges.append(TrieEdge(scalar: scalar, childIndex: childIndex))
        }

        for node in parsedNodes where node.edgeCount > 1 {
            let range = node.firstEdge ..< node.firstEdge + node.edgeCount
            for index in range.dropFirst() where parsedEdges[index - 1].scalar >= parsedEdges[index].scalar {
                throw ResourceError.invalidValue("trie edges are not strictly sorted")
            }
        }

        var parsedTargets: [String?] = []
        parsedTargets.reserveCapacity(targetCount)
        for _ in 0 ..< targetCount {
            let length = try reader.readUInt32()
            if length == UInt32.max {
                parsedTargets.append(nil)
                continue
            }
            let pieceBytes = try reader.readBytes(count: Int(length))
            guard let piece = String(bytes: pieceBytes, encoding: .utf8) else {
                throw ResourceError.invalidUTF8
            }
            parsedTargets.append(piece)
        }

        guard reader.offset == reader.bytes.count else {
            throw ResourceError.invalidValue("resource has trailing bytes")
        }

        nodes = parsedNodes
        edges = parsedEdges
        targetPieces = parsedTargets
    }

    /// Encodes text to Marian's final combined vocabulary IDs.
    ///
    /// Adjacent unknown Unicode scalars are collapsed to one unknown token,
    /// matching SentencePieceProcessor's public encode result.
    public func encode(_ text: String, addEndOfSequence: Bool = true) -> [Int32] {
        let scalars = normalizedScalars(text)
        guard !scalars.isEmpty else {
            return addEndOfSequence && endOfSequenceTokenID >= 0
                ? [endOfSequenceTokenID]
                : []
        }

        var paths = Array(repeating: BestPath(), count: scalars.count + 1)
        paths[0].score = 0

        for startsAt in scalars.indices where paths[startsAt].isReachable {
            let scoreToStart = paths[startsAt].score
            var nodeIndex = 0
            var hasSingleScalarPiece = false

            for endsAt in startsAt ..< scalars.count {
                guard let childIndex = child(of: nodeIndex, matching: scalars[endsAt]) else {
                    break
                }
                nodeIndex = childIndex
                let node = nodes[nodeIndex]
                guard node.tokenID >= 0 else { continue }

                let scalarLength = endsAt - startsAt + 1
                if scalarLength == 1 {
                    hasSingleScalarPiece = true
                }
                let pieceScore = node.pieceType == Self.userDefinedPiece
                    ? Float(scalarLength - 1) * 0.1
                    : node.score
                update(
                    &paths[endsAt + 1],
                    candidateScore: scoreToStart + pieceScore,
                    startsAt: startsAt,
                    tokenID: node.tokenID,
                    isUnknownSurface: false
                )
            }

            if !hasSingleScalarPiece {
                update(
                    &paths[startsAt + 1],
                    candidateScore: scoreToStart + unknownScore,
                    startsAt: startsAt,
                    tokenID: unknownTokenID,
                    isUnknownSurface: true
                )
            }
        }

        var reversed: [(tokenID: Int32, isUnknownSurface: Bool)] = []
        reversed.reserveCapacity(scalars.count)
        var endsAt = scalars.count
        while endsAt > 0 {
            let path = paths[endsAt]
            guard path.startsAt >= 0 else {
                // A valid exported Unigram trie always has either a one-scalar
                // piece or an unknown fallback at every position.
                return addEndOfSequence && endOfSequenceTokenID >= 0
                    ? [unknownTokenID, endOfSequenceTokenID]
                    : [unknownTokenID]
            }
            reversed.append((path.tokenID, path.isUnknownSurface))
            endsAt = path.startsAt
        }

        var result: [Int32] = []
        result.reserveCapacity(reversed.count + (addEndOfSequence ? 1 : 0))
        var previousWasUnknownSurface = false
        for item in reversed.reversed() {
            if item.isUnknownSurface, previousWasUnknownSurface {
                continue
            }
            result.append(item.tokenID)
            previousWasUnknownSurface = item.isUnknownSurface
        }
        if addEndOfSequence, endOfSequenceTokenID >= 0 {
            result.append(endOfSequenceTokenID)
        }
        return result
    }

    /// Decodes target vocabulary IDs using Marian's target piece mapping.
    public func decode(
        _ tokenIDs: [Int32],
        skipSpecialTokens: Bool = true
    ) -> String {
        var output = ""
        output.reserveCapacity(tokenIDs.count * 3)

        for tokenID in tokenIDs {
            guard tokenID >= 0, Int(tokenID) < targetPieces.count else { continue }
            if isSpecial(tokenID) {
                if !skipSpecialTokens, tokenID == unknownTokenID {
                    output.append("⁇")
                } else if !skipSpecialTokens, let piece = targetPieces[Int(tokenID)] {
                    output.append(piece)
                    output.append(" ")
                }
                continue
            }
            guard let piece = targetPieces[Int(tokenID)] else { continue }
            output.append(piece)
        }

        return output
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedText(_ text: String) -> String {
        let scalars = normalizedScalars(text).compactMap(UnicodeScalar.init)
        return String(String.UnicodeScalarView(scalars))
    }

    private func normalizedScalars(_ text: String) -> [UInt32] {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let separator = escapeWhitespaces ? Self.metaspace : Self.ordinarySpace
        var output: [UInt32] = []
        output.reserveCapacity(nfkc.unicodeScalars.count + (addDummyPrefix ? 1 : 0))
        var pendingWhitespace = false

        for scalar in nfkc.unicodeScalars {
            if Self.isWhitespace(scalar) {
                if removeExtraWhitespaces {
                    pendingWhitespace = !output.isEmpty
                } else {
                    output.append(separator)
                }
                continue
            }

            if output.isEmpty, addDummyPrefix {
                output.append(separator)
            } else if pendingWhitespace {
                output.append(separator)
            }
            pendingWhitespace = false
            output.append(scalar.value)
        }
        return output
    }

    private static func isWhitespace(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func child(of nodeIndex: Int, matching scalar: UInt32) -> Int? {
        let node = nodes[nodeIndex]
        var lower = node.firstEdge
        var upper = node.firstEdge + node.edgeCount
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let edge = edges[middle]
            if edge.scalar < scalar {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < node.firstEdge + node.edgeCount, edges[lower].scalar == scalar else {
            return nil
        }
        return edges[lower].childIndex
    }

    private func update(
        _ path: inout BestPath,
        candidateScore: Float,
        startsAt: Int,
        tokenID: Int32,
        isUnknownSurface: Bool
    ) {
        if path.startsAt == -1 || candidateScore > path.score {
            path.score = candidateScore
            path.startsAt = startsAt
            path.tokenID = tokenID
            path.isUnknownSurface = isUnknownSurface
        }
    }

    private func isSpecial(_ tokenID: Int32) -> Bool {
        tokenID == unknownTokenID
            || tokenID == endOfSequenceTokenID
            || tokenID == paddingTokenID
            || tokenID == beginningOfSequenceTokenID
    }
}
