import Foundation
import Testing
@testable import SequentialExecutor

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: value)
    }
}

final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [ContinuationBox<Void>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ContinuationBox(continuation)
            let shouldResumeImmediately = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(box)
                return false
            }

            if shouldResumeImmediately {
                box.resume(returning: ())
            }
        }
    }

    func open() {
        let waiters = lock.withLock {
            guard !isOpen else { return [ContinuationBox<Void>]() }
            isOpen = true
            defer { self.waiters.removeAll() }
            return self.waiters
        }
        waiters.forEach { $0.resume(returning: ()) }
    }
}

struct ExecutionSnapshot: Sendable {
    let startedCount: Int
    let finishedCount: Int
    let inFlightCount: Int
    let maxInFlightCount: Int
}

final class ExecutionProbe: @unchecked Sendable {
    private struct Waiter {
        let predicate: @Sendable (ExecutionSnapshot) -> Bool
        let continuation: ContinuationBox<ExecutionSnapshot?>
    }

    private let lock = NSLock()
    private var startedCount = 0
    private var finishedCount = 0
    private var inFlightCount = 0
    private var maxInFlightCount = 0
    private var waiters: [UUID: Waiter] = [:]

    func begin() {
        update(startedDelta: 1, finishedDelta: 0)
    }

    func end() {
        update(startedDelta: 0, finishedDelta: 1)
    }

    func snapshot() -> ExecutionSnapshot {
        lock.withLock { snapshotLocked() }
    }

    func wait(
        timeout: Duration = .seconds(2),
        until predicate: @escaping @Sendable (ExecutionSnapshot) -> Bool
    ) async -> ExecutionSnapshot? {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            let immediateSnapshot = lock.withLock { () -> ExecutionSnapshot? in
                let snapshot = snapshotLocked()
                guard !predicate(snapshot) else { return snapshot }
                waiters[waiterID] = Waiter(predicate: predicate, continuation: box)
                return nil
            }

            if let immediateSnapshot {
                box.resume(returning: immediateSnapshot)
                return
            }

            Task {
                try? await Task.sleep(for: timeout)
                let continuation = self.lock.withLock {
                    self.waiters.removeValue(forKey: waiterID)?.continuation
                }
                continuation?.resume(returning: nil)
            }
        }
    }

    private func update(startedDelta: Int, finishedDelta: Int) {
        let (snapshot, continuations): (ExecutionSnapshot, [ContinuationBox<ExecutionSnapshot?>]) = lock.withLock {
            startedCount += startedDelta
            finishedCount += finishedDelta
            inFlightCount += startedDelta - finishedDelta
            maxInFlightCount = max(maxInFlightCount, inFlightCount)

            let snapshot = snapshotLocked()
            let matchedIDs = waiters.compactMap { id, waiter in
                waiter.predicate(snapshot) ? id : nil
            }
            let continuations = matchedIDs.compactMap { waiters.removeValue(forKey: $0)?.continuation }
            return (snapshot, continuations)
        }

        continuations.forEach { $0.resume(returning: snapshot) }
    }

    private func snapshotLocked() -> ExecutionSnapshot {
        ExecutionSnapshot(
            startedCount: startedCount,
            finishedCount: finishedCount,
            inFlightCount: inFlightCount,
            maxInFlightCount: maxInFlightCount
        )
    }
}

final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

final class EventRecorder: @unchecked Sendable {
    private struct Waiter {
        let predicate: @Sendable ([SequentialExecutor.Event]) -> Bool
        let continuation: ContinuationBox<[SequentialExecutor.Event]?>
    }

    private let lock = NSLock()
    private var events: [SequentialExecutor.Event] = []
    private var waiters: [UUID: Waiter] = [:]

    func record(_ event: SequentialExecutor.Event) {
        let (snapshot, continuations): ([SequentialExecutor.Event], [ContinuationBox<[SequentialExecutor.Event]?>]) = lock.withLock {
            events.append(event)
            let snapshot = events
            let matchedIDs = waiters.compactMap { id, waiter in
                waiter.predicate(snapshot) ? id : nil
            }
            let continuations = matchedIDs.compactMap { waiters.removeValue(forKey: $0)?.continuation }
            return (snapshot, continuations)
        }

        continuations.forEach { $0.resume(returning: snapshot) }
    }

    func snapshot() -> [SequentialExecutor.Event] {
        lock.withLock { events }
    }

    func wait(
        timeout: Duration = .seconds(2),
        until predicate: @escaping @Sendable ([SequentialExecutor.Event]) -> Bool
    ) async -> [SequentialExecutor.Event]? {
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            let immediateSnapshot = lock.withLock { () -> [SequentialExecutor.Event]? in
                guard !predicate(events) else { return events }
                waiters[waiterID] = Waiter(predicate: predicate, continuation: box)
                return nil
            }

            if let immediateSnapshot {
                box.resume(returning: immediateSnapshot)
                return
            }

            Task {
                try? await Task.sleep(for: timeout)
                let continuation = self.lock.withLock {
                    self.waiters.removeValue(forKey: waiterID)?.continuation
                }
                continuation?.resume(returning: nil)
            }
        }
    }
}

final class ExecutionContextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [SequentialExecutor.ExecutionContext] = []

    func record(_ context: SequentialExecutor.ExecutionContext) {
        lock.withLock {
            contexts.append(context)
        }
    }

    func snapshot() -> [SequentialExecutor.ExecutionContext] {
        lock.withLock { contexts }
    }
}

struct StubError: Error, Sendable {}

func recordEvents(
    from stream: AsyncStream<SequentialExecutor.Event>,
    into recorder: EventRecorder
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            recorder.record(event)
        }
    }
}

func eventually(
    timeout: Duration = .seconds(2),
    until predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

// MARK: Run Helpers

/// Starts `run()` in its own task and returns once the executor reports `runStarted`.
func startRun(_ executor: SequentialExecutor, events: EventRecorder) async throws -> Task<Void, Never> {
    let run = Task { await executor.run() }
    try #require(await events.wait { events in
        events.contains(where: \.isRunStarted)
    } != nil)
    return run
}

func stopRun(_ run: Task<Void, Never>) async {
    run.cancel()
    await run.value
}
