import Testing
@testable import DictionaryCore

@Test("Pure numbers translate to English without a model")
func deterministicNumberTranslation() {
    #expect(DeterministicNumberTranslation.englishSpelling(for: "1") == "one")
    #expect(DeterministicNumberTranslation.englishSpelling(for: "12") == "twelve")
    #expect(DeterministicNumberTranslation.englishSpelling(for: "2026") == "two thousand twenty-six")
    #expect(DeterministicNumberTranslation.englishSpelling(for: "-7") == "minus seven")
    #expect(DeterministicNumberTranslation.englishSpelling(for: "1.05") == "one point zero five")
}

@Test("Full-width numeric input uses the deterministic path")
func deterministicFullWidthNumberTranslation() {
    #expect(DeterministicNumberTranslation.englishSpelling(for: " １ ") == "one")
    #expect(DeterministicNumberTranslation.englishSpelling(for: "－１２．５") == "minus twelve point five")
}

@Test("Mixed text does not get mistaken for a pure number")
func deterministicNumberTranslationRejectsText() {
    #expect(DeterministicNumberTranslation.englishSpelling(for: "1st") == nil)
    #expect(DeterministicNumberTranslation.englishSpelling(for: "Room 1") == nil)
    #expect(DeterministicNumberTranslation.englishSpelling(for: "1.2.3") == nil)
}
