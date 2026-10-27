import Foundation
import Testing
@testable import SequentialExecutor

@Suite struct SchedulingTests {
    // MARK: Policy and Waiting

    @Test func updatePolicy_emitsPolicyUpdatedEvent() async {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )

        let previousPolicy = SequentialExecutor.Policy.paused
        let updatedPolicy = SequentialExecutor.Policy.interval(.milliseconds(50))
        await executor.updatePolicy(updatedPolicy)

        let snapshot = events.snapshot()
        let matches = snapshot.contains { event in
            guard case let .policyUpdated(previous, new) = event.kind else { return false }
            return previous == previousPolicy && new == updatedPolicy
        }
        #expect(matches)
        #expect(snapshot.count == 1)
    }

    @Test func settingSamePolicy_doesNotEmitPolicyUpdated() async {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )

        let policy = SequentialExecutor.Policy.interval(.milliseconds(100))
        await executor.updatePolicy(policy)
        await executor.updatePolicy(policy)

        #expect(events.snapshot().filter(\.isPolicyUpdated).count == 1)
    }

    @Test func settingInterval_startsWaitWithoutExecutingImmediately() async throws {
        let invocations = InvocationCounter()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: { _ = invocations.next() },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        await executor.updatePolicy(.interval(.seconds(60)))

        let snapshot = try #require(await events.wait { events in
            events.contains(where: \.isWaitStarted)
        })
        #expect(snapshot.first(where: \.isWaitStarted)?.waitInterval == .seconds(60))
        #expect(snapshot.contains(where: \.isExecutionStarted) == false)
        #expect(invocations.value() == 0)
        await stopRun(run)
    }

    @Test func pausedRun_idlesWithoutWaitEvents() async throws {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        await executor.runNow()

        let snapshot = events.snapshot()
        #expect(snapshot.contains(where: \.isWaitStarted) == false)
        #expect(snapshot.contains { $0.isImmediateExecutionFinished })
        await stopRun(run)
    }

    @Test func updatingInterval_restartsTheWait() async throws {
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)
        let initialInterval = Duration.seconds(60)
        let updatedInterval = Duration.seconds(120)

        await executor.updatePolicy(.interval(initialInterval))
        try #require(await events.wait { events in
            events.contains(where: { $0.waitInterval == initialInterval })
        } != nil)

        await executor.updatePolicy(.interval(updatedInterval))
        let snapshot = try #require(await events.wait { events in
            events.contains(where: { $0.waitInterval == updatedInterval })
        })

        let initialIndex = snapshot.firstIndex(where: { $0.waitInterval == initialInterval })
        let cancelledIndex = snapshot.firstIndex(where: \.isWaitCancelled)
        let updatedIndex = snapshot.firstIndex(where: { $0.waitInterval == updatedInterval })
        if let initialIndex, let cancelledIndex, let updatedIndex {
            #expect(initialIndex < cancelledIndex)
            #expect(cancelledIndex < updatedIndex)
        } else {
            Issue.record("Expected the first wait to be cancelled before the second wait started.")
        }
        #expect(snapshot.contains(where: \.isIntervalElapsed) == false)
        await stopRun(run)
    }

    @Test func pausing_cancelsActiveWait() async throws {
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

        await executor.updatePolicy(.paused)
        let snapshot = try #require(await events.wait { events in
            events.contains(where: \.isWaitCancelled)
        })

        #expect(snapshot.filter(\.isWaitStarted).count == 1)
        #expect(snapshot.contains(where: \.isIntervalElapsed) == false)
        await stopRun(run)
    }

    @Test func pausing_doesNotCancelActiveExecution() async throws {
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

        await executor.updatePolicy(.interval(.milliseconds(10)))
        try #require(await events.wait { events in
            events.contains(where: \.isScheduledExecutionStarted)
        } != nil)

        await executor.updatePolicy(.paused)
        executionGate.open()

        let snapshot = try #require(await events.wait { events in
            events.contains(where: \.isScheduledExecutionFinished)
        })
        #expect(snapshot.filter(\.isScheduledExecutionCancelled).isEmpty)
        #expect(snapshot.filter(\.isScheduledExecutionStarted).count == 1)
        await stopRun(run)
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
        let run = try await startRun(executor, events: events)
        let updatedInterval = Duration.seconds(60)

        await executor.updatePolicy(.interval(.milliseconds(10)))
        try #require(await events.wait { events in
            events.contains(where: \.isScheduledExecutionStarted)
        } != nil)

        await executor.updatePolicy(.interval(updatedInterval))
        executionGate.open()

        let snapshot = try #require(await events.wait { events in
            events.contains(where: { $0.waitInterval == updatedInterval })
        })
        let finishedIndex = snapshot.firstIndex(where: \.isScheduledExecutionFinished)
        let updatedWaitIndex = snapshot.firstIndex(where: { $0.waitInterval == updatedInterval })
        #expect(snapshot.filter(\.isScheduledExecutionCancelled).isEmpty)
        if let finishedIndex, let updatedWaitIndex {
            #expect(finishedIndex < updatedWaitIndex)
        } else {
            Issue.record("Expected the execution to finish before the new interval was applied.")
        }
        await stopRun(run)
    }

    // MARK: Scheduled Executions

    @Test func scheduledExecutions_runRepeatedlyWithoutOverlapping() async throws {
        let probe = ExecutionProbe()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {
                probe.begin()
                defer { probe.end() }
                try await Task.sleep(for: .milliseconds(5))
            },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        await executor.updatePolicy(.interval(.milliseconds(20)))
        let snapshot = try #require(await events.wait { events in
            events.filter(\.isScheduledExecutionFinished).count >= 2
        })
        await stopRun(run)

        let waitStartedIndices = snapshot.indices.filter { snapshot[$0].isWaitStarted }
        let startedIndices = snapshot.indices.filter { snapshot[$0].isScheduledExecutionStarted }
        let finishedIndices = snapshot.indices.filter { snapshot[$0].isScheduledExecutionFinished }
        #expect(probe.snapshot().maxInFlightCount == 1)
        #expect(startedIndices.count >= 2)
        if waitStartedIndices.count >= 2, startedIndices.count >= 2, finishedIndices.count >= 2 {
            #expect(waitStartedIndices[0] < startedIndices[0])
            #expect(startedIndices[0] < finishedIndices[0])
            #expect(finishedIndices[0] < waitStartedIndices[1])
            #expect(waitStartedIndices[1] < startedIndices[1])
        } else {
            Issue.record("Expected at least two wait, start, finish cycles.")
        }
    }

    @Test func scheduledFailure_emitsFailureAndSchedulingContinues() async throws {
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

        await executor.updatePolicy(.interval(.milliseconds(10)))
        let snapshot = try #require(await events.wait { events in
            guard let failedIndex = events.firstIndex(where: \.isScheduledExecutionFailed) else { return false }
            return events[failedIndex...].contains(where: \.isWaitStarted)
        })
        await stopRun(run)

        #expect(snapshot.contains { $0.isScheduledExecutionFailed })
        #expect(snapshot.filter(\.isWaitStarted).count >= 2)
    }

    @Test func runNow_cancelsInFlightScheduledExecution_beforeRunningImmediateExecution() async throws {
        let invocations = InvocationCounter()
        let scheduledExecutionGate = AsyncGate()
        let events = EventRecorder()
        let executor = SequentialExecutor(
            execute: {
                if invocations.next() == 1 {
                    await scheduledExecutionGate.wait()
                }
            },
            eventHandler: { event in
                events.record(event)
            }
        )
        let run = try await startRun(executor, events: events)

        await executor.updatePolicy(.interval(.milliseconds(10)))
        try #require(await events.wait { events in
            events.contains(where: \.isScheduledExecutionStarted)
        } != nil)

        let immediateRequest = Task { await executor.runNow() }
        try #require(await events.wait { events in
            events.contains(where: \.isRequested)
        } != nil)
        #expect(invocations.value() == 1)
        scheduledExecutionGate.open()

        let immediateResult = await immediateRequest.value
        await stopRun(run)

        let snapshot = events.snapshot()
        let scheduledCancelledIndex = snapshot.firstIndex(where: \.isScheduledExecutionCancelled)
        let immediateStartedIndex = snapshot.firstIndex(where: \.isImmediateExecutionStarted)
        let immediateFinishedIndex = snapshot.firstIndex(where: \.isImmediateExecutionFinished)
        #expect(invocations.value() == 2)
        if let scheduledCancelledIndex, let immediateStartedIndex, let immediateFinishedIndex {
            #expect(scheduledCancelledIndex < immediateStartedIndex)
            #expect(immediateStartedIndex < immediateFinishedIndex)
        } else {
            Issue.record("Expected the scheduled execution to be cancelled before the immediate execution ran.")
        }
        #expect(immediateResult.startedRequestID == snapshot.compactMap(\.requestedID).first)
        #expect(immediateResult.isFinished)
    }

    @Test func scheduledWait_resumesAfterRunNow() async throws {
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

        await executor.runNow()

        let snapshot = try #require(await events.wait { events in
            events.filter(\.isWaitStarted).count >= 2
        })
        await stopRun(run)

        let cancelledIndex = snapshot.firstIndex(where: \.isWaitCancelled)
        let finishedIndex = snapshot.firstIndex(where: \.isImmediateExecutionFinished)
        let secondWaitIndex = snapshot.indices.filter { snapshot[$0].isWaitStarted }.dropFirst().first
        if let cancelledIndex, let finishedIndex, let secondWaitIndex {
            #expect(cancelledIndex < finishedIndex)
            #expect(finishedIndex < secondWaitIndex)
        } else {
            Issue.record("Expected the wait to be cancelled, the execution to finish, and a new wait to start.")
        }
    }

    @Test func scheduledWait_resumesAfterImmediateExecutionFails() async throws {
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

        await executor.updatePolicy(.interval(.seconds(60)))
        try #require(await events.wait { events in
            events.contains(where: \.isWaitStarted)
        } != nil)
        let result = await executor.runNow()
        let snapshot = await events.wait { events in
            events.filter(\.isWaitStarted).count >= 2
        }
        await stopRun(run)

        guard case let .failed(context, error) = result else {
            Issue.record("Expected the immediate execution to fail.")
            return
        }
        if case .runNow = context.source {} else {
            Issue.record("Expected the failed execution to come from runNow.")
        }
        #expect(error is StubError)
        #expect(snapshot != nil)
    }
}
