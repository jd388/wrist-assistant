import Foundation

public struct DictionarySearchEngine: Sendable {
    private static let highConfidenceExactScore = 2_300
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")
    private static let normalizedSeparators = CharacterSet.punctuationCharacters
        .union(.symbols)
        .union(.whitespacesAndNewlines)
    private static let outerPunctuation = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines)

    private struct QueryContext {
        let text: String
        let isChinese: Bool
        let count: Int
        let preferredTranslations: [String]?
        let inflectedGlosses: [String]
        let equivalentGloss: String?
    }

    private struct IndexedEntry: Sendable {
        struct Expression: Sendable {
            let text: String
            let chinese: String
        }

        let entry: DictionaryEntry
        let headword: String
        let aliases: [String]
        let keywords: [String]
        let directChineseGlossRanks: [String: Int]
        let expressions: [Expression]
        let priorityBonus: Int
    }

    /// A spelling candidate pointing into one compact UTF-8 buffer. Fuzzy
    /// lookup used to rebuild `[Character]` for every headword and alias on
    /// every keystroke, which dominated lookup time for the 30k Watch
    /// dictionary. Keeping offsets instead of 60k tiny arrays also avoids
    /// inflating Watch memory and dictionary-load time.
    private struct FuzzyCandidate: Sendable {
        let entryIndex: Int
        let headwordLength: Int
        let unitOffset: Int
        let unitCount: Int
        let latinLetterMask: UInt32
    }

    /// A small, explicit learner lexicon for ambiguous high-frequency Chinese
    /// words whose default English translation cannot be inferred reliably
    /// from gloss order alone. The order is intentional and gives the Watch a
    /// deterministic offline answer without loading a model for one-word lookup.
    private static let preferredChineseTranslations: [String: [String]] = [
        "学习": ["learn", "study"],
        "老师": ["teacher"],
        "读": ["read"],
        "想要": ["want"],
        "喜欢": ["like"],
        "玩": ["play"],
        "跑": ["run"],
        "睡觉": ["sleep"],
        "吃": ["eat"],
        "喝": ["drink"],
        "生活": ["live", "life"],
        "人们": ["people"],
        "孩子": ["child", "kid"],
        "男人": ["man"],
        "好": ["good", "well"],
        "坏": ["bad"],
        "大": ["big", "large", "great"],
        "小": ["small", "little"],
        "新": ["new"],
        "老": ["old"],
        "快乐": ["happy", "joy", "delight"],
        "悲伤": ["sad", "sorrow", "sadness", "grief"],
        "容易": ["easy"],
        "重要": ["important"],
        "不同": ["different"],
        "美丽": ["beautiful"],
        "有趣": ["interesting", "fun"],
        "之前": ["before"],
        "和": ["and", "with"],
        "为了": ["for"],
        "能": ["can", "able"],
        "将": ["will", "would"],
        "是": ["be"],
        "怎么": ["how"],
        "一": ["one"],
        "第一": ["first"],
        "最后": ["last", "final"],
        "促进": ["stimulate", "promote", "facilitate", "advance", "boost"]
    ]

    private let entries: [IndexedEntry]
    private let fuzzyCandidatesByLength: [Int: [FuzzyCandidate]]
    private let fuzzyUnitStorage: [UInt8]

    public init(entries: [DictionaryEntry]) {
        let indexedEntries = entries.map { entry in
            IndexedEntry(
                entry: entry,
                headword: Self.normalize(entry.headword),
                aliases: entry.aliases.map(Self.normalize),
                keywords: entry.keywords.map(Self.normalize),
                directChineseGlossRanks: Self.directChineseGlossRanks(entry.meanings),
                expressions: entry.relatedExpressions.map {
                    IndexedEntry.Expression(
                        text: Self.normalize($0.text),
                        chinese: Self.normalize($0.chinese)
                    )
                },
                // Keep enough resolution to distinguish common school words
                // from rare derivatives. The old 60-point cap made nearly all
                // of the first 20,000 entries tie, after which shorter obscure
                // headwords could win solely because they had fewer letters.
                priorityBonus: max(0, 300 - min(entry.priority, 30_000) / 100)
            )
        }
        self.entries = indexedEntries

        var fuzzyCandidatesByLength: [Int: [FuzzyCandidate]] = [:]
        var fuzzyUnitStorage: [UInt8] = []
        fuzzyUnitStorage.reserveCapacity(indexedEntries.count * 16)
        for (entryIndex, entry) in indexedEntries.enumerated() {
            let headwordLength = entry.headword.count
            var seenSpellings = Set<String>()
            for spelling in [entry.headword] + entry.aliases
                where !spelling.isEmpty
                    && !Self.containsChinese(spelling)
                    && spelling.unicodeScalars.allSatisfy(\.isASCII)
                    && seenSpellings.insert(spelling).inserted {
                let unitOffset = fuzzyUnitStorage.count
                var latinLetterMask: UInt32 = 0
                for unit in spelling.utf8 {
                    fuzzyUnitStorage.append(unit)
                    if (97 ... 122).contains(unit) {
                        latinLetterMask |= UInt32(1) << UInt32(unit - 97)
                    }
                }
                fuzzyCandidatesByLength[spelling.count, default: []].append(
                    FuzzyCandidate(
                        entryIndex: entryIndex,
                        headwordLength: headwordLength,
                        unitOffset: unitOffset,
                        unitCount: fuzzyUnitStorage.count - unitOffset,
                        latinLetterMask: latinLetterMask
                    )
                )
            }
        }
        self.fuzzyCandidatesByLength = fuzzyCandidatesByLength
        self.fuzzyUnitStorage = fuzzyUnitStorage
    }

    public func search(_ rawQuery: String, suggestionLimit: Int = 5) -> SearchResponse {
        let query = Self.normalize(rawQuery)
        let emptyResponse = SearchResponse(
            query: rawQuery,
            normalizedQuery: query,
            exactMatches: [],
            suggestions: []
        )
        guard !query.isEmpty else {
            return emptyResponse
        }
        guard !Task.isCancelled else { return emptyResponse }

        let queryLength = query.count
        let isChineseQuery = Self.containsChinese(query)
        let context = QueryContext(
            text: query,
            isChinese: isChineseQuery,
            count: queryLength,
            preferredTranslations: Self.preferredChineseTranslations[query],
            inflectedGlosses: isChineseQuery ? [query + "的", query + "地", query + "得"] : [],
            equivalentGloss: isChineseQuery ? Self.chineseGlossEquivalent(for: query) : nil
        )

        var matches: [DictionaryMatch] = []
        matches.reserveCapacity(min(entries.count, 32))

        for (entryIndex, entry) in entries.enumerated() {
            if entryIndex.isMultiple(of: 256), Task.isCancelled {
                return emptyResponse
            }
            if let match = scoreWithoutFuzzy(entry: entry, context: context) {
                matches.append(match)
            }
        }

        let hasExactMatch = matches.contains { $0.kind.isExact }
        if !hasExactMatch, !isChineseQuery {
            let threshold = max(1, min(3, (queryLength + 1) / 3))
            let queryUnits = Array(query.utf8)
            if queryLength >= 2, queryUnits.count == queryLength {
                let queryLetterMask = Self.latinLetterMask(for: queryUnits)
                var bestDistanceByEntry: [Int: Int] = [:]
                bestDistanceByEntry.reserveCapacity(32)
                var beforePrevious = [Int](repeating: 0, count: queryUnits.count + threshold + 1)
                var previous = beforePrevious
                var current = beforePrevious

                let minimumLength = max(0, queryUnits.count - threshold)
                let maximumLength = queryUnits.count + threshold
                if minimumLength <= maximumLength {
                    for length in minimumLength ... maximumLength {
                        guard !Task.isCancelled else { return emptyResponse }
                        guard let candidates = fuzzyCandidatesByLength[length] else { continue }
                        for candidate in candidates
                            where abs(candidate.headwordLength - queryLength) <= threshold {
                            // One edit can introduce/remove at most two distinct
                            // Latin letters. This cheap admissible lower bound
                            // rejects unrelated words before touching the DP rows.
                            let differingLetters = (queryLetterMask ^ candidate.latinLetterMask)
                                .nonzeroBitCount
                            guard (differingLetters + 1) / 2 <= threshold else { continue }

                            let effectiveThreshold = min(
                                threshold,
                                bestDistanceByEntry[candidate.entryIndex].map { $0 - 1 }
                                    ?? threshold
                            )
                            guard effectiveThreshold >= 0,
                                  let distance = Self.boundedCorrectionDistance(
                                    queryUnits,
                                    fuzzyUnitStorage,
                                    rhsOffset: candidate.unitOffset,
                                    rhsCount: candidate.unitCount,
                                    maximumDistance: effectiveThreshold,
                                    beforePrevious: &beforePrevious,
                                    previous: &previous,
                                    current: &current
                                  ) else { continue }
                            bestDistanceByEntry[candidate.entryIndex] = distance
                        }
                    }
                }

                for (entryIndex, shortestDistance) in bestDistanceByEntry {
                    let entry = entries[entryIndex]
                    matches.append(
                        DictionaryMatch(
                            entry: entry.entry,
                            kind: .fuzzy,
                            // A close edit-distance match is stronger evidence
                            // than a longer word merely sharing the submitted
                            // prefix, or a one/two-letter headword appearing
                            // inside the typo. Keep frequency as the tie-breaker
                            // so common learner words win among equal edits.
                            score: 1_450 + entry.priorityBonus
                                - shortestDistance * 120
                                - abs(entry.headword.count - query.count) * 10
                        )
                    )
                }
            } else if query.count >= 2 {
                // The bundled English spellings are ASCII after folding. Keep
                // a correctness-first fallback for clients that provide a
                // non-ASCII lexical key; this path is intentionally rare.
                for (entryIndex, entry) in entries.enumerated()
                    where abs(entry.headword.count - query.count) <= threshold {
                    if entryIndex.isMultiple(of: 256), Task.isCancelled {
                        return emptyResponse
                    }
                    let shortestDistance = ([entry.headword] + entry.aliases).map {
                        Self.correctionDistance(query, $0)
                    }.min() ?? Int.max
                    if shortestDistance <= threshold {
                        matches.append(
                            DictionaryMatch(
                                entry: entry.entry,
                                kind: .fuzzy,
                                score: 1_450 + entry.priorityBonus
                                    - shortestDistance * 120
                                    - abs(entry.headword.count - query.count) * 10
                            )
                        )
                    }
                }
            }
        }

        guard !Task.isCancelled else { return emptyResponse }

        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.headword.count != $1.entry.headword.count {
                return $0.entry.headword.count < $1.entry.headword.count
            }
            return $0.entry.headword.localizedCaseInsensitiveCompare($1.entry.headword) == .orderedAscending
        }

        let exactCandidates = matches.filter(\.kind.isExact)
        let highConfidenceExact = exactCandidates.filter {
            $0.score >= Self.highConfidenceExactScore
        }
        // Keyword fragments are retained as a last-resort offline result when
        // nothing stronger exists. Once a preferred translation, complete
        // gloss, alias, headword or full expression matches, hide those weak
        // fragments so entries such as `pattern` cannot appear as an exact
        // answer for 学习 merely because one long usage note contains that word.
        let exact = highConfidenceExact.isEmpty
            ? exactCandidates
            : highConfidenceExact
        // One entry can qualify as both a prefix/contains recovery and a fuzzy
        // match. Deduplicate after sorting so the UI's limited slots contain
        // distinct words and retain the strongest reason for each entry.
        var seenSuggestionIDs = Set<String>()
        var suggestions: [DictionaryMatch] = []
        suggestions.reserveCapacity(max(0, suggestionLimit))
        if suggestionLimit > 0 {
            for match in matches where !match.kind.isExact {
                guard seenSuggestionIDs.insert(match.id).inserted else { continue }
                suggestions.append(match)
                if suggestions.count == suggestionLimit { break }
            }
        }
        return SearchResponse(
            query: rawQuery,
            normalizedQuery: query,
            exactMatches: exact,
            suggestions: suggestions
        )
    }

    public static func normalize(_ text: String) -> String {
        // Most stored keys are plain Latin words or Han-only glosses. These
        // forms already satisfy the full normalizer's Unicode rules.
        if text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) {
            return text.lowercased()
        }
        if text.unicodeScalars.allSatisfy(isHan) { return text }

        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: normalizationLocale)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Chinese lookup intentionally remains separator-insensitive so
        // handwriting and dictation output such as `学 校。` still finds
        // `学校`. English needs a stricter key: deleting spaces made distinct
        // entries such as `take off` / `takeoff` and `act on` / `Acton`
        // collide. Preserve that word boundary while treating spelling variants
        // that use whitespace or a Unicode dash as the same phrase.
        if containsChinese(folded) {
            return folded.unicodeScalars
                .filter { !normalizedSeparators.contains($0) }
                .map(String.init)
                .joined()
                .lowercased()
        }

        // Dictation commonly appends sentence punctuation even when the user
        // spoke a single word. Remove punctuation only at the outside; internal
        // apostrophes and periods remain meaningful dictionary spelling.
        let punctuationTrimmed = folded.trimmingCharacters(
            in: outerPunctuation
        )
        let isSingleToken = !punctuationTrimmed.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let english = isSingleToken ? punctuationTrimmed : folded

        var result = ""
        var hasPendingBoundary = false
        for scalar in english.lowercased().unicodeScalars {
            let isBoundary = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.properties.generalCategory == .dashPunctuation
            if isBoundary {
                hasPendingBoundary = !result.isEmpty
                continue
            }

            if hasPendingBoundary {
                result.append(" ")
                hasPendingBoundary = false
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private func scoreWithoutFuzzy(entry: IndexedEntry, context: QueryContext) -> DictionaryMatch? {
        let query = context.text
        let isChineseQuery = context.isChinese
        let englishCommonnessBonus = min(entry.priorityBonus, 100)

        if isChineseQuery,
           let preferred = context.preferredTranslations,
           let preferredIndex = preferred.firstIndex(of: entry.headword) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactMeaning,
                // One preferred slot must remain stronger than any frequency
                // difference, otherwise a common secondary sense can again
                // displace the intended learner translation.
                score: 5_000 - preferredIndex * 350 + entry.priorityBonus
            )
        }

        // A real headword must beat an inflection/alias even when the alias is
        // stored under a much more frequent base word. This keeps `meaning`,
        // `interested`, and `surprised` on their own learner-facing entries.
        if entry.headword == query {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactHeadword,
                score: 3_000 + englishCommonnessBonus
            )
        }

        if entry.aliases.contains(query) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactHeadword,
                // A curated Chinese alias is an explicit reverse-lookup key,
                // while an English alias is normally only an inflection. Keep
                // both below a real English headword, but let a Chinese alias
                // (for example 刺激 -> stimulate) beat competing glosses.
                score: (isChineseQuery ? 3_200 + entry.priorityBonus : 2_750 + englishCommonnessBonus)
            )
        }

        if entry.expressions.contains(where: { $0.text == query }) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactExpression,
                score: 2_600 + englishCommonnessBonus
            )
        }

        if isChineseQuery,
           let glossRank = entry.directChineseGlossRanks[query] {
            // A complete first gloss is stronger than every later sense, even
            // when the later sense belongs to a more frequent English word.
            // Later complete glosses still beat tokens extracted from phrases
            // such as "给……看" or "（学校的）班长".
            let score = glossRank == 0
                ? 2_900 + entry.priorityBonus
                : 2_500 + entry.priorityBonus - min(glossRank, 20) * 5
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactMeaning,
                score: score
            )
        }

        if isChineseQuery,
           let directKeywordIndex = entry.keywords.firstIndex(of: query) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactMeaning,
                score: 1_900 + min(entry.priorityBonus, 100)
                    - min(directKeywordIndex, 20) * 2
            )
        }

        if isChineseQuery {
            if let keywordIndex = entry.keywords.firstIndex(where: context.inflectedGlosses.contains) {
                return DictionaryMatch(
                    entry: entry.entry,
                    kind: .exactMeaning,
                    score: 1_700 + entry.priorityBonus - min(keywordIndex, 20) * 2
                )
            }
        }

        if isChineseQuery,
           let equivalent = context.equivalentGloss,
           let glossRank = entry.directChineseGlossRanks[equivalent] {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactMeaning,
                score: (glossRank == 0 ? 2_850 : 2_450) + entry.priorityBonus
            )
        }

        // A phrase translation is an exact result only when the complete gloss
        // matches. Merely appearing inside "在学校就餐" or "学习笔记" is not a
        // dictionary definition for 学校 or 学习.
        if isChineseQuery,
           entry.expressions.contains(where: { $0.chinese == query }) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .exactMeaning,
                score: 2_350 + min(entry.priorityBonus, 100)
            )
        }

        // Multi-character substrings remain low-confidence recovery hints. They
        // deliberately use `.contains`, so they cannot route a lookup away from
        // translation or displace an exact headword/meaning. A single Chinese
        // character is too ambiguous for substring matching and is ignored.
        if isChineseQuery,
           context.count > 1,
           let keywordIndex = entry.keywords.firstIndex(where: { $0.contains(query) }) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .contains,
                score: 600 + min(entry.priorityBonus, 30) - min(keywordIndex, 12) * 15
            )
        }

        if isChineseQuery,
           context.count > 1,
           entry.expressions.contains(where: { $0.chinese.contains(query) }) {
            return DictionaryMatch(
                entry: entry.entry,
                kind: .contains,
                score: 500 + min(entry.priorityBonus, 30)
            )
        }

        if entry.headword.hasPrefix(query) || entry.aliases.contains(where: { $0.hasPrefix(query) }) {
            let lengthPenalty = min(abs(entry.headword.count - context.count), 30)
            return DictionaryMatch(entry: entry.entry, kind: .prefix, score: 700 + entry.priorityBonus - lengthPenalty)
        }

        if entry.expressions.contains(where: { $0.text.hasPrefix(query) }) {
            return DictionaryMatch(entry: entry.entry, kind: .prefix, score: 660 + entry.priorityBonus)
        }

        if query.contains(entry.headword) {
            return DictionaryMatch(entry: entry.entry, kind: .contains, score: 560 + entry.priorityBonus)
        }

        return nil
    }

    /// Index complete gloss segments separately from keyword fragments.
    ///
    /// The final Han run handles source annotations deterministically:
    /// `[C] (中、小) 学校` yields `学校`, while `给……看` yields `看` rather
    /// than falsely treating `给` as the translation of `show`. Joining all
    /// Han runs also recovers typography such as `家(庭)` -> `家庭`.
    private static func directChineseGlossRanks(
        _ meanings: [DictionaryEntry.Meaning]
    ) -> [String: Int] {
        let separators = CharacterSet(charactersIn: "；;，,：:\n")
        var result: [String: Int] = [:]
        var rank = 0

        for meaning in meanings {
            for segment in meaning.chinese.components(separatedBy: separators) {
                var runs: [String] = []
                var current = ""
                for character in segment {
                    if character.unicodeScalars.allSatisfy(isHan) {
                        current.append(character)
                    } else if !current.isEmpty {
                        runs.append(current)
                        current = ""
                    }
                }
                if !current.isEmpty { runs.append(current) }

                let candidates = [runs.joined(), runs.last ?? ""]
                for candidate in candidates where !candidate.isEmpty && candidate.count <= 12 {
                    result[candidate] = min(result[candidate] ?? Int.max, rank)
                }
                rank += 1
            }
        }
        return result
    }

    private static func chineseGlossEquivalent(for query: String) -> String? {
        switch query {
        case "哪个": return "哪一个"
        case "怎么": return "怎样"
        default: return nil
        }
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) ||
            (0x4E00...0x9FFF).contains(scalar.value)
    }

    public static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHan)
    }

    public static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, charB) in b.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (charA == charB ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func latinLetterMask(for units: [UInt8]) -> UInt32 {
        units.reduce(into: UInt32(0)) { mask, unit in
            guard (97 ... 122).contains(unit) else { return }
            mask |= UInt32(1) << UInt32(unit - 97)
        }
    }

    /// Threshold-bounded optimal-string-alignment distance for human spelling
    /// correction. Adjacent swaps such as `appel` -> `apple` cost one edit.
    ///
    /// Only the diagonal band that can still finish within `maximumDistance`
    /// is evaluated. Two over-budget rows allow a safe early exit while still
    /// leaving room for the OSA recurrence to recover an adjacent transposition.
    static func boundedCorrectionDistance(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        maximumDistance: Int
    ) -> Int? {
        guard maximumDistance >= 0 else { return nil }
        var beforePrevious = [Int](repeating: 0, count: rhs.count + 1)
        var previous = beforePrevious
        var current = beforePrevious
        return boundedCorrectionDistance(
            lhs,
            rhs,
            rhsOffset: 0,
            rhsCount: rhs.count,
            maximumDistance: maximumDistance,
            beforePrevious: &beforePrevious,
            previous: &previous,
            current: &current
        )
    }

    private static func boundedCorrectionDistance(
        _ lhs: [UInt8],
        _ rhsStorage: [UInt8],
        rhsOffset: Int,
        rhsCount: Int,
        maximumDistance: Int,
        beforePrevious: inout [Int],
        previous: inout [Int],
        current: inout [Int]
    ) -> Int? {
        let lhsCount = lhs.count
        guard abs(lhsCount - rhsCount) <= maximumDistance else { return nil }
        if lhsCount == 0 { return rhsCount <= maximumDistance ? rhsCount : nil }
        if rhsCount == 0 { return lhsCount <= maximumDistance ? lhsCount : nil }

        let requiredCapacity = rhsCount + 1
        if beforePrevious.count < requiredCapacity {
            beforePrevious = [Int](repeating: 0, count: requiredCapacity)
            previous = beforePrevious
            current = beforePrevious
        }

        let overBudget = maximumDistance + 1
        for column in 0 ... rhsCount {
            beforePrevious[column] = overBudget
            previous[column] = column <= maximumDistance ? column : overBudget
            current[column] = overBudget
        }

        var previousRowMinimum = 0
        for row in 1 ... lhsCount {
            for column in 0 ... rhsCount { current[column] = overBudget }
            if row <= maximumDistance { current[0] = row }

            let firstColumn = max(1, row - maximumDistance)
            let lastColumn = min(rhsCount, row + maximumDistance)
            var rowMinimum = overBudget
            if firstColumn <= lastColumn {
                for column in firstColumn ... lastColumn {
                    var distance = min(
                        current[column - 1] + 1,
                        previous[column] + 1,
                        previous[column - 1]
                            + (lhs[row - 1] == rhsStorage[rhsOffset + column - 1] ? 0 : 1)
                    )

                    if row > 1,
                       column > 1,
                       lhs[row - 1] == rhsStorage[rhsOffset + column - 2],
                       lhs[row - 2] == rhsStorage[rhsOffset + column - 1] {
                        distance = min(distance, beforePrevious[column - 2] + 1)
                    }
                    current[column] = min(distance, overBudget)
                    rowMinimum = min(rowMinimum, current[column])
                }
            }

            // OSA can look back two rows for one transposition. Therefore one
            // over-budget row is not enough to stop, but two consecutive rows
            // cannot return to the accepted band.
            if rowMinimum > maximumDistance,
               previousRowMinimum > maximumDistance {
                return nil
            }
            previousRowMinimum = rowMinimum
            swap(&beforePrevious, &previous)
            swap(&previous, &current)
        }

        let distance = previous[rhsCount]
        return distance <= maximumDistance ? distance : nil
    }

    /// Character-based fallback for the uncommon non-ASCII lexical key. The
    /// normal bundled path above stays allocation-free inside its candidate
    /// loop, while this preserves the previous Unicode matching semantics.
    private static func correctionDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var beforePrevious: [Int]?
        var previous = Array(0 ... b.count)

        for (i, charA) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, charB) in b.enumerated() {
                var distance = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (charA == charB ? 0 : 1)
                )

                if i > 0,
                   j > 0,
                   charA == b[j - 1],
                   a[i - 1] == charB,
                   let beforePrevious {
                    distance = min(distance, beforePrevious[j - 1] + 1)
                }
                current[j + 1] = distance
            }
            beforePrevious = previous
            previous = current
        }
        return previous[b.count]
    }
}
