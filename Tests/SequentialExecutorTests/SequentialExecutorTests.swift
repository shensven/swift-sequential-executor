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

private final class AsyncGate: @unchecked Sendable {
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

private func recordEvents(
    from stream: AsyncStream<SequentialExecutor.Event>,
    into recorder: EventRecorder
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            recorder.record(event)
        }
    }
}

private func eventually(
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

// MARK: Event Matchers - General

private extension SequentialExecutor.Event {
    var requestedID: UInt? {
        if case let .requested(requestID) = kind { return requestID }
        return nil
    }

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

private enum ExecutionEventSignature: Equatable {
    case requested(UInt)
    case started(UUID, SequentialExecutor.ExecutionSource)
    case finished(UUID, SequentialExecutor.ExecutionSource)
    case cancelled(UUID, SequentialExecutor.ExecutionSource)
}

private extension SequentialExecutor.Event {
    var executionSignature: ExecutionEventSignature? {
        switch kind {
        case let .requested(requestID):
            return .requested(requestID)
        case let .executionStarted(executionID, source):
            return .started(executionID, source)
        case let .executionFinished(executionID, source):
            return .finished(executionID, source)
        case let .executionCancelled(executionID, source):
            return .cancelled(executionID, source)
        default:
            return nil
        }
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

    var isScheduledExecutionFailed: Bool {
        if case .executionFailed(_, .scheduledLoop(loopID: _), _) = kind { return true }
        return false
    }
}

// MARK: Event Matchers - Immediate Executions

private extension SequentialExecutor.Event {
    var isImmediateExecutionStarted: Bool {
        if case .executionStarted(_, .runNow(requestID: _)) = kind { return true }
        return false
    }

    var isImmediateExecutionCancelled: Bool {
        if case .executionCancelled(_, .runNow(requestID: _)) = kind { return true }
        return false
    }

    var isImmediateExecutionFinished: Bool {
        if case .executionFinished(_, .runNow(requestID: _)) = kind { return true }
        return false
    }

    var isImmediateExecutionFailed: Bool {
        if case .executionFailed(_, .runNow(requestID: _), _) = kind { return true }
        return false
    }
}

// MARK: runNow() Basics

@Test func runNow_runsTheExecuteClosureOnce() async {
    let invocations = InvocationCounter()
    let executor = SequentialExecutor {
        _ = invocations.next()
    }

    let result = await executor.runNow()

    #expect(invocations.value() == 1)
    guard case let .finished(context) = result else {
        Issue.record("Expected the immediate execution to finish successfully.")
        return
    }
    #expect(context.source == .runNow(requestID: 1))
}

@Test func runNow_passesExecutionContextMatchingLifecycleEvents() async {
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

    let result = await executor.runNow()

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
    #expect(context.source == .runNow(requestID: 1))
    if case let .finished(resultContext) = result {
        #expect(resultContext == context)
    } else {
        Issue.record("Expected runNow() to return the finished execution context.")
    }
    #expect(startedEvent)
    #expect(finishedEvent)
}

@Test func runNow_emitsExecutionFailedWhenWorkThrows() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            throw StubError()
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    let result = await executor.runNow()

    guard case let .failed(context, error) = result else {
        Issue.record("Expected runNow() to return the execution failure.")
        return
    }
    let snapshot = events.snapshot()
    let matchingFailure = snapshot.contains { event in
        guard case let .executionFailed(executionID, source, eventError) = event.kind else { return false }
        return executionID == context.executionID
            && source == context.source
            && eventError is StubError
    }
    #expect(context.source == .runNow(requestID: 1))
    #expect(error is StubError)
    #expect(matchingFailure)
}

@Test func cancellingRunNowCaller_doesNotWithdrawAcceptedExecution() async throws {
    let executionGate = AsyncGate()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            await executionGate.wait()
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    let caller = Task {
        await executor.runNow()
    }

    try #require(await events.wait { events in
        events.contains(where: \.isImmediateExecutionStarted)
    } != nil)

    caller.cancel()
    executionGate.open()
    let result = await caller.value

    guard case .finished = result else {
        Issue.record("Expected accepted work to finish independently of caller cancellation.")
        return
    }
    #expect(!events.snapshot().contains(where: { $0.isImmediateExecutionCancelled }))
}

@Test func eventsStream_receivesImmediateExecutionLifecycleEvents() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(execute: {})
    let stream = await executor.events()
    let collector = recordEvents(from: stream, into: events)

    await executor.runNow()

    let snapshot = await events.wait { events in
        events.contains(where: { $0.isRequested })
            && events.contains(where: { $0.isImmediateExecutionStarted })
            && events.contains(where: { $0.isImmediateExecutionFinished })
    }

    collector.cancel()

    #expect(snapshot != nil)
}

@Test func eventsStream_receivesSameExecutionEventsAsEventHandler() async throws {
    let callbackEvents = EventRecorder()
    let streamEvents = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            callbackEvents.record(event)
        }
    )
    let stream = await executor.events()
    let collector = recordEvents(from: stream, into: streamEvents)

    await executor.runNow()

    let callbackSnapshot = try #require(await callbackEvents.wait { events in
        events.contains(where: { $0.isImmediateExecutionFinished })
    })
    let streamSnapshot = try #require(await streamEvents.wait { events in
        events.contains(where: { $0.isImmediateExecutionFinished })
    })

    collector.cancel()

    let callbackSignatures = callbackSnapshot.compactMap(\.executionSignature)
    let streamSignatures = streamSnapshot.compactMap(\.executionSignature)
    #expect(callbackSignatures == streamSignatures)
    #expect(callbackSignatures.count == 3)
}

@Test func eventsStream_doesNotReplayEventsEmittedBeforeSubscription() async throws {
    let streamedEvents = EventRecorder()
    let executor = SequentialExecutor(execute: {})

    await executor.runNow()

    let stream = await executor.events()
    let collector = recordEvents(from: stream, into: streamedEvents)
    await executor.runNow()

    let snapshot = try #require(await streamedEvents.wait { events in
        events.contains(where: { $0.isImmediateExecutionFinished })
    })
    collector.cancel()

    #expect(snapshot.compactMap(\.requestedID) == [2])
    #expect(snapshot.compactMap(\.executionSignature).count == 3)
}

@Test func multipleEventStreams_receiveTheSameExecutionEvents() async throws {
    let firstEvents = EventRecorder()
    let secondEvents = EventRecorder()
    let executor = SequentialExecutor(execute: {})
    let firstCollector = recordEvents(from: await executor.events(), into: firstEvents)
    let secondCollector = recordEvents(from: await executor.events(), into: secondEvents)

    await executor.runNow()

    let firstSnapshot = try #require(await firstEvents.wait { events in
        events.contains(where: { $0.isImmediateExecutionFinished })
    })
    let secondSnapshot = try #require(await secondEvents.wait { events in
        events.contains(where: { $0.isImmediateExecutionFinished })
    })
    firstCollector.cancel()
    secondCollector.cancel()

    #expect(firstSnapshot.compactMap(\.executionSignature) == secondSnapshot.compactMap(\.executionSignature))
}

enum BoundedBufferingScenario: Sendable {
    case oldest
    case newest

    var policy: SequentialExecutor.EventBufferingPolicy {
        switch self {
        case .oldest: return .bufferingOldest(1)
        case .newest: return .bufferingNewest(1)
        }
    }
}

@Test(arguments: [BoundedBufferingScenario.oldest, .newest])
func eventsStream_respectsBoundedBuffering(_ scenario: BoundedBufferingScenario) async throws {
    let executor = SequentialExecutor(execute: {})
    let stream = await executor.events(bufferingPolicy: scenario.policy)

    await executor.runNow()

    var iterator = stream.makeAsyncIterator()
    let bufferedEvent = try #require(await iterator.next())
    switch scenario {
    case .oldest:
        #expect(bufferedEvent.requestedID == 1)
    case .newest:
        #expect(bufferedEvent.isImmediateExecutionFinished)
    }
}

// MARK: runNow() Concurrency

@Test func concurrentRunNow_requestsCancelOlderImmediateExecution() async throws {
    let invocations = InvocationCounter()
    let firstExecutionGate = AsyncGate()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            let invocation = invocations.next()
            if invocation == 1 {
                await firstExecutionGate.wait()
            }
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    let firstRequest = Task {
        await executor.runNow()
    }

    try #require(await events.wait { events in
        events.contains(where: { $0.isImmediateExecutionStarted })
    } != nil)

    let secondRequest = Task {
        await executor.runNow()
    }

    try #require(await events.wait { events in
        events.contains(where: { $0.requestedID == 2 })
    } != nil)
    #expect(invocations.value() == 1)
    firstExecutionGate.open()

    let firstResult = await firstRequest.value
    let secondResult = await secondRequest.value

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
    if case let .cancelled(context) = firstResult {
        #expect(context.source == .runNow(requestID: 1))
    } else {
        Issue.record("Expected the first immediate execution to be cancelled.")
    }
    if case let .finished(context) = secondResult {
        #expect(context.source == .runNow(requestID: 2))
    } else {
        Issue.record("Expected the replacement immediate execution to finish.")
    }
}

@Test func multipleConcurrentRunNow_onlyLatestActuallyRuns() async throws {
    let probe = ExecutionProbe()
    let firstExecutionGate = AsyncGate()
    let invocations = InvocationCounter()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            probe.begin()
            defer { probe.end() }
            if invocations.next() == 1 {
                await firstExecutionGate.wait()
            }
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    let first = Task { await executor.runNow() }

    try #require(await events.wait { events in
        events.contains(where: { $0.isImmediateExecutionStarted })
    } != nil)

    let concurrentRequestA = Task { await executor.runNow() }
    let concurrentRequestB = Task { await executor.runNow() }

    try #require(await events.wait { events in
        events.filter(\.isRequested).count == 3
    } != nil)
    firstExecutionGate.open()

    let firstResult = await first.value
    let concurrentResultA = await concurrentRequestA.value
    let concurrentResultB = await concurrentRequestB.value

    let executionSnapshot = probe.snapshot()
    let eventSnapshot = events.snapshot()
    let requestedIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .requested(requestID) = event.kind { return requestID }
        return nil
    }
    let startedIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .executionStarted(_, .runNow(requestID)) = event.kind { return requestID }
        return nil
    }
    let cancelledIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .executionCancelled(_, .runNow(requestID)) = event.kind { return requestID }
        return nil
    }
    let finishedIDs = eventSnapshot.compactMap { event -> UInt? in
        if case let .executionFinished(_, .runNow(requestID)) = event.kind { return requestID }
        return nil
    }

    #expect(executionSnapshot.maxInFlightCount == 1)
    #expect(executionSnapshot.startedCount == 2)
    #expect(requestedIDs == [1, 2, 3])
    #expect(startedIDs == [1, 3])
    #expect(cancelledIDs == [1])
    #expect(finishedIDs == [3])
    if case let .cancelled(context) = firstResult {
        #expect(context.source == .runNow(requestID: 1))
    } else {
        Issue.record("Expected the first request to be cancelled after starting.")
    }
    switch (concurrentResultA, concurrentResultB) {
    case let (.superseded(requestID, byRequestID), .finished(context)),
         let (.finished(context), .superseded(requestID, byRequestID)):
        #expect(requestID == 2)
        #expect(byRequestID == 3)
        #expect(context.source == .runNow(requestID: 3))
    default:
        Issue.record("Expected one concurrent request to be superseded and the latest request to finish.")
    }
}

@Test func concurrentRunNow_stressPreservesSchedulingLiveness() async {
    // Exercise many handoffs because actor continuations may resume in any order.
    // In particular, the newest request can finish before an older request settles,
    // whether that older request was superseded before starting or cancelled after it
    // had already started.
    for round in 1 ... 250 {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: { await Task.yield() },
            eventHandler: { event in
                events.record(event)
            }
        )

        await executor.updatePolicy(.init(runLoop: .interval(.seconds(60))))

        let results = await withTaskGroup(
            of: SequentialExecutor.RunNowResult.self,
            returning: [SequentialExecutor.RunNowResult].self
        ) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    await executor.runNow()
                }
            }

            return await group.reduce(into: []) { results, result in
                results.append(result)
            }
        }

        let snapshot = events.snapshot()
        let requestedCount = snapshot.filter(\.isRequested).count
        let loopStartCount = snapshot.filter(\.isLoopStarted).count
        let latestRequestFinished = results.contains { result in
            guard case let .finished(context) = result else { return false }
            return context.source == .runNow(requestID: 20)
        }

        guard requestedCount == 20, results.count == 20, latestRequestFinished, loopStartCount >= 2 else {
            let startedCount = snapshot.filter(\.isImmediateExecutionStarted).count
            let cancelledCount = snapshot.filter(\.isImmediateExecutionCancelled).count
            let finishedCount = snapshot.filter(\.isImmediateExecutionFinished).count
            let settledCount = results.count
            Issue.record(
                "Concurrent handoff lost liveness in round \(round): requested=\(requestedCount), settled=\(settledCount), started=\(startedCount), cancelled=\(cancelledCount), finished=\(finishedCount), loopStarted=\(loopStartCount), latestFinished=\(latestRequestFinished)"
            )
            await executor.updatePolicy(.init())
            return
        }

        await executor.updatePolicy(.init())
    }
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

    let snapshot = events.snapshot()
    let policyUpdatedCount = snapshot.filter(\.isPolicyUpdated).count
    let loopStartedCount = snapshot.filter(\.isLoopStarted).count
    let loopStoppedCount = snapshot.filter(\.isLoopStopped).count
    #expect(policyUpdatedCount == 1)
    #expect(loopStartedCount == 1)
    #expect(loopStoppedCount == 0)

    await executor.updatePolicy(.init())
}

@Test func enablingScheduling_startsLoopAndInitialWait() async {
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

@Test func enablingScheduling_doesNotExecuteImmediately() async {
    let invocations = InvocationCounter()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            _ = invocations.next()
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.seconds(60))))

    let snapshot = events.snapshot()
    #expect(snapshot.contains(where: { $0.isLoopStarted }))
    #expect(snapshot.contains(where: { $0.isScheduledExecutionStarted }) == false)
    #expect(invocations.value() == 0)

    await executor.updatePolicy(.init())
}

@Test func updatingLoopInterval_restartsTheLoop() async throws {
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

    let initialSnapshot = try #require(await events.wait { events in
        events.contains(where: { $0.waitInterval == initialInterval })
    })
    let initialLoopID = try #require(initialSnapshot.compactMap { event -> UUID? in
        guard case let .waitStarted(loopID, interval) = event.kind, interval == initialInterval else { return nil }
        return loopID
    }.first)

    await executor.updatePolicy(.init(runLoop: .interval(updatedInterval)))

    let snapshot = try #require(await events.wait { events in
        let replacementWaitStarted = events.contains { event in
            guard case let .waitStarted(loopID, interval) = event.kind else { return false }
            return loopID != initialLoopID && interval == updatedInterval
        }
        let initialLoopStopped = events.contains { event in
            guard case let .loopStopped(loopID, reason) = event.kind else { return false }
            return loopID == initialLoopID && reason == .policyUpdated
        }
        let initialWaitCancelled = events.contains { event in
            guard case let .waitCancelled(loopID) = event.kind else { return false }
            return loopID == initialLoopID
        }
        return replacementWaitStarted && initialLoopStopped && initialWaitCancelled
    })

    await executor.updatePolicy(.init())

    let stoppedInitialLoop = snapshot.contains { event in
        guard case let .loopStopped(loopID, reason) = event.kind else { return false }
        return loopID == initialLoopID && reason == .policyUpdated
    }
    let cancelledInitialWait = snapshot.contains { event in
        guard case let .waitCancelled(loopID) = event.kind else { return false }
        return loopID == initialLoopID
    }
    #expect(stoppedInitialLoop)
    #expect(cancelledInitialWait)
}

@Test func disablingScheduling_doesNotCancelActiveExecution() async throws {
    let executionGate = AsyncGate()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            await executionGate.wait()
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(10))))
    try #require(await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionStarted })
    } != nil)

    await executor.updatePolicy(.init())
    #expect(events.snapshot().contains(where: { $0.isScheduledExecutionCancelled }) == false)

    executionGate.open()
    let snapshot = await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionFinished })
            && events.contains(where: { $0.isLoopExited })
    }

    #expect(snapshot != nil)
    #expect(events.snapshot().contains(where: { $0.isScheduledExecutionCancelled }) == false)
}

@Test func updatingInterval_doesNotCancelActiveExecutionAndAppliesAfterItFinishes() async throws {
    let executionGate = AsyncGate()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            await executionGate.wait()
        },
        eventHandler: { event in
            events.record(event)
        }
    )
    let updatedInterval = Duration.seconds(60)

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(10))))
    try #require(await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionStarted })
    } != nil)

    await executor.updatePolicy(.init(runLoop: .interval(updatedInterval)))
    #expect(events.snapshot().contains(where: { $0.isScheduledExecutionCancelled }) == false)
    executionGate.open()

    let snapshot = await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionFinished })
            && events.contains(where: { $0.waitInterval == updatedInterval })
    }

    await executor.updatePolicy(.init())

    #expect(snapshot != nil)
    #expect(events.snapshot().contains(where: { $0.isScheduledExecutionCancelled }) == false)
}

@Test func disablingPolicy_stopsActiveLoop() async throws {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    try #require(await events.wait { events in
        events.contains(where: { $0.isLoopStarted })
    } != nil)

    await executor.updatePolicy(.init())

    let snapshot = await events.wait { events in
        events.contains(where: { $0.loopStopReason == .policyDisabled })
    }

    #expect(snapshot != nil)
}

@Test func disablingLoop_emitsLoopExited() async throws {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    try #require(await events.wait { events in
        events.contains(where: { $0.isLoopStarted })
    } != nil)

    await executor.updatePolicy(.init())

    let snapshot = await events.wait { events in
        events.contains(where: { $0.isLoopExited })
    }

    #expect(snapshot != nil)
}

@Test func stoppingLoopImmediately_preservesLifecycleEventOrder() async {
    for _ in 0 ..< 50 {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )

        await executor.updatePolicy(.init(runLoop: .interval(.seconds(60))))
        await executor.updatePolicy(.init())

        let snapshot = await events.wait { events in
            events.contains(where: { $0.isLoopExited })
        }
        guard let snapshot else {
            Issue.record("Expected the stopped loop to exit.")
            return
        }

        let startedIndex = snapshot.firstIndex(where: { $0.isLoopStarted })
        let stoppedIndex = snapshot.firstIndex(where: { $0.isLoopStopped })
        let exitedIndex = snapshot.firstIndex(where: { $0.isLoopExited })
        #expect(startedIndex != nil)
        #expect(stoppedIndex != nil)
        #expect(exitedIndex != nil)
        if let startedIndex, let stoppedIndex, let exitedIndex {
            #expect(startedIndex < stoppedIndex)
            #expect(stoppedIndex < exitedIndex)
        }
    }
}

@Test func scheduledWait_doesNotKeepExecutorAlive() async {
    let events = EventRecorder()
    var executor: SequentialExecutor? = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )
    let executorReference: @Sendable () -> SequentialExecutor? = { [weak executor] in executor }

    await executor?.updatePolicy(.init(runLoop: .interval(.seconds(60))))
    #expect(await events.wait { events in
        events.contains(where: { $0.isWaitStarted })
    } != nil)

    executor = nil
    #expect(await eventually { executorReference() == nil })
}

// MARK: Scheduled Execution Behavior

@Test func scheduledLoop_runsRepeatedlyWithoutOverlappingExecutions() async {
    let probe = ExecutionProbe()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            probe.begin()
            defer { probe.end() }
            try await Task.sleep(for: .milliseconds(80))
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    #expect(await probe.wait(timeout: .seconds(3), until: { $0.finishedCount >= 2 }) != nil)

    await executor.updatePolicy(.init())

    let snapshot = probe.snapshot()
    #expect(snapshot.finishedCount >= 2)
    #expect(snapshot.maxInFlightCount == 1)

    let eventSnapshot = events.snapshot()
    let waitStartedIndices = eventSnapshot.indices.filter { eventSnapshot[$0].isWaitStarted }
    let executionStartedIndices = eventSnapshot.indices.filter { eventSnapshot[$0].isScheduledExecutionStarted }
    let executionFinishedIndices = eventSnapshot.indices.filter { eventSnapshot[$0].isScheduledExecutionFinished }
    #expect(waitStartedIndices.count >= 2)
    #expect(executionStartedIndices.count >= 2)
    #expect(executionFinishedIndices.count >= 2)
    if waitStartedIndices.count >= 2, executionStartedIndices.count >= 2, executionFinishedIndices.count >= 2 {
        #expect(waitStartedIndices[0] < executionStartedIndices[0])
        #expect(executionStartedIndices[0] < executionFinishedIndices[0])
        #expect(executionFinishedIndices[0] < waitStartedIndices[1])
        #expect(waitStartedIndices[1] < executionStartedIndices[1])
        #expect(executionStartedIndices[1] < executionFinishedIndices[1])
    }
}

@Test func scheduledFailure_emitsFailureAndSchedulingContinues() async {
    let invocations = InvocationCounter()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            if invocations.next() == 1 {
                throw StubError()
            }
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(10))))
    let snapshot = await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionFailed })
            && events.contains(where: { $0.isScheduledExecutionFinished })
    }
    await executor.updatePolicy(.init())

    #expect(snapshot != nil)
    #expect(invocations.value() >= 2)
    if let snapshot {
        let failedIndex = snapshot.firstIndex(where: { $0.isScheduledExecutionFailed })
        let finishedIndex = snapshot.firstIndex(where: { $0.isScheduledExecutionFinished })
        if let failedIndex, let finishedIndex {
            #expect(failedIndex < finishedIndex)
        }
    }
}

@Test func scheduledExecution_emitsExecutionFinished() async throws {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {},
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    let snapshot = try #require(await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionFinished })
    })

    await executor.updatePolicy(.init())

    let startedIndex = try #require(snapshot.firstIndex(where: { $0.isScheduledExecutionStarted }))
    let finishedIndex = try #require(snapshot.firstIndex(where: { $0.isScheduledExecutionFinished }))
    guard case let .executionStarted(startedID, startedSource) = snapshot[startedIndex].kind,
          case let .executionFinished(finishedID, finishedSource) = snapshot[finishedIndex].kind
    else {
        Issue.record("Expected matching scheduled execution lifecycle events.")
        return
    }
    #expect(startedIndex < finishedIndex)
    #expect(startedID == finishedID)
    #expect(startedSource == finishedSource)
}

// MARK: Scheduled and Immediate Interaction

@Test func runNow_cancelsInFlightScheduledExecution_beforeRunningImmediateExecution() async throws {
    let invocations = InvocationCounter()
    let scheduledExecutionGate = AsyncGate()
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            let invocation = invocations.next()
            if invocation == 1 {
                await scheduledExecutionGate.wait()
            }
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.milliseconds(50))))

    try #require(await events.wait { events in
        events.contains(where: { $0.isScheduledExecutionStarted })
    } != nil)

    let immediateRequest = Task {
        await executor.runNow()
    }
    try #require(await events.wait { events in
        events.contains(where: { $0.isRequested })
    } != nil)
    #expect(invocations.value() == 1)
    scheduledExecutionGate.open()

    let immediateResult = await immediateRequest.value
    await executor.updatePolicy(.init())

    let snapshot = events.snapshot()
    let scheduledCancelledIndex = snapshot.firstIndex(where: { $0.isScheduledExecutionCancelled })
    let immediateStartedIndex = snapshot.firstIndex(where: { $0.isImmediateExecutionStarted })
    let immediateFinishedIndex = snapshot.firstIndex(where: { $0.isImmediateExecutionFinished })

    #expect(invocations.value() == 2)
    #expect(scheduledCancelledIndex != nil)
    #expect(immediateStartedIndex != nil)
    #expect(immediateFinishedIndex != nil)
    if case let .finished(context) = immediateResult {
        #expect(context.source == .runNow(requestID: 1))
    } else {
        Issue.record("Expected the immediate replacement execution to finish.")
    }

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

@Test func scheduledLoop_resumesAfterRunNow() async {
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

    await executor.runNow()

    let snapshot = await events.wait { events in
        let loopStartCount = events.filter(\.isLoopStarted).count
        return loopStartCount >= 2
    }

    await executor.updatePolicy(.init())

    #expect(snapshot != nil)
}

@Test func scheduledLoop_resumesAfterImmediateExecutionFails() async {
    let events = EventRecorder()
    let executor = SequentialExecutor(
        execute: {
            throw StubError()
        },
        eventHandler: { event in
            events.record(event)
        }
    )

    await executor.updatePolicy(.init(runLoop: .interval(.seconds(60))))
    let result = await executor.runNow()
    let snapshot = await events.wait { events in
        events.filter(\.isLoopStarted).count >= 2
    }
    await executor.updatePolicy(.init())

    guard case let .failed(context, error) = result else {
        Issue.record("Expected the immediate execution to fail.")
        return
    }
    #expect(context.source == .runNow(requestID: 1))
    #expect(error is StubError)
    #expect(snapshot != nil)
}
