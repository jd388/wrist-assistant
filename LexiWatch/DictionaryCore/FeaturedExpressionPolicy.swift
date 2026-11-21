/// Selects the compact, teaching-first expression set shown on the main
/// Watch result while the complete entry remains available one level deeper.
public enum FeaturedExpressionPolicy {
    public static let defaultLimit = 6

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
