/// Serializes expensive async work while allowing cancelled queued callers to
/// leave the FIFO immediately.
///
/// The operation itself is deliberately kept inside the permit lifetime. This
/// matters for actor-based clients: even if their actor re-enters while an
/// awaited operation is running, the gate never admits a second operation.
public actor CancellationAwareSerialGate {
    private struct Permit: Sendable {
        let id: UInt64
    }

    private struct Waiter {
        let permit: Permit
        let continuation: CheckedContinuation<Permit, any Error>
    }

    private var activePermitID: UInt64?
    private var waiters: [Waiter] = []
    private var nextPermitID: UInt64 = 0

    public init() {}

    /// Runs `operation` after all earlier non-cancelled callers have finished.
    /// A caller cancelled while queued is removed without consuming a turn.
    public func withExclusiveAccess<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let permit = try await acquire()
        defer { release(permit) }

        // Cancellation can race with the waiter being resumed. Check again
        // while the permit is held so that race releases directly to the next
        // live waiter without invoking the cancelled operation.
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws -> Permit {
        try Task.checkCancellation()

        let permit = makePermit()
        guard activePermitID != nil else {
            activePermitID = permit.id
            return permit
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(
                        Waiter(permit: permit, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(withID: permit.id) }
        }
    }

    private func makePermit() -> Permit {
        nextPermitID &+= 1
        return Permit(id: nextPermitID)
    }

    private func cancelWaiter(withID id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.permit.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ permit: Permit) {
        guard activePermitID == permit.id else { return }

        guard !waiters.isEmpty else {
            activePermitID = nil
            return
        }
        let next = waiters.removeFirst()
        activePermitID = next.permit.id
        next.continuation.resume(returning: next.permit)
    }

    // Internal observability keeps cancellation tests deterministic without
    // adding sleeps or exposing queue state to the app target's public API.
    var pendingWaiterCount: Int {
        waiters.count
    }
}
