/// A monotonic token used to prevent a cancelled lookup from publishing stale
/// state after a newer submit, clear, edit, or suggestion selection.
public struct LookupRequestGate: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> Token {
        generation &+= 1
        return Token(generation: generation)
    }

    public mutating func invalidate() {
        generation &+= 1
    }

    public func isCurrent(_ token: Token) -> Bool {
        token.generation == generation
    }
}
