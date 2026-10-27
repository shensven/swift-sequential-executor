import Foundation
import Testing
@testable import SequentialExecutor

@Suite struct EventStreamTests {
    // MARK: Event Streams

    @Test func eventsStream_receivesImmediateExecutionLifecycleEvents() async throws {
        let handlerEvents = EventRecorder()
        let streamedEvents = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                handlerEvents.record(event)
            }
        )
        let collector = recordEvents(from: await executor.events(), into: streamedEvents)
        let run = try await startRun(executor, events: handlerEvents)

        await executor.runNow()

        let snapshot = try #require(await streamedEvents.wait { events in
            events.contains(where: \.isImmediateExecutionFinished)
        })
        let signatures = snapshot.compactMap(\.executionSignature)
        #expect(signatures.count == 3)
        #expect(signatures.first.map { if case .requested = $0 { true } else { false } } == true)
        collector.cancel()
        await stopRun(run)
    }

    @Test func eventsStream_receivesSameExecutionEventsAsEventHandler() async throws {
        let handlerEvents = EventRecorder()
        let streamedEvents = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                handlerEvents.record(event)
            }
        )
        let collector = recordEvents(from: await executor.events(), into: streamedEvents)
        let run = try await startRun(executor, events: handlerEvents)

        await executor.runNow()

        let streamed = try #require(await streamedEvents.wait { events in
            events.contains(where: \.isImmediateExecutionFinished)
        })
        let handled = handlerEvents.snapshot()
        #expect(streamed.compactMap(\.executionSignature) == handled.compactMap(\.executionSignature))
        collector.cancel()
        await stopRun(run)
    }

    @Test func eventsStream_doesNotReplayEventsEmittedBeforeSubscription() async throws {
        let handlerEvents = EventRecorder()
        let streamedEvents = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                handlerEvents.record(event)
            }
        )
        let run = try await startRun(executor, events: handlerEvents)

        await executor.runNow()

        let collector = recordEvents(from: await executor.events(), into: streamedEvents)
        let secondResult = await executor.runNow()

        let snapshot = try #require(await streamedEvents.wait { events in
            events.contains(where: \.isImmediateExecutionFinished)
        })
        collector.cancel()

        #expect(snapshot.contains(where: \.isRunStarted) == false)
        #expect(snapshot.compactMap(\.requestedID) == [secondResult.startedRequestID].compactMap { $0 })
        #expect(snapshot.compactMap(\.executionSignature).count == 3)
        await stopRun(run)
    }

    @Test func multipleEventStreams_receiveTheSameExecutionEvents() async throws {
        let handlerEvents = EventRecorder()
        let firstEvents = EventRecorder()
        let secondEvents = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                handlerEvents.record(event)
            }
        )
        let firstCollector = recordEvents(from: await executor.events(), into: firstEvents)
        let secondCollector = recordEvents(from: await executor.events(), into: secondEvents)
        let run = try await startRun(executor, events: handlerEvents)

        await executor.runNow()

        let firstSnapshot = try #require(await firstEvents.wait { events in
            events.contains(where: \.isImmediateExecutionFinished)
        })
        let secondSnapshot = try #require(await secondEvents.wait { events in
            events.contains(where: \.isImmediateExecutionFinished)
        })
        firstCollector.cancel()
        secondCollector.cancel()

        #expect(firstSnapshot.compactMap(\.executionSignature) == secondSnapshot.compactMap(\.executionSignature))
        await stopRun(run)
    }

    enum BoundedBufferingScenario: Sendable {
        case oldest
        case newest

        var policy: AsyncStream<SequentialExecutor.Event>.Continuation.BufferingPolicy {
            switch self {
            case .oldest: return .bufferingOldest(1)
            case .newest: return .bufferingNewest(1)
            }
        }
    }

    @Test(arguments: [BoundedBufferingScenario.oldest, .newest])
    func eventsStream_respectsBoundedBuffering(_ scenario: BoundedBufferingScenario) async throws {
        let handlerEvents = EventRecorder()
        let executor = SequentialExecutor(
            execute: {},
            eventHandler: { event in
                handlerEvents.record(event)
            }
        )
        let run = try await startRun(executor, events: handlerEvents)
        let stream = await executor.events(bufferingPolicy: scenario.policy)

        await executor.runNow()

        var iterator = stream.makeAsyncIterator()
        let bufferedEvent = try #require(await iterator.next())
        switch scenario {
        case .oldest:
            #expect(bufferedEvent.isRequested)
        case .newest:
            #expect(bufferedEvent.isImmediateExecutionFinished)
        }
        await stopRun(run)
    }
}
