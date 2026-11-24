import Foundation

/// Removes source-formatting artifacts that otherwise render as tofu or
/// literal black squares on Apple Watch.
///
/// The sanitizer is intentionally conservative: it preserves assigned text,
/// including IPA, combining marks, CJK, punctuation and teaching arrows. It
/// only handles markers observed in the bundled sources, Unicode values that
/// cannot have a portable glyph, controls, box-drawing corruption, and ASCII
/// HTML-like tags left by an older ECDICT import.
public enum DictionaryTextSanitizer {
    public static func sanitize(_ value: String) -> String {
        guard requiresCleaning(value) else { return value }

        let decoded = decodeHTMLEntities(value)
        let withoutTags = stripASCIIHTMLTags(decoded)
        var output = String.UnicodeScalarView()
        var pendingSpace = false

        for scalar in withoutTags.unicodeScalars {
            let codePoint = scalar.value
            let category = scalar.properties.generalCategory

            if codePoint == 0x25A0 || codePoint == 0x25B6 {
                pendingSpace = false
                while output.last == " " { output.removeLast() }
                if let last = output.last, last != "；", last != ";" {
                    output.append("；")
                }
                continue
            }

            let isBoxDrawing = (0x2500 ... 0x257F).contains(codePoint)
            let hasNoPortableGlyph = category == .privateUse
                || category == .surrogate
                || category == .unassigned
                || codePoint == 0xFFFD
            if isBoxDrawing || hasNoPortableGlyph || category == .control {
                pendingSpace = true
                continue
            }
            if category == .format {
                continue
            }
            if category == .spaceSeparator
                || category == .lineSeparator
                || category == .paragraphSeparator {
                pendingSpace = true
                continue
            }

            if pendingSpace,
               !output.isEmpty,
               output.last != " ",
               !isClosingPunctuation(scalar) {
                output.append(" ")
            }
            pendingSpace = false
            output.append(scalar)
        }

        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sanitize(_ value: String?) -> String? {
        value.map(sanitize)
    }

    private static func requiresCleaning(_ value: String) -> Bool {
        if value.contains("<") || value.contains("&") { return true }

        return value.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return scalar.value == 0x25A0
                || scalar.value == 0x25B6
                || scalar.value == 0xFFFD
                || (0x2500 ... 0x257F).contains(scalar.value)
                || category == .privateUse
                || category == .surrogate
                || category == .unassigned
                || category == .control
                || category == .format
        }
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            guard scalars[index] == "&" else {
                output.append(scalars[index])
                index += 1
                continue
            }

            let searchEnd = min(index + 14, scalars.count)
            guard let semicolon = (index + 1 ..< searchEnd).first(where: {
                scalars[$0] == ";"
            }) else {
                output.append(scalars[index])
                index += 1
                continue
            }

            let body = String(String.UnicodeScalarView(scalars[index + 1 ..< semicolon]))
            guard let replacement = decodedEntity(body) else {
                output.append(scalars[index])
                index += 1
                continue
            }
            output.append(contentsOf: replacement.unicodeScalars)
            index = semicolon + 1
        }

        return String(output)
    }

    private static func decodedEntity(_ body: String) -> String? {
        switch body.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39", "#x27": return "'"
        case "nbsp": return " "
        default: break
        }

        let number: UInt32?
        if body.lowercased().hasPrefix("#x") {
            number = UInt32(body.dropFirst(2), radix: 16)
        } else if body.hasPrefix("#") {
            number = UInt32(body.dropFirst(), radix: 10)
        } else {
            number = nil
        }
        guard let number, let scalar = UnicodeScalar(number) else { return nil }
        return String(scalar)
    }

    private static func stripASCIIHTMLTags(_ value: String) -> String {
        guard value.contains("<") else { return value }
        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            guard scalars[index] == "<" else {
                output.append(scalars[index])
                index += 1
                continue
            }

            let searchEnd = min(index + 82, scalars.count)
            guard let closing = (index + 1 ..< searchEnd).first(where: {
                scalars[$0] == ">"
            }),
            isASCIIHTMLTag(scalars[index + 1 ..< closing]) else {
                output.append(scalars[index])
                index += 1
                continue
            }

            output.append(" ")
            index = closing + 1
        }

        return String(output)
    }

    private static func isASCIIHTMLTag(_ content: ArraySlice<UnicodeScalar>) -> Bool {
        let trimmed = content.drop(while: { $0.properties.isWhitespace })
            .reversed()
            .drop(while: { $0.properties.isWhitespace })
            .reversed()
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII }) else { return false }

        var index = trimmed.startIndex
        if trimmed[index] == "/" {
            index = trimmed.index(after: index)
            guard index < trimmed.endIndex else { return false }
        }
        if trimmed[index] == "!" || trimmed[index] == "?" { return true }
        let value = trimmed[index].value
        return (65 ... 90).contains(value) || (97 ... 122).contains(value)
    }

    private static func isClosingPunctuation(_ scalar: UnicodeScalar) -> Bool {
        switch scalar {
        case "；", ";", "，", ",", "。", ".", "：", ":", "！", "!", "？", "?",
             ")", "）", "]", "】", "}", "》", "、":
            return true
        default:
            return false
        }
    }
}

public struct DictionaryEntry: Codable, Hashable, Identifiable, Sendable {
    public struct RegionalPronunciation: Codable, Hashable, Sendable {
        public enum Region: String, Codable, Hashable, Sendable {
            case uk
            case us
        }

        public let ipa: String
        public let region: Region?
        public let partOfSpeech: String
    }

    public struct RelatedExpression: Codable, Hashable, Identifiable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable {
            case phrasalVerb
            case verbPattern
            case fixedPhrase

            fileprivate var displayOrder: Int {
                switch self {
                case .phrasalVerb: 0
                case .verbPattern: 1
                case .fixedPhrase: 2
                }
            }
        }

        public let text: String
        public let kind: Kind
        public let chinese: String
        public let example: String?
        public let exampleChinese: String?
        public let priority: Int
        public let partOfSpeech: String?

        public var id: String { "\(kind.rawValue):\(text)" }

        public init(
            text: String,
            kind: Kind,
            chinese: String,
            example: String? = nil,
            exampleChinese: String? = nil,
            priority: Int = 100,
            partOfSpeech: String? = nil
        ) {
            self.text = DictionaryTextSanitizer.sanitize(text)
            self.kind = kind
            self.chinese = DictionaryTextSanitizer.sanitize(chinese)
            self.example = DictionaryTextSanitizer.sanitize(example)
            self.exampleChinese = DictionaryTextSanitizer.sanitize(exampleChinese)
            self.priority = priority
            self.partOfSpeech = DictionaryTextSanitizer.sanitize(partOfSpeech)
        }
    }

    public struct Meaning: Codable, Hashable, Sendable {
        public let partOfSpeech: String
        public let chinese: String
        public let englishDefinition: String?
        public let collocations: [String]
        public let collocationDetails: [RelatedExpression]?
        public let example: String?
        public let exampleChinese: String?

        public init(
            partOfSpeech: String,
            chinese: String,
            englishDefinition: String? = nil,
            collocations: [String] = [],
            example: String? = nil,
            exampleChinese: String? = nil,
            collocationDetails: [RelatedExpression]? = nil
        ) {
            self.partOfSpeech = DictionaryTextSanitizer.sanitize(partOfSpeech)
            self.chinese = DictionaryTextSanitizer.sanitize(chinese)
            self.englishDefinition = DictionaryTextSanitizer.sanitize(englishDefinition)
            self.collocations = collocations.map(DictionaryTextSanitizer.sanitize)
            self.example = DictionaryTextSanitizer.sanitize(example)
            self.exampleChinese = DictionaryTextSanitizer.sanitize(exampleChinese)
            self.collocationDetails = collocationDetails
        }
    }

    public let id: String
    public let headword: String
    public let pronunciation: String?
    public let regionalPronunciations: [RegionalPronunciation]
    public let aliases: [String]
    public let keywords: [String]
    public let meanings: [Meaning]
    public let relatedExpressions: [RelatedExpression]
    public let level: String?
    public let source: String?
    public let priority: Int

    public init(
        id: String,
        headword: String,
        pronunciation: String? = nil,
        aliases: [String] = [],
        keywords: [String] = [],
        meanings: [Meaning],
        relatedExpressions: [RelatedExpression] = [],
        level: String? = nil,
        source: String? = nil,
        priority: Int = 30_000,
        regionalPronunciations: [RegionalPronunciation] = []
    ) {
        self.id = DictionaryTextSanitizer.sanitize(id)
        self.headword = DictionaryTextSanitizer.sanitize(headword)
        self.pronunciation = DictionaryTextSanitizer.sanitize(pronunciation)
        self.regionalPronunciations = regionalPronunciations
        self.aliases = aliases.map(DictionaryTextSanitizer.sanitize)
        self.keywords = keywords.map(DictionaryTextSanitizer.sanitize)
        self.meanings = meanings.map {
            Meaning(
                partOfSpeech: $0.partOfSpeech,
                chinese: $0.chinese,
                englishDefinition: $0.englishDefinition,
                collocations: $0.collocations,
                example: $0.example,
                exampleChinese: $0.exampleChinese,
                collocationDetails: $0.collocationDetails
            )
        }
        self.relatedExpressions = relatedExpressions.map {
            RelatedExpression(
                text: $0.text,
                kind: $0.kind,
                chinese: $0.chinese,
                example: $0.example,
                exampleChinese: $0.exampleChinese,
                priority: $0.priority,
                partOfSpeech: $0.partOfSpeech
            )
        }.sorted {
            if $0.kind != $1.kind {
                return $0.kind.displayOrder < $1.kind.displayOrder
            }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
        }
        self.level = DictionaryTextSanitizer.sanitize(level)
        self.source = DictionaryTextSanitizer.sanitize(source)
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case headword
        case pronunciation
        case regionalPronunciations
        case aliases
        case keywords
        case meanings
        case relatedExpressions
        case level
        case source
        case priority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            headword: try container.decode(String.self, forKey: .headword),
            pronunciation: try container.decodeIfPresent(String.self, forKey: .pronunciation),
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            keywords: try container.decodeIfPresent([String].self, forKey: .keywords) ?? [],
            meanings: try container.decode([Meaning].self, forKey: .meanings),
            relatedExpressions: try container.decodeIfPresent(
                [RelatedExpression].self,
                forKey: .relatedExpressions
            ) ?? [],
            level: try container.decodeIfPresent(String.self, forKey: .level),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            priority: try container.decodeIfPresent(Int.self, forKey: .priority) ?? 30_000,
            regionalPronunciations: try container.decodeIfPresent(
                [RegionalPronunciation].self, forKey: .regionalPronunciations
            ) ?? []
        )
    }
}

/// A compact, stable snapshot used by the Watch word book.
///
/// Favorites deliberately do not retain a complete `DictionaryEntry`: the
/// bundled dictionary can evolve independently while the saved list stays
/// small. Selecting a favorite performs a fresh lookup by `headword`, so the
/// user always sees the current full entry.
public struct FavoriteWord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let headword: String
    public let pronunciation: String?
    public let conciseChinese: String

    public init(
        id: String,
        headword: String,
        pronunciation: String? = nil,
        conciseChinese: String
    ) {
        self.id = DictionaryTextSanitizer.sanitize(id)
        self.headword = DictionaryTextSanitizer.sanitize(headword)
        self.pronunciation = DictionaryTextSanitizer.sanitize(pronunciation)
        self.conciseChinese = DictionaryTextSanitizer.sanitize(conciseChinese)
    }

    public init(entry: DictionaryEntry) {
        self.init(
            id: entry.id,
            headword: entry.headword,
            pronunciation: entry.pronunciation,
            conciseChinese: Self.conciseChinese(for: entry)
        )
    }

    public func matches(_ entry: DictionaryEntry) -> Bool {
        if id == entry.id { return true }
        let oxfordPrefix = "oxford-10:"
        return id.hasPrefix(oxfordPrefix) && entry.id.hasPrefix(oxfordPrefix) &&
            entry.aliases.contains { id == oxfordPrefix + $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case headword
        case pronunciation
        case conciseChinese
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            headword: try container.decode(String.self, forKey: .headword),
            pronunciation: try container.decodeIfPresent(String.self, forKey: .pronunciation),
            conciseChinese: try container.decode(String.self, forKey: .conciseChinese)
        )
    }

    /// Keeps the first occurrence of each entry because callers supply items
    /// in most-recent-first order.
    public static func deduplicatingMostRecent(_ words: [FavoriteWord]) -> [FavoriteWord] {
        var seenIDs = Set<String>()
        return words.filter { seenIDs.insert($0.id).inserted }
    }

    private static func conciseChinese(for entry: DictionaryEntry) -> String {
        guard let meaning = entry.meanings.first(where: {
            !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return "暂无释义"
        }

        let compact = meaning.chinese
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let limit = 48
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }
}

public enum MatchKind: String, Codable, Hashable, Sendable {
    case exactHeadword
    case exactExpression
    case exactMeaning
    case prefix
    case contains
    case fuzzy

    public var isExact: Bool {
        self == .exactHeadword || self == .exactExpression || self == .exactMeaning
    }
}

public struct DictionaryMatch: Identifiable, Hashable, Sendable {
    public let entry: DictionaryEntry
    public let kind: MatchKind
    public let score: Int

    public var id: String { entry.id }

    public init(entry: DictionaryEntry, kind: MatchKind, score: Int) {
        self.entry = entry
        self.kind = kind
        self.score = score
    }
}

public struct SearchResponse: Equatable, Sendable {
    public let query: String
    public let normalizedQuery: String
    public let exactMatches: [DictionaryMatch]
    public let suggestions: [DictionaryMatch]

    public var bestMatch: DictionaryMatch? { exactMatches.first }
    public var hasExactMatch: Bool { !exactMatches.isEmpty }

    public init(
        query: String,
        normalizedQuery: String,
        exactMatches: [DictionaryMatch],
        suggestions: [DictionaryMatch]
    ) {
        self.query = query
        self.normalizedQuery = normalizedQuery
        self.exactMatches = exactMatches
        self.suggestions = suggestions
    }
}

/// One-entry routing for the Watch app.
///
/// An exact dictionary result is more useful for learning than a generative
/// one-word translation. Everything else falls through to local translation,
/// so a fuzzy suggestion can never prevent a sentence from being translated.
public enum UnifiedLookupRoute: Equatable, Sendable {
    case dictionary
    case translation
}

public enum UnifiedLookupPolicy {
    public static func route(for response: SearchResponse) -> UnifiedLookupRoute {
        response.hasExactMatch ? .dictionary : .translation
    }

    /// Only try this after the original spelling and phrase have been checked.
    public static func joinedEnglishSpellingCandidate(for rawQuery: String) -> String? {
        let query = rawQuery.folding(options: .widthInsensitive, locale: nil)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        let parts = query.split(whereSeparator: \.isWhitespace)
        guard parts.count > 1 else { return nil }
        let spelling = parts.joined().lowercased()
        guard (2...32).contains(spelling.utf8.count),
              spelling.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return spelling
    }

    /// A broad secondary dictionary normally stays closed after a core hit.
    /// The one exception is an English inflection/alias: the same spelling may
    /// be a standalone headword in the secondary dictionary (`ballistics` is
    /// not merely the plural of `ballistic`).
    public static func shouldConsultExtendedDictionary(
        after core: SearchResponse
    ) -> Bool {
        guard let match = core.bestMatch else { return true }
        guard !DictionarySearchEngine.containsChinese(core.normalizedQuery),
              match.kind == .exactHeadword else { return false }
        return DictionarySearchEngine.normalize(match.entry.headword)
            != core.normalizedQuery
    }

    /// Prefer a real headword for the submitted spelling over an inflection
    /// stored under another lemma. Otherwise retain the higher-scoring result,
    /// with the richer core entry winning an exact tie.
    public static func preferredDictionaryMatch(
        core: SearchResponse,
        extended: SearchResponse
    ) -> DictionaryMatch? {
        guard let coreMatch = core.bestMatch else { return extended.bestMatch }
        guard let extendedMatch = extended.bestMatch else { return coreMatch }

        let coreIsDirectHeadword = isDirectHeadword(coreMatch, in: core)
        let extendedIsDirectHeadword = isDirectHeadword(extendedMatch, in: extended)
        if coreIsDirectHeadword != extendedIsDirectHeadword {
            return extendedIsDirectHeadword ? extendedMatch : coreMatch
        }
        return extendedMatch.score > coreMatch.score ? extendedMatch : coreMatch
    }

    public static func correctionSuggestions(
        for response: SearchResponse,
        limit: Int = 3
    ) -> [DictionaryMatch] {
        guard limit > 0, isCompactLexicalInput(response.query) else { return [] }

        // A short Chinese word often has several valid English translations.
        // Keep the best one as the main result, then expose the next exact
        // candidates before fuzzy corrections instead of silently discarding
        // them. This is both faster and more honest than asking a tiny model to
        // invent one answer without sentence context.
        var seenIDs = Set<String>()
        let candidates = response.hasExactMatch
            ? Array(response.exactMatches.dropFirst())
            : response.suggestions
        return Array(candidates.filter { seenIDs.insert($0.id).inserted }.prefix(limit))
    }

    public static func isCompactLexicalInput(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }

        // Dictation often wraps a single lexical item in sentence punctuation
        // (`appel.`, `促进。`). Ignore punctuation only at the outside, just as
        // dictionary normalization does; a terminator inside the remaining
        // text still indicates prose and must not surface spelling chips.
        let lexicalCore = query.trimmingCharacters(
            in: CharacterSet.punctuationCharacters
                .union(.symbols)
                .union(.whitespacesAndNewlines)
        )
        guard !lexicalCore.isEmpty else { return false }

        let sentenceTerminators = CharacterSet(charactersIn: ".!?。！？；;")
        if lexicalCore.unicodeScalars.contains(where: sentenceTerminators.contains) {
            return false
        }

        let meaningfulScalars = lexicalCore.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        guard (2 ... 30).contains(meaningfulScalars.count) else { return false }

        if DictionarySearchEngine.containsChinese(lexicalCore) {
            return meaningfulScalars.count <= 6
        }

        return lexicalCore.split(whereSeparator: { $0.isWhitespace }).count == 1
    }

    private static func isDirectHeadword(
        _ match: DictionaryMatch,
        in response: SearchResponse
    ) -> Bool {
        match.kind == .exactHeadword
            && DictionarySearchEngine.normalize(match.entry.headword)
                == response.normalizedQuery
    }
}
