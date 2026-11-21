import Testing
@testable import DictionaryCore

@Test func aNewLookupInvalidatesThePreviousLookup() {
    var gate = LookupRequestGate()
    let first = gate.begin()
    let second = gate.begin()

    #expect(!gate.isCurrent(first))
    #expect(gate.isCurrent(second))
}

@Test func clearingInvalidatesTheRunningLookup() {
    var gate = LookupRequestGate()
    let running = gate.begin()

    gate.invalidate()

    #expect(!gate.isCurrent(running))
}

@Test func editingInvalidatesWithoutStartingAnotherLookup() {
    var gate = LookupRequestGate()
    let stale = gate.begin()

    gate.invalidate()
    let resumed = gate.begin()

    #expect(!gate.isCurrent(stale))
    #expect(gate.isCurrent(resumed))
}

@Test func directQueryEditingInvalidatesAnInFlightResult() {
    var gate = LookupRequestGate()
    let submittedQuery = gate.begin()

    // LookupViewModel calls invalidate as soon as its TextField-bound query
    // changes, even when the user edits without tapping its edit button.
    gate.invalidate()

    #expect(!gate.isCurrent(submittedQuery))
}
