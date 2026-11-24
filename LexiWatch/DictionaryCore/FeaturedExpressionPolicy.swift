import Foundation

/// Selects the compact, teaching-first expression set shown on the main
/// Watch result while the complete entry remains available one level deeper.
public enum FeaturedExpressionPolicy {
    public static let defaultLimit = 6

    private static let usageSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "+()[]{}=,;:…"))
    private static let slotNames: Set<String> = [
        "sb", "sth", "somebody", "something", "someone", "yourself", "myself",
        "himself", "herself", "itself", "oneself", "ourselves", "themselves"
    ]
    private static let grammarLabels: Set<String> = [
        "adv", "adverb", "adverbs", "adverbial", "prep", "preposition", "prepositions",
        "adj", "adjective", "adjectives", "n", "noun", "nouns", "v", "verb", "verbs",
        "pron", "pronoun", "conj", "conjunction", "det", "determiner", "phrase",
        "phrases", "clause", "clauses", "speech", "direct-speech", "indirect-speech",
        "etc", "obj", "object", "complement", "inf", "infinitive", "participle",
        "gerund", "pred", "predicate", "transitive", "intransitive", "particle", "or", "and"
    ]

    public static func isUsefulUsagePattern(_ pattern: String, headword: String) -> Bool {
        if DictionarySearchEngine.containsChinese(pattern) { return true }

        let head = usageWords(headword)
        let joinedAlternatives = pattern.replacingOccurrences(of: #"\s*/\s*"#, with: "/", options: .regularExpression)
        var words = usageWords(joinedAlternatives)
        if !head.isEmpty, words.starts(with: head, by: { $0.lowercased() == $1.lowercased() }) {
            words.removeFirst(head.count)
        } else if head.count == 1, words.count >= 2, words[0].lowercased() == "be",
                  [head[0], head[0] + "d", head[0] + "ed"].contains(words[1]) {
            words.removeFirst(2)
        }

        var slots = 0
        for word in words {
            let alternatives = word.split(separator: "/").map {
                $0.trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty }
            guard !alternatives.isEmpty else { continue }
            if alternatives.allSatisfy({ grammarLabels.contains($0.lowercased()) }) { continue }
            if alternatives.allSatisfy({ $0 == "A" || $0 == "B" || slotNames.contains($0.lowercased()) }) {
                slots += 1
            } else {
                return true
            }
        }
        // Two slots encode a real double-object construction; one generic
        // slot or a list of part-of-speech abbreviations adds little here.
        return slots >= 2
    }

    private static func usageWords(_ value: String) -> [String] {
        value.components(separatedBy: usageSeparators)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0 != "~" }
    }

    public static func select(
        from expressions: [DictionaryEntry.RelatedExpression],
        limit: Int = defaultLimit
    ) -> [DictionaryEntry.RelatedExpression] {
        guard limit > 0 else { return [] }

        let ranked = expressions.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.priority != rhs.element.priority {
                    return lhs.element.priority < rhs.element.priority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var selectedIDs = Set<String>()
        func reserve(
            _ kind: DictionaryEntry.RelatedExpression.Kind,
            count: Int
        ) {
            guard selectedIDs.count < limit else { return }
            var reservedCount = 0
            for expression in ranked where expression.kind == kind {
                guard selectedIDs.count < limit else { return }
                if selectedIDs.insert(expression.id).inserted {
                    reservedCount += 1
                }
                if reservedCount >= count { return }
            }
        }

        reserve(.phrasalVerb, count: 3)
        reserve(.verbPattern, count: 2)
        reserve(.fixedPhrase, count: 1)

        for expression in ranked where selectedIDs.count < limit {
            selectedIDs.insert(expression.id)
        }

        var emittedIDs = Set<String>()
        return ranked.filter {
            selectedIDs.contains($0.id) && emittedIDs.insert($0.id).inserted
        }
    }
}
