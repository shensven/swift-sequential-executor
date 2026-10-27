import Foundation
import Testing
@testable import SequentialExecutor

@Suite struct RunLifetimeTests {
    // MARK: Run Lifetime

    @Test func cancellingRun_cancelsActiveWaitAndEndsRun() async throws {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        await executor.updatePolicy(.interval(.seconds(60)))
        try #require(await events.wait { events in
            events.contains(where: \.isWaitStarted)
        } != nil)

        await stopRun(run)

        let snapshot = events.snapshot()
        let startedIndex = snapshot.firstIndex(where: \.isRunStarted)
        let waitIndex = snapshot.firstIndex(where: \.isWaitStarted)
        let cancelledIndex = snapshot.firstIndex(where: \.isWaitCancelled)
        let endedIndex = snapshot.firstIndex(where: \.isRunEnded)
        if let startedIndex, let waitIndex, let cancelledIndex, let endedIndex {
            #expect(startedIndex < waitIndex)
            #expect(waitIndex < cancelledIndex)
            #expect(cancelledIndex < endedIndex)
            #expect(endedIndex == snapshot.indices.last)
        } else {
            Issue.record("Expected runStarted, waitStarted, waitCancelled, runEnded in order.")
        }
    }

    @Test func cancellingRun_cancelsInFlightExecution() async throws {
        let executionGate = AsyncGate()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {
                await executionGate.wait()
                try Task.checkCancellation()
            },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        let request = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.contains(where: \.isImmediateExecutionStarted)
        } != nil)

        run.cancel()
        executionGate.open()
        await run.value
        let result = await request.value

        let snapshot = events.snapshot()
        #expect(result.isCancelled)
        #expect(snapshot.filter(\.isImmediateExecutionCancelled).count == 1)
        #expect(snapshot.last?.isRunEnded == true)
    }

    @Test func pendingRequestWhenRunEnds_completesAsNotRunning() async throws {
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

        run.cancel()
        firstExecutionGate.open()
        await run.value

        let firstResult = await firstRequest.value
        #expect(firstResult.isCancelled)
        guard case .notRunning = await secondRequest.value else {
            Issue.record("Expected the pending request to complete as notRunning when the run ended.")
            return
        }
        #expect(invocations.value() == 1)
    }

    @Test func secondRun_waitsForActiveRunToEnd() async throws {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )
        let firstRun = try await startRun(executor, events: events)

        let secondRun = Task { await executor.run() }
        await executor.runNow()
        #expect(events.snapshot().filter(\.isRunStarted).count == 1)

        await stopRun(firstRun)
        let snapshot = try #require(await events.wait { events in
            events.filter(\.isRunStarted).count == 2
        })
        await stopRun(secondRun)

        let runIDs = snapshot.compactMap(\.runStartedID)
        let endedIndex = snapshot.firstIndex(where: \.isRunEnded)
        let secondStartIndex = snapshot.indices.filter { snapshot[$0].isRunStarted }.dropFirst().first
        #expect(runIDs.count == 2)
        #expect(runIDs.first != runIDs.last)
        if let endedIndex, let secondStartIndex {
            #expect(endedIndex < secondStartIndex)
        } else {
            Issue.record("Expected the first run to end before the second run started.")
        }
    }

    @Test func cancelledRunCall_returnsWithoutStarting() async throws {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )

        let run = Task { await executor.run() }
        run.cancel()
        await run.value

        // 取消可能赶在 run() 登记之前（没有任何事件），也可能赶在之后（runStarted 随即 runEnded）；
        // 两种时序下都不能留下一个没有结束的 run。
        let snapshot = events.snapshot()
        #expect(snapshot.filter(\.isRunStarted).count == snapshot.filter(\.isRunEnded).count)
        #expect(snapshot.allSatisfy { $0.isRunStarted || $0.isRunEnded })
    }
}
