import Testing
@testable import DictionaryCore

@Test func featuredExpressionsBalanceGivePhrasesAndTeachingPatterns() {
    let expressions = [
        expression("give up", kind: .phrasalVerb, priority: 0),
        expression("give in", kind: .phrasalVerb, priority: 1),
        expression("give away", kind: .phrasalVerb, priority: 2),
        expression("give out", kind: .phrasalVerb, priority: 3),
        expression("give off", kind: .phrasalVerb, priority: 4),
        expression("give back", kind: .phrasalVerb, priority: 5),
        expression("give sb sth / give sth to sb", kind: .verbPattern, priority: 6),
        expression("give up doing sth", kind: .verbPattern, priority: 7),
        expression("give way (to)", kind: .fixedPhrase, priority: 9),
    ]

    let selected = FeaturedExpressionPolicy.select(from: expressions)

    #expect(selected.count == 6)
    #expect(selected.filter { $0.kind == .phrasalVerb }.map(\.text) == [
        "give up", "give in", "give away",
    ])
    #expect(selected.filter { $0.kind == .verbPattern }.map(\.text) == [
        "give sb sth / give sth to sb", "give up doing sth",
    ])
    #expect(selected.filter { $0.kind == .fixedPhrase }.map(\.text) == [
        "give way (to)",
    ])
}

@Test func missingCategoriesReturnTheirSlotsToGlobalPriority() {
    let expressions = (0 ..< 8).map {
        expression("phrase \($0)", kind: .phrasalVerb, priority: $0)
    }

    let selected = FeaturedExpressionPolicy.select(from: expressions)

    #expect(selected.map(\.text) == (0 ..< 6).map { "phrase \($0)" })
}

private func expression(
    _ text: String,
    kind: DictionaryEntry.RelatedExpression.Kind,
    priority: Int
) -> DictionaryEntry.RelatedExpression {
    .init(text: text, kind: kind, chinese: "测试", priority: priority)
}
