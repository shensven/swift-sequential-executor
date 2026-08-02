// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

// MARK: Public Types

/// Runs one execution at a time.
///
/// A scheduled loop waits for the configured interval, executes once, waits again,
/// and never overlaps with another execution.
///
/// `runNow()` has higher priority than the scheduled loop. It stops the current
/// loop, cancels any in-flight execution, runs a new immediate execution, and then
/// lets the loop resume from a clean state.
///
/// The public surface is intentionally small:
/// - `execute` defines the unit of work.
/// - `eventHandler` observes lifecycle events in emission order.
/// - `updatePolicy(_:)` controls the scheduled loop.
/// - `runNow()` requests a higher-priority immediate execution.
public actor SequentialExecutor {
    /// Reports the executor's observable lifecycle.
    ///
    /// The events are grouped into:
    /// - immediate requests
    /// - execution lifecycle
    /// - policy changes
    /// - loop lifecycle
    /// - loop waiting
    public struct Event: Sendable {
        public enum Kind: Sendable {
            /// Reports that a caller requested an immediate execution.
            case requested(requestID: UInt)
            /// Reports that a single execution started.
            ///
            /// The executor emits this immediately before awaiting `execute(context)`
            /// for the matching `executionID`.
            case executionStarted(executionID: UUID, source: ExecutionSource)
            /// Reports that a single execution finished successfully.
            case executionFinished(executionID: UUID, source: ExecutionSource)
            /// Reports that a single execution was cancelled.
            case executionCancelled(executionID: UUID, source: ExecutionSource)
            /// Reports that a single execution failed with an error.
            case executionFailed(executionID: UUID, source: ExecutionSource, error: any Error & Sendable)

            /// Reports that the loop policy changed.
            case policyUpdated(previous: Policy, new: Policy)

            /// Reports that a new scheduled loop started.
            case loopStarted(loopID: UUID)
            /// Reports that the current scheduled loop was asked to stop.
            case loopStopped(loopID: UUID, reason: LoopStopReason)
            /// Reports that the scheduled loop fully exited.
            case loopExited(loopID: UUID)

            /// Reports that the loop started waiting for the next interval.
            case waitStarted(loopID: UUID, interval: Duration)
            /// Reports that the current loop wait was cancelled.
            case waitCancelled(loopID: UUID)
            /// Reports that the current loop wait failed with an error.
            case waitFailed(loopID: UUID, error: any Error & Sendable)
            /// Reports that the configured interval elapsed.
            case intervalElapsed(loopID: UUID)
        }

        /// The time when the executor emitted this event on its coordination path.
        public let emittedAt: Date
        /// The lifecycle payload emitted at `emittedAt`.
        public let kind: Kind

        public init(emittedAt: Date = .now, kind: Kind) {
            self.emittedAt = emittedAt
            self.kind = kind
        }
    }

    /// Observes lifecycle events synchronously on the executor's coordination path.
    ///
    /// Handlers must be safe to transfer across isolation domains. Keep handlers
    /// lightweight and use ``events()`` for actor-isolated or asynchronous work.
    public typealias EventHandler = @Sendable (Event) -> Void

    /// Describes what triggered an execution.
    public enum ExecutionSource: Sendable, Equatable {
        /// Identifies an explicit `runNow()` request.
        case runNow(requestID: UInt)
        /// Identifies a scheduled loop tick.
        case scheduledLoop(loopID: UUID)
    }

    /// Describes the execution currently being run.
    public struct ExecutionContext: Sendable, Equatable {
        /// Identifies this specific execution.
        ///
        /// The same identifier appears in the matching execution lifecycle events.
        public let executionID: UUID
        /// Describes what triggered this execution.
        ///
        /// The same source appears in the matching execution lifecycle events.
        public let source: ExecutionSource

        public init(executionID: UUID, source: ExecutionSource) {
            self.executionID = executionID
            self.source = source
        }
    }

    /// Reports how an immediate execution request completed.
    public enum RunNowResult: Sendable {
        /// The requested execution finished successfully.
        case finished(ExecutionContext)
        /// The requested execution started, then was cancelled.
        case cancelled(ExecutionContext)
        /// The requested execution failed with an error.
        case failed(ExecutionContext, any Error & Sendable)
        /// A newer immediate request replaced this request before it started.
        case superseded(requestID: UInt, byRequestID: UInt)
    }

    /// Explains why a scheduled loop stopped.
    public enum LoopStopReason: Sendable, Equatable {
        /// Indicates that an immediate execution request stopped the loop.
        case runNowRequested
        /// Indicates that the loop policy disabled the loop.
        case policyDisabled
        /// Indicates that the loop policy changed and the loop must restart.
        case policyUpdated
    }

    /// Controls whether the scheduled loop should run and how long it waits.
    public struct Policy: Sendable, Equatable {
        /// Describes whether the loop is disabled or running with an interval.
        public enum RunLoop: Sendable, Equatable {
            case disabled
            case interval(Duration)
        }

        public private(set) var runLoop: RunLoop = .disabled

        /// Creates a loop policy.
        ///
        /// - Parameter runLoop: The desired loop mode.
        public init(runLoop: RunLoop = .disabled) {
            switch runLoop {
            case .disabled:
                self.runLoop = .disabled
            case let .interval(interval):
                precondition(interval > .zero, "SequentialExecutor.Policy.runLoop interval must be greater than zero.")
                self.runLoop = .interval(interval)
            }
        }

        fileprivate var interval: Duration? {
            if case let .interval(interval) = runLoop {
                return interval
            }
            return nil
        }
    }

    /// Controls how event subscribers buffer lifecycle events.
    public enum EventBufferingPolicy: Sendable, Equatable {
        /// Buffers every event until the consumer receives it.
        case unbounded
        /// Buffers the oldest `limit` events and drops new events while the buffer is full.
        case bufferingOldest(Int)
        /// Buffers the newest `limit` events and drops the oldest buffered event first.
        case bufferingNewest(Int)
    }

    // MARK: Stored Properties

    private let execute: @Sendable (ExecutionContext) async throws -> Void
    private let eventHandler: EventHandler?
    private let clock = ContinuousClock()
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    private var loopTask: Task<Void, Never>?
    private var loopTaskID: UUID?
    private var loopPolicy = Policy()

    private var executionTask: Task<ExecutionCompletion, Never>?
    private var executionTaskID: UUID?

    private var latestImmediateExecutionRequestID: UInt = 0
    private var pendingImmediateExecutionCount = 0

    // MARK: Lifecycle

    /// Creates a sequential executor.
    ///
    /// - Parameters:
    ///   - execute: The single unit of work to run each time the executor fires.
    ///     The executor passes the current execution context, including the
    ///     execution identifier and the trigger source. The executor emits the
    ///     matching `executionStarted` event immediately before awaiting this closure.
    ///     This closure is expected to cooperate with Swift Concurrency cancellation.
    ///     When `runNow()` needs to replace an in-flight execution, it cancels the
    ///     current task and then waits for this closure to return. If the closure does
    ///     not observe cancellation, the replacement execution cannot start promptly.
    ///   - eventHandler: An optional observer for lifecycle events.
    ///     The executor invokes this `@Sendable` callback synchronously on its
    ///     coordination path in the same order the events are emitted. The handler
    ///     cannot synchronously access state isolated elsewhere, such as MainActor UI
    ///     state. Keep it lightweight and use ``events()`` for isolated or asynchronous
    ///     event processing.
    public init(
        execute: @escaping @Sendable (ExecutionContext) async throws -> Void,
        eventHandler: EventHandler? = nil
    ) {
        self.execute = execute
        self.eventHandler = eventHandler
    }

    /// Convenience overload for work that does not need `ExecutionContext`.
    public init(
        execute: @escaping @Sendable () async throws -> Void,
        eventHandler: EventHandler? = nil
    ) {
        self.init(
            execute: { _ in
                try await execute()
            },
            eventHandler: eventHandler
        )
    }

    deinit {
        loopTask?.cancel()
        executionTask?.cancel()
        eventContinuations.values.forEach { $0.finish() }
    }
}

// MARK: Public API

public extension SequentialExecutor {
    /// Applies a new loop policy.
    ///
    /// Updating the policy may start, stop, or restart the scheduled loop.
    func updatePolicy(_ policy: Policy) {
        reconcile(with: policy)
    }

    /// Requests a new immediate execution.
    ///
    /// Immediate execution has priority over the scheduled loop. If a loop is active,
    /// it is stopped first. If another execution is already running, it is cancelled
    /// and replaced by the new one. If multiple callers race to invoke `runNow()`,
    /// only the latest pending request is guaranteed to proceed after cancellation
    /// coordination completes. Cancellation remains cooperative: this method requests
    /// cancellation of the in-flight execution and waits for it to return; it does not
    /// forcibly terminate non-cooperative work.
    ///
    /// This method returns after the selected immediate execution exits, or as soon as
    /// a newer request supersedes it before execution starts. Errors thrown by `execute`
    /// are returned as ``RunNowResult/failed(_:_:)`` and are also reported through
    /// ``Event/Kind/executionFailed(executionID:source:error:)``.
    @discardableResult
    func runNow() async -> RunNowResult {
        await runImmediately()
    }

    /// Returns an async sequence view of the executor lifecycle events.
    ///
    /// The stream observes the same `Event` values emitted to `eventHandler`, using
    /// an unbounded buffer.
    func events() -> AsyncStream<Event> {
        events(bufferingPolicy: .unbounded)
    }

    /// Returns an async sequence view of the executor lifecycle events.
    ///
    /// The stream observes the same `Event` values emitted to `eventHandler`, but
    /// delivers them asynchronously according to the provided buffering policy.
    func events(bufferingPolicy: EventBufferingPolicy) -> AsyncStream<Event> {
        let subscriberID = UUID()
        var continuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: bufferingPolicy.asyncStreamPolicy) {
            continuation = $0
        }

        guard let continuation else {
            preconditionFailure("AsyncStream failed to provide a continuation.")
        }

        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeEventContinuation(subscriberID)
            }
        }
        eventContinuations[subscriberID] = continuation
        return stream
    }
}

private extension SequentialExecutor.EventBufferingPolicy {
    var asyncStreamPolicy: AsyncStream<SequentialExecutor.Event>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded: return .unbounded
        case let .bufferingOldest(limit): return .bufferingOldest(limit)
        case let .bufferingNewest(limit): return .bufferingNewest(limit)
        }
    }
}

// MARK: Scheduled Loop Coordination

private extension SequentialExecutor {
    func reconcile(with policy: Policy) {
        let previousPolicy = loopPolicy
        let shouldRestartScheduledExecutionLoop = loopTask != nil
            && previousPolicy.interval != nil
            && policy.interval != nil
            && previousPolicy.interval != policy.interval
        loopPolicy = policy
        if previousPolicy != policy {
            emit(.policyUpdated(previous: previousPolicy, new: policy))
        }
        if shouldRestartScheduledExecutionLoop {
            stopScheduledExecutionLoop(reason: .policyUpdated)
        }
        reconcileLoopTask()
    }

    func stopScheduledExecutionLoop(reason: LoopStopReason) {
        guard loopTask != nil, let loopID = loopTaskID else { return }
        emit(.loopStopped(loopID: loopID, reason: reason))
        loopTask?.cancel()
        loopTask = nil
        loopTaskID = nil
    }

    func reconcileLoopTask() {
        guard loopPolicy.interval != nil else {
            stopScheduledExecutionLoop(reason: .policyDisabled)
            return
        }

        guard pendingImmediateExecutionCount == 0 else {
            stopScheduledExecutionLoop(reason: .runNowRequested)
            return
        }

        guard executionTask == nil else { return }
        guard loopTask == nil else { return }

        let loopID = UUID.sequentialExecutorV7()
        let clock = self.clock
        loopTaskID = loopID
        emit(.loopStarted(loopID: loopID))
        loopTask = Task.detached { [weak self, clock] in
            // Waiting happens outside actor isolation so a sleeping loop does not keep
            // the executor alive. Each execution still runs in its own replaceable task.
            while let interval = await self?.beginScheduledWait(loopID: loopID) {
                let waitOutcome: ScheduledWaitOutcome
                do {
                    try await clock.sleep(for: interval)
                    try Task.checkCancellation()
                    waitOutcome = .elapsed
                } catch is CancellationError {
                    waitOutcome = .cancelled
                } catch {
                    waitOutcome = .failed(error)
                }

                guard await self?.completeScheduledWait(loopID: loopID, outcome: waitOutcome) == true else { break }
                guard !Task.isCancelled else { break }
                guard let executionTask = await self?.startScheduledExecution(loopID: loopID) else { break }
                _ = await executionTask.value
                guard !Task.isCancelled else { break }
            }
            await self?.loopDidExit(loopID: loopID)
        }
    }

    enum ScheduledWaitOutcome: Sendable {
        case elapsed
        case cancelled
        case failed(any Error & Sendable)
    }

    func beginScheduledWait(loopID: UUID) -> Duration? {
        guard loopTaskID == loopID, let interval = loopPolicy.interval else { return nil }
        emit(.waitStarted(loopID: loopID, interval: interval))
        return interval
    }

    func completeScheduledWait(loopID: UUID, outcome: ScheduledWaitOutcome) -> Bool {
        switch outcome {
        case .cancelled:
            emit(.waitCancelled(loopID: loopID))
            return false
        case let .failed(error):
            emit(.waitFailed(loopID: loopID, error: error))
            return false
        case .elapsed:
            guard loopTaskID == loopID else {
                emit(.waitCancelled(loopID: loopID))
                return false
            }
            emit(.intervalElapsed(loopID: loopID))
            return true
        }
    }

    func startScheduledExecution(loopID: UUID) -> Task<ExecutionCompletion, Never>? {
        guard loopTaskID == loopID else { return nil }
        guard loopPolicy.interval != nil else { return nil }
        guard pendingImmediateExecutionCount == 0 else { return nil }
        guard executionTask == nil else { return nil }
        return startExecution(source: .scheduledLoop(loopID: loopID))
    }

    func loopDidExit(loopID: UUID) {
        emit(.loopExited(loopID: loopID))
        clearLoopTaskIfCurrent(loopID)
    }

    func clearLoopTaskIfCurrent(_ taskId: UUID) {
        guard loopTaskID == taskId else { return }
        loopTask = nil
        loopTaskID = nil
        reconcileLoopTask()
    }
}

// MARK: Immediate Request Coordination

private extension SequentialExecutor {
    func runImmediately() async -> RunNowResult {
        latestImmediateExecutionRequestID &+= 1
        let requestID = latestImmediateExecutionRequestID
        emit(.requested(requestID: requestID))
        pendingImmediateExecutionCount += 1

        // Latest request wins. Stop the loop, cancel the current execution if needed,
        // and replace it with a new immediate execution.
        stopScheduledExecutionLoop(reason: .runNowRequested)
        await cancelCurrentExecutionAndWait()

        // After resuming from the suspension point, a newer runNow() request
        // may have already been queued. Only the latest request should proceed;
        // older requests yield to avoid parallel executions.
        guard latestImmediateExecutionRequestID == requestID else {
            pendingImmediateExecutionCount -= 1
            return .superseded(requestID: requestID, byRequestID: latestImmediateExecutionRequestID)
        }

        let task = startExecution(source: .runNow(requestID: requestID))
        let completion = await task.value

        pendingImmediateExecutionCount -= 1
        if latestImmediateExecutionRequestID == requestID {
            reconcileLoopTask()
        }
        return RunNowResult(completion)
    }

    func cancelCurrentExecutionAndWait() async {
        guard let executionTask else { return }
        executionTask.cancel()
        _ = await executionTask.value
    }
}

// MARK: Execution Lifecycle

private extension SequentialExecutor {
    enum ExecutionOutcome: Sendable {
        case finished
        case cancelled
        case failed(any Error & Sendable)
    }

    struct ExecutionCompletion: Sendable {
        let context: ExecutionContext
        let outcome: ExecutionOutcome
    }

    func startExecution(source: ExecutionSource) -> Task<ExecutionCompletion, Never> {
        let execute = self.execute
        let executionID = UUID.sequentialExecutorV7()
        let context = ExecutionContext(executionID: executionID, source: source)
        let task = Task { [weak self, execute] in
            await self?.emit(.executionStarted(executionID: executionID, source: source))

            let outcome: ExecutionOutcome
            do {
                try Task.checkCancellation()
                try await execute(context)
                try Task.checkCancellation()
                outcome = .finished
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed(error)
            }

            await self?.finishExecution(executionID: executionID, source: source, outcome: outcome)
            return ExecutionCompletion(context: context, outcome: outcome)
        }
        executionTask = task
        executionTaskID = executionID
        return task
    }

    func finishExecution(executionID: UUID, source: ExecutionSource, outcome: ExecutionOutcome) {
        switch outcome {
        case .finished: emit(.executionFinished(executionID: executionID, source: source))
        case .cancelled: emit(.executionCancelled(executionID: executionID, source: source))
        case let .failed(error): emit(.executionFailed(executionID: executionID, source: source, error: error))
        }

        guard executionTaskID == executionID else { return }
        executionTask = nil
        executionTaskID = nil

        guard pendingImmediateExecutionCount == 0 else { return }
        reconcileLoopTask()
    }
}

private extension SequentialExecutor.RunNowResult {
    init(_ completion: SequentialExecutor.ExecutionCompletion) {
        switch completion.outcome {
        case .finished:
            self = .finished(completion.context)
        case .cancelled:
            self = .cancelled(completion.context)
        case let .failed(error):
            self = .failed(completion.context, error)
        }
    }
}

// MARK: Event Emission

private extension SequentialExecutor {
    func removeEventContinuation(_ subscriberID: UUID) {
        eventContinuations.removeValue(forKey: subscriberID)
    }

    func emit(_ kind: Event.Kind, emittedAt: Date = .now) {
        let event = Event(emittedAt: emittedAt, kind: kind)
        eventHandler?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}

// MARK: Utilities

private extension UUID {
    /// Generates a UUIDv7-style identifier for executor loop and execution IDs.
    ///
    /// The executor uses time-ordered IDs so loop and execution logs are easier to
    /// read in chronological order.
    static func sequentialExecutorV7() -> UUID {
        var random = SystemRandomNumberGenerator()
        let timestamp = unixMilliseconds()
        let randA = UInt16.random(in: 0 ... 0x0FFF, using: &random)
        let randB = UInt64.random(in: 0 ... 0x3FFF_FFFF_FFFF_FFFF, using: &random)

        let uuid: uuid_t = (
            UInt8((timestamp >> 40) & 0xFF),
            UInt8((timestamp >> 32) & 0xFF),
            UInt8((timestamp >> 24) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8(timestamp & 0xFF),
            UInt8(0x70 | UInt8((randA >> 8) & 0x0F)),
            UInt8(randA & 0xFF),
            UInt8(0x80 | UInt8((randB >> 56) & 0x3F)),
            UInt8((randB >> 48) & 0xFF),
            UInt8((randB >> 40) & 0xFF),
            UInt8((randB >> 32) & 0xFF),
            UInt8((randB >> 24) & 0xFF),
            UInt8((randB >> 16) & 0xFF),
            UInt8((randB >> 8) & 0xFF),
            UInt8(randB & 0xFF)
        )
        return UUID(uuid: uuid)
    }

    /// Returns the current Unix timestamp in milliseconds.
    private static func unixMilliseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
