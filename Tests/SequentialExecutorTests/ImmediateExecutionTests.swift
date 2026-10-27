import Foundation
import Testing
@testable import SequentialExecutor

@Suite struct ImmediateExecutionTests {
    // MARK: runNow() Basics

    @Test func runNow_runsTheExecuteClosureOnce() async throws {
        let invocations = InvocationCounter()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: { _ = invocations.next() },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        let result = await executor.runNow()

        #expect(invocations.value() == 1)
        #expect(result.isFinished)
        await stopRun(run)
    }

    @Test func runNow_withoutActiveRun_returnsNotRunning() async {
        let invocations = InvocationCounter()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: { _ = invocations.next() },
            eventHandler: { event in
                events.record(event)
            }
        )

        let result = await executor.runNow()

        guard case let .notRunning(requestID) = result else {
            Issue.record("Expected runNow() without a run to report notRunning.")
            return
        }
        #expect(invocations.value() == 0)
        #expect(events.snapshot().compactMap(\.requestedID) == [requestID])
        #expect(events.snapshot().count == 1)
    }

    @Test func runNow_passesExecutionContextMatchingLifecycleEvents() async throws {
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
        let run = try await startRun(executor, events: events)

        let result = await executor.runNow()

        guard case let .finished(resultContext) = result else {
            Issue.record("Expected runNow() to finish.")
            return
        }
        let recorded = try #require(contexts.snapshot().first)
        #expect(recorded == resultContext)
        guard case let .runNow(requestID) = recorded.source else {
            Issue.record("Expected the execution to be attributed to runNow.")
            return
        }

        let snapshot = events.snapshot()
        let startedIndex = snapshot.firstIndex(where: \.isImmediateExecutionStarted)
        let finishedIndex = snapshot.firstIndex(where: \.isImmediateExecutionFinished)
        #expect(snapshot.compactMap(\.requestedID) == [requestID])
        #expect(startedIndex != nil && finishedIndex != nil)
        if let startedIndex, let finishedIndex {
            #expect(startedIndex < finishedIndex)
            #expect(snapshot[startedIndex].executionSignature == .started(recorded.executionID, recorded.source))
            #expect(snapshot[finishedIndex].executionSignature == .finished(recorded.executionID, recorded.source))
        }
        await stopRun(run)
    }

    @Test func runNow_emitsExecutionFailedWhenWorkThrows() async throws {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {
                throw StubError()
            },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        let result = await executor.runNow()

        guard case let .failed(context, error) = result else {
            Issue.record("Expected runNow() to return the execution failure.")
            return
        }
        let matchingFailure = events.snapshot().contains { event in
            guard case let .executionFailed(executionID, source, eventError) = event.kind else { return false }
            return executionID == context.executionID
                && source == context.source
                && eventError is StubError
        }
        #expect(error is StubError)
        #expect(matchingFailure)
        await stopRun(run)
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
        let run = try await startRun(executor, events: events)

        let caller = Task {
            await executor.runNow()
        }
        try #require(await events.wait { events in
            events.contains(where: \.isImmediateExecutionStarted)
        } != nil)

        caller.cancel()
        executionGate.open()

        let snapshot = try #require(await events.wait { events in
            events.contains(where: \.isImmediateExecutionFinished)
        })
        #expect(snapshot.filter(\.isImmediateExecutionCancelled).isEmpty)
        let callerResult = await caller.value
        #expect(callerResult.isFinished)
        await stopRun(run)
    }

    // MARK: Immediate Request Handoff

    @Test func concurrentRunNow_requestsCancelOlderImmediateExecution() async throws {
        let invocations = InvocationCounter()
        let firstExecutionGate = AsyncGate()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {
                if invocations.next() == 1 {
                    await firstExecutionGate.wait()
                }
            },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        let firstRequest = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.contains(where: \.isImmediateExecutionStarted)
        } != nil)

        let secondRequest = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.filter(\.isRequested).count == 2
        } != nil)
        #expect(invocations.value() == 1)
        firstExecutionGate.open()

        let firstResult = await firstRequest.value
        let secondResult = await secondRequest.value

        let snapshot = events.snapshot()
        let requestedIDs = snapshot.compactMap(\.requestedID)
        #expect(invocations.value() == 2)
        #expect(requestedIDs.count == 2)
        #expect(snapshot.filter(\.isImmediateExecutionStarted).count == 2)
        #expect(snapshot.filter(\.isImmediateExecutionCancelled).count == 1)
        #expect(snapshot.filter(\.isImmediateExecutionFinished).count == 1)
        if case let .cancelled(context) = firstResult {
            #expect(context.source == requestedIDs.first.map { .runNow(requestID: $0) })
        } else {
            Issue.record("Expected the first immediate execution to be cancelled.")
        }
        if case let .finished(context) = secondResult {
            #expect(context.source == requestedIDs.last.map { .runNow(requestID: $0) })
        } else {
            Issue.record("Expected the replacement immediate execution to finish.")
        }
        await stopRun(run)
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
        let run = try await startRun(executor, events: events)

        let first = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.contains(where: \.isImmediateExecutionStarted)
        } != nil)

        let concurrentRequestA = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.filter(\.isRequested).count == 2
        } != nil)
        let concurrentRequestB = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.filter(\.isRequested).count == 3
        } != nil)
        firstExecutionGate.open()

        let firstResult = await first.value
        let concurrentResultA = await concurrentRequestA.value
        let concurrentResultB = await concurrentRequestB.value

        let eventSnapshot = events.snapshot()
        let requestedIDs = eventSnapshot.compactMap(\.requestedID)
        let startedIDs = eventSnapshot.compactMap { event -> UInt? in
            if case let .executionStarted(_, .runNow(requestID)) = event.kind { return requestID }
            return nil
        }
        let finishedIDs = eventSnapshot.compactMap { event -> UInt? in
            if case let .executionFinished(_, .runNow(requestID)) = event.kind { return requestID }
            return nil
        }
        let firstRequestID = requestedIDs.first
        let middleRequestID = requestedIDs.dropFirst().first
        let latestRequestID = requestedIDs.last

        #expect(probe.snapshot().maxInFlightCount == 1)
        #expect(probe.snapshot().startedCount == 2)
        #expect(requestedIDs.count == 3)
        #expect(startedIDs == [firstRequestID, latestRequestID].compactMap { $0 })
        #expect(finishedIDs == [latestRequestID].compactMap { $0 })
        if case let .cancelled(context) = firstResult {
            #expect(context.source == firstRequestID.map { .runNow(requestID: $0) })
        } else {
            Issue.record("Expected the first request to be cancelled after starting.")
        }
        guard case let .superseded(requestID, byRequestID) = concurrentResultA else {
            Issue.record("Expected the middle request to be superseded.")
            return
        }
        #expect(requestID == middleRequestID)
        #expect(byRequestID == latestRequestID)
        if case let .finished(context) = concurrentResultB {
            #expect(context.source == latestRequestID.map { .runNow(requestID: $0) })
        } else {
            Issue.record("Expected the latest request to finish.")
        }
        await stopRun(run)
    }

    @Test func concurrentRunNow_stressPreservesSchedulingLiveness() async throws {
        // Exercise many handoffs: the newest request can finish before older requests
        // settle, whether they were superseded before starting or cancelled after starting.
        for round in 1 ... 250 {
            let events = EventRecorder()
            let executor = SequentialExecutor(
                execute: { await Task.yield() },
                eventHandler: { event in
                    events.record(event)
                }
            )
            let run = try await startRun(executor, events: events)
            await executor.updatePolicy(.interval(.seconds(60)))

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

            // The run must be waiting again after the last execution exits.
            let resumed = await events.wait { events in
                guard let lastExecutionIndex = events.lastIndex(where: { $0.isImmediateExecutionFinished || $0.isImmediateExecutionCancelled }) else { return false }
                return events[lastExecutionIndex...].contains(where: \.isWaitStarted)
            }
            let snapshot = events.snapshot()
            let requestedCount = snapshot.filter(\.isRequested).count
            let latestRequestID = snapshot.compactMap(\.requestedID).max()
            let latestRequestFinished = results.contains { result in
                guard case let .finished(context) = result else { return false }
                return context.source == latestRequestID.map { .runNow(requestID: $0) }
            }

            guard requestedCount == 20, results.count == 20, latestRequestFinished, resumed != nil else {
                let startedCount = snapshot.filter(\.isImmediateExecutionStarted).count
                let cancelledCount = snapshot.filter(\.isImmediateExecutionCancelled).count
                let finishedCount = snapshot.filter(\.isImmediateExecutionFinished).count
                Issue.record(
                    "Concurrent handoff lost liveness in round \(round): requested=\(requestedCount), settled=\(results.count), started=\(startedCount), cancelled=\(cancelledCount), finished=\(finishedCount), resumedWaiting=\(resumed != nil), latestFinished=\(latestRequestFinished)"
                )
                await stopRun(run)
                return
            }

            await stopRun(run)
        }
    }

    // MARK: Cancellation Precedence

    @Test func cancellationRequested_takesPrecedenceOverThrownError() async throws {
        let invocations = InvocationCounter()
        let firstExecutionGate = AsyncGate()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {
                if invocations.next() == 1 {
                    await firstExecutionGate.wait()
                    throw StubError()
                }
            },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        let firstRequest = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.contains(where: \.isImmediateExecutionStarted)
        } != nil)
        let secondRequest = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.filter(\.isRequested).count == 2
        } != nil)
        firstExecutionGate.open()

        let firstResult = await firstRequest.value
        _ = await secondRequest.value

        #expect(firstResult.isCancelled)
        #expect(events.snapshot().filter(\.isImmediateExecutionFailed).isEmpty)
        #expect(events.snapshot().filter(\.isImmediateExecutionCancelled).count == 1)
        await stopRun(run)
    }
}
