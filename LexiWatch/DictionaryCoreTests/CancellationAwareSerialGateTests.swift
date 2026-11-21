import Testing
@testable import DictionaryCore

private actor GateTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let suspended = waiters
        waiters.removeAll()
        for waiter in suspended {
            waiter.resume()
        }
    }
}

private actor GateTestRecorder {
    private(set) var labels: [String] = []
    private var activeCount = 0
    private(set) var maximumActiveCount = 0

    func begin(_ label: String) {
        labels.append(label)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }
}

@Test("A cancelled queued caller is removed before the active operation finishes")
func cancelledWaiterLeavesQueueImmediately() async {
    let gate = CancellationAwareSerialGate()
    let firstStarted = GateTestLatch()
    let releaseFirst = GateTestLatch()
    let recorder = GateTestRecorder()

    let first = Task {
        try await gate.withExclusiveAccess {
            await recorder.begin("first")
            await firstStarted.open()
            await releaseFirst.wait()
            await recorder.end()
        }
    }
    await firstStarted.wait()

    let cancelled = Task {
        try await gate.withExclusiveAccess {
            await recorder.begin("cancelled")
            await recorder.end()
        }
    }
    #expect(await waitForPendingCount(1, in: gate))

    cancelled.cancel()
    let removedBeforeRelease = await waitForPendingCount(0, in: gate)
    #expect(removedBeforeRelease)

    let latest = Task {
        try await gate.withExclusiveAccess {
            await recorder.begin("latest")
            await recorder.end()
        }
    }
    #expect(await waitForPendingCount(1, in: gate))
    await releaseFirst.open()

    _ = try? await first.value
    let cancellationWasObserved: Bool
    do {
        try await cancelled.value
        cancellationWasObserved = false
    } catch is CancellationError {
        cancellationWasObserved = true
    } catch {
        cancellationWasObserved = false
    }
    _ = try? await latest.value

    #expect(cancellationWasObserved)
    #expect(await recorder.labels == ["first", "latest"])
    #expect(await recorder.maximumActiveCount == 1)
}

@Test("Concurrent callers never overlap inside the gated operation")
func gateAllowsOnlyOneOperationAtATime() async {
    let gate = CancellationAwareSerialGate()
    let recorder = GateTestRecorder()

    await withTaskGroup(of: Void.self) { group in
        for index in 0 ..< 24 {
            group.addTask {
                _ = try? await gate.withExclusiveAccess {
                    await recorder.begin("\(index)")
                    await Task.yield()
                    await recorder.end()
                }
            }
        }
    }

    #expect(await recorder.labels.count == 24)
    #expect(await recorder.maximumActiveCount == 1)
}

@Test("Repeatedly cancelled retries do not delay the newest caller")
func repeatedCancelledRetriesAreSkipped() async {
    let gate = CancellationAwareSerialGate()
    let firstStarted = GateTestLatch()
    let releaseFirst = GateTestLatch()
    let recorder = GateTestRecorder()

    let first = Task {
        try await gate.withExclusiveAccess {
            await recorder.begin("first")
            await firstStarted.open()
            await releaseFirst.wait()
            await recorder.end()
        }
    }
    await firstStarted.wait()

    let retryCount = 16
    var retries: [Task<Bool, Never>] = []
    for index in 0 ..< retryCount {
        retries.append(Task {
            do {
                try await gate.withExclusiveAccess {
                    await recorder.begin("retry-\(index)")
                    await recorder.end()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        })
    }
    #expect(await waitForPendingCount(retryCount, in: gate))

    for retry in retries {
        retry.cancel()
    }
    #expect(await waitForPendingCount(0, in: gate))

    let latest = Task {
        try await gate.withExclusiveAccess {
            await recorder.begin("latest")
            await recorder.end()
        }
    }
    #expect(await waitForPendingCount(1, in: gate))
    await releaseFirst.open()

    _ = try? await first.value
    for retry in retries {
        #expect(await retry.value)
    }
    _ = try? await latest.value

    #expect(await recorder.labels == ["first", "latest"])
    #expect(await recorder.maximumActiveCount == 1)
}

private func waitForPendingCount(
    _ expected: Int,
    in gate: CancellationAwareSerialGate
) async -> Bool {
    for _ in 0 ..< 10_000 {
        if await gate.pendingWaiterCount == expected {
            return true
        }
        await Task.yield()
    }
    return false
}
