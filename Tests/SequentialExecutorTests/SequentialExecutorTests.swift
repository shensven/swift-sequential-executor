import Foundation
import Testing
@testable import SequentialExecutor

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
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

private struct ExecutionSnapshot: Sendable {
    let startedCount: Int
    let finishedCount: Int
    let inFlightCount: Int
    let maxInFlightCount: Int
}

private final class ExecutionProbe: @unchecked Sendable {
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

private final class InvocationCounter: @unchecked Sendable {
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

private final class EventRecorder: @unchecked Sendable {
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

private final class ExecutionContextRecorder: @unchecked Sendable {
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

private struct StubError: Error, Sendable {}

// MARK: Event Matchers - General

private extension SequentialExecutor.Event {
    var isRequested: Bool {
        if case .requested = kind { return true }
        return false
    }

    var isPolicyUpdated: Bool {
        if case .policyUpdated = kind { return true }
        return false
    }

    var isLoopStarted: Bool {
        if case .loopStarted = kind { return true }
        return false
    }

    var isLoopStopped: Bool {
        if case .loopStopped = kind { return true }
        return false
    }

    var isLoopExited: Bool {
        if case .loopExited = kind { return true }
        return false
    }

    var loopStopReason: SequentialExecutor.LoopStopReason? {
        if case let .loopStopped(_, reason) = kind { return reason }
        return nil
    }

    var isWaitStarted: Bool {
        if case .waitStarted = kind { return true }
        return false
    }

    var isWaitCancelled: Bool {
        if case .waitCancelled = kind { return true }
        return false
    }

    var waitInterval: Duration? {
        if case let .waitStarted(_, interval) = kind { return interval }
        return nil
    }
}

// MARK: Event Matchers - Scheduled Executions

private extension SequentialExecutor.Event {
    var isScheduledExecutionStarted: Bool {
        if case .executionStarted(_, .scheduledLoop(loopID: _)) = kind { return true }
        return false
    }

    var isScheduledExecutionCancelled: Bool {
        if case .executionCancelled(_, .scheduledLoop(loopID: _)) = kind { return true }
        return false
    }

    var isScheduledExecutionFinished: Bool {
        if case .executionFinished(_, .scheduledLoop(loopID: _)) = kind { return true }
        return false
    }
}

// MARK: Event Matchers - Immediate Executions

private extension SequentialExecutor.Event {
    var isImmediateExecutionStarted: Bool {
        if case .executionStarted(_, .executeNow(requestID: _)) = kind { return true }
        return false
    }

    var isImmediateExecutionCancelled: Bool {
        if case .executionCancelled(_, .executeNow(requestID: _)) = kind { return true }
        return false
    }

    var isImmediateExecutionFinished: Bool {
        if case .executionFinished(_, .executeNow(requestID: _)) = kind { return true }
        return false
    }

    var isImmediateExecutionFailed: Bool {
        if case .executionFailed(_, .executeNow(requestID: _), _) = kind { return true }
        return false
    }
}

// MARK: executeNow() Basics

@Test func executeNow_runsTheExecuteClosureOnce() async {
    let invocations = InvocationCounter()
    let executor = SequentialExecutor {
        _ = invocations.next()
    }

    await executor.executeNow()

    #expect(invocations.value() == 1)
}

@Test func executeNow_passesExecutionContextMatchingLifecycleEvents() async {
    let contexts = ExecutionContextRecorder()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: { context in
            contexts.record(context)
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.executeNow()

    let capturedContexts = contexts.snapshot()
    let capturedEvents = events.snapshot()

    #expect(capturedContexts.count == 1)

    guard let context = capturedContexts.first else {
        Issue.record("Expected the executor to pass one execution context.")
        return
    }

    let startedEvent = capturedEvents.contains { event in
        if case let .executionStarted(executionID, source) = event.kind {
            return executionID == context.executionID && source == context.source
        }
        return false
    }
    let finishedEvent = capturedEvents.contains { event in
        if case let .executionFinished(executionID, source) = event.kind {
            return executionID == context.executionID && source == context.source
        }
        return false
    }
    let eventTimes = capturedEvents.map(\.emittedAt)

    #expect(context.source == .executeNow(requestID: 1))
    #expect(startedEvent)
    #expect(finishedEvent)
    #expect(eventTimes == eventTimes.sorted())
}

@Test func executeNow_emitsExecutionFailedWhenWorkThrows() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            throw StubError()
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.executeNow()

    #expect(events.snapshot().contains(where: { $0.isImmediateExecutionFailed }))
}

// MARK: executeNow() Concurrency

@Test func concurrentExecuteNow_requestsCancelOlderImmediateExecution() async {
    let invocations = InvocationCounter()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            let invocation = invocations.next()
            if invocation == 1 {
                try await Task.sleep(for: .milliseconds(500))
            }
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    let firstRequest = Task {
        await executor.executeNow()
    }

    #expect(await events.wait { events in
        events.contains(where: { $0.isImmediateExecutionStarted })
    } != nil)

    let secondRequest = Task {
        await executor.executeNow()
    }

    await firstRequest.value
    await secondRequest.value

    let snapshot = events.snapshot()
    let requestedCount = snapshot.filter(\.isRequested).count
    let startedCount = snapshot.filter(\.isImmediateExecutionStarted).count
    let cancelledCount = snapshot.filter(\.isImmediateExecutionCancelled).count
    let finishedCount = snapshot.filter(\.isImmediateExecutionFinished).count

    #expect(invocations.value() == 2)
    #expect(requestedCount == 2)
    #expect(startedCount == 2)
    #expect(cancelledCount == 1)
    #expect(finishedCount == 1)
}

@Test func multipleConcurrentExecuteNow_onlyLatestActuallyRuns() async {
    let probe = ExecutionProbe()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            probe.begin()
            defer { probe.end() }
            try await Task.sleep(for: .milliseconds(100))
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    let first = Task { await executor.executeNow() }

    #expect(await events.wait { events in
        events.contains(where: { $0.isImmediateExecutionStarted })
    } != nil)

    let second = Task { await executor.executeNow() }
    let third = Task { await executor.executeNow() }

    await first.value
    await second.value
    await third.value

    let executionSnapshot = probe.snapshot()
    let eventSnapshot = events.snapshot()
    let requestedIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .requested(requestID) = event.kind { return requestID }
        return nil
    }
    let startedIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .executionStarted(_, .executeNow(requestID)) = event.kind { return requestID }
        return nil
    }
    let cancelledIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .executionCancelled(_, .executeNow(requestID)) = event.kind { return requestID }
        return nil
    }
    let finishedIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .executionFinished(_, .executeNow(requestID)) = event.kind { return requestID }
        return nil
    }

    #expect(executionSnapshot.maxInFlightCount == 1)
    #expect(executionSnapshot.startedCount == 2)
    #expect(requestedIDs == [1, 2, 3])
    #expect(startedIDs == [1, 3])
    #expect(cancelledIDs == [1])
    #expect(finishedIDs == [3])
}

// MARK: Policy and Loop Lifecycle

@Test func updatePolicy_emitsPolicyUpdatedEvent() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    let previousPolicy = SequentialExecutor.Policy()
    let updatedPolicy = SequentialExecutor.Policy(runLoop: .interval(.milliseconds(50)))

    await executor.updatePolicy(updatedPolicy)

    let snapshot = await events.wait { events in
        events.contains(where: { event in
            if case let .policyUpdated(previous, new) = event.kind {
                return previous == previousPolicy && new == updatedPolicy
            }
            return false
        })
    }

    #expect(snapshot != nil)
}

@Test func settingSamePolicy_doesNotEmitPolicyUpdated() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    let policy = SequentialExecutor.Policy(runLoop: .interval(.milliseconds(100)))

    await executor.updatePolicy(policy)
    await executor.updatePolicy(policy)

    try? await Task.sleep(for: .milliseconds(50))

    let policyUpdatedCount = events.snapshot().filter(\.isPolicyUpdated).count
    #expect(policyUpdatedCount == 1)

    await executor.updatePolicy(.init())
}

@Test func enablingLoop_startsScheduledExecution() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init())
    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    let snapshot = await events.wait { events in
        events.contains(where: { $0.isLoopStarted })
            && events.contains(where: { $0.isWaitStarted })
    }

    await executor.updatePolicy(.init())

    #expect(snapshot != nil)
}

@Test func updatingLoopInterval_restartsTheLoop() async {
    let initialInterval = Duration.seconds(10)
    let updatedInterval = Duration.seconds(20)
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(initialInterval)))

    #expect(await events.wait { events in
        events.contains(where: { $0.waitInterval == initialInterval })
    } != nil)

    await executor.updatePolicy(.init(runLoop: .interval(updatedInterval)))

    let snapshot = await events.wait { events in
        let loopStartCount = events.filter(\.isLoopStarted).count
        return loopStartCount >= 2
            && events.contains(where: { $0.loopStopReason == .policyUpdated })
            && events.contains(where: { $0.isWaitCancelled })
            && events.contains(where: { $0.waitInterval == updatedInterval })
    }

    await executor.updatePolicy(.init())

    #expect(snapshot != nil)
}

@Test func disablingPolicy_stopsActiveLoop() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    #expect(await events.wait { events in
        events.contains(where: { $0.isLoopStarted })
    } != nil)

    await executor.updatePolicy(.init())

    let snapshot = await events.wait { events in
        events.contains(where: { $0.loopStopReason == .policyDisabled })
    }

    #expect(snapshot != nil)
}

@Test func disablingLoop_emitsLoopExited() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    #expect(await events.wait { events in
        events.contains(where: { $0.isLoopStarted })
    } != nil)

    await executor.updatePolicy(.init())

    let snapshot = await events.wait { events in
        events.contains(where: { $0.isLoopExited })
    }

    #expect(snapshot != nil)
}

// MARK: Scheduled Execution Behavior

@Test func scheduledLoop_runsRepeatedlyWithoutOverlappingExecutions() async {
    let probe = ExecutionProbe()
    let executor = SequentialExecutor {
        probe.begin()
        defer { probe.end() }
        try await Task.sleep(for: .milliseconds(80))
    }

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    #expect(await probe.wait(timeout: .seconds(3), until: { $0.finishedCount >= 2 }) != nil)

    await executor.updatePolicy(.init())

    let snapshot = probe.snapshot()
    #expect(snapshot.finishedCount >= 2)
    #expect(snapshot.maxInFlightCount == 1)
}

@Test func scheduledExecution_emitsExecutionFinished() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    let snapshot = await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionFinished })
    }

    await executor.updatePolicy(.init())

    #expect(snapshot != nil)

    if let snapshot {
        let startedIndex = snapshot.firstIndex(where: { $0.isScheduledExecutionStarted })
        let finishedIndex = snapshot.firstIndex(where: { $0.isScheduledExecutionFinished })
        #expect(startedIndex != nil)
        #expect(finishedIndex != nil)
        if let startedIndex, let finishedIndex {
            #expect(startedIndex < finishedIndex)
        }
    }
}

// MARK: Scheduled and Immediate Interaction

@Test func executeNow_cancelsInFlightScheduledExecution_beforeRunningImmediateExecution() async {
    let invocations = InvocationCounter()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            let invocation = invocations.next()
            if invocation == 1 {
                try await Task.sleep(for: .milliseconds(500))
            }
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    #expect(await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionStarted })
    } != nil)

    await executor.executeNow()
    await executor.updatePolicy(.init())

    let snapshot = events.snapshot()
    let scheduledCancelledIndex = snapshot.firstIndex(where: { $0.isScheduledExecutionCancelled })
    let immediateStartedIndex = snapshot.firstIndex(where: { $0.isImmediateExecutionStarted })
    let immediateFinishedIndex = snapshot.firstIndex(where: { $0.isImmediateExecutionFinished })

    #expect(invocations.value() == 2)
    #expect(scheduledCancelledIndex != nil)
    #expect(immediateStartedIndex != nil)
    #expect(immediateFinishedIndex != nil)

    if let scheduledCancelledIndex, let immediateStartedIndex {
        #expect(scheduledCancelledIndex < immediateStartedIndex)
    } else {
        Issue.record("Expected the scheduled execution to be cancelled before the immediate execution started.")
    }

    if let immediateStartedIndex, let immediateFinishedIndex {
        #expect(immediateStartedIndex < immediateFinishedIndex)
    } else {
        Issue.record("Expected the immediate execution to start and finish.")
    }
}

@Test func scheduledLoop_resumesAfterExecuteNow() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    #expect(await events.wait { events in
        events.contains(where: { $0.isWaitStarted })
    } != nil)

    await executor.executeNow()

    let snapshot = await events.wait { events in
        let loopStartCount = events.filter(\.isLoopStarted).count
        return loopStartCount >= 2
    }

    await executor.updatePolicy(.init())

    #expect(snapshot != nil)
}
