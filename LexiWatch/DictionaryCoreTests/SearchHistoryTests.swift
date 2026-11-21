import XCTest
@testable import DictionaryCore

final class SearchHistoryTests: XCTestCase {
    func testMergingPreservesEveryUniqueItemWithoutCountLimit() {
        let current = (1...12).map { "query-\($0)" }
        let legacy = ["QUERY-4", "translation-1", "translation-2"]

        let merged = SearchHistory.merging([current, legacy])

        XCTAssertEqual(merged, current + ["translation-1", "translation-2"])
        XCTAssertEqual(merged.count, 14)
    }

    func testRememberingAddsBeyondFiveAndMovesRepeatToFront() {
        let existing = (1...20).map { "query-\($0)" }

        let appended = SearchHistory.remembering("new-query", in: existing)
        let repeated = SearchHistory.remembering("QUERY-12", in: appended)

        XCTAssertEqual(appended.count, 21)
        XCTAssertEqual(Set(appended), Set(existing + ["new-query"]))
        XCTAssertEqual(repeated.first, "QUERY-12")
        XCTAssertEqual(repeated.count, 21)
        XCTAssertFalse(repeated.dropFirst().contains("query-12"))
    }

    func testRemovingDeletesOnlySelectedItem() {
        let existing = ["hello", "stimulate", "give up", "school"]

        let result = SearchHistory.removing("STIMULATE", from: existing)

        XCTAssertEqual(result, ["hello", "give up", "school"])
    }
}
