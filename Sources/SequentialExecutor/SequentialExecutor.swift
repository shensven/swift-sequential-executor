// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

// MARK: Public Types

/// Runs one execution at a time.
///
/// Scheduled work uses fixed-delay semantics: the loop waits for the configured
/// interval, executes once, and starts the next wait only after that execution exits.
/// Enabling scheduling does not execute immediately, and executions never overlap.
///
/// `runNow()` takes precedence over the scheduled loop. It stops the current
/// loop, requests cancellation of any in-flight execution, and coordinates a new
/// immediate execution. When requests race, the newest pending request takes over.
/// The scheduled loop resumes afterward when its policy remains enabled.
///
/// The public surface is intentionally small:
/// - `execute` defines the unit of work.
/// - `eventHandler` observes lifecycle events in emission order.
/// - `updatePolicy(_:)` controls the scheduled loop.
/// - `runNow()` requests an immediate execution that takes precedence over scheduling.
public actor SequentialExecutor {
    /// Reports the executor's observable lifecycle.
    ///
    /// Request, loop, and execution identifiers are issued from one monotonically
    /// increasing counter per executor, so within one executor no two of them share
    /// a number and a larger identifier was always issued later.
    ///
    /// The events are grouped into:
    /// - immediate requests
    /// - execution lifecycle
    /// - policy changes
    /// - loop lifecycle
    /// - loop waiting
    public struct Event: Sendable {
        /// Identifies a lifecycle transition.
        public enum Kind: Sendable {
            /// Reports that a caller requested an immediate execution.
            case requested(requestID: UInt)
            /// Reports that a single execution started.
            ///
            /// The executor emits this synchronously when it selects the execution,
            /// before awaiting `execute(context)` for the matching `executionID`. It is
            /// always ordered before that execution's finished, cancelled, or failed event.
            case executionStarted(executionID: UInt, source: ExecutionSource)
            /// Reports that a single execution finished successfully.
            case executionFinished(executionID: UInt, source: ExecutionSource)
            /// Reports that a single execution was cancelled.
            case executionCancelled(executionID: UInt, source: ExecutionSource)
            /// Reports that a single execution failed with an error.
            case executionFailed(executionID: UInt, source: ExecutionSource, error: any Error & Sendable)

            /// Reports that the loop policy changed.
            case policyUpdated(previous: Policy, new: Policy)

            /// Reports that a new scheduled loop started.
            ///
            /// For a given `loopID`, this event is emitted before any waiting,
            /// stopping, or exit event.
            case loopStarted(loopID: UInt)
            /// Reports that the current scheduled loop was asked to stop.
            case loopStopped(loopID: UInt, reason: LoopStopReason)
            /// Reports that the scheduled loop fully exited.
            ///
            /// Events from different loop identifiers may interleave. In particular,
            /// an old loop can exit after its replacement has already started.
            case loopExited(loopID: UInt)

            /// Reports that the loop started waiting for the next interval.
            case waitStarted(loopID: UInt, interval: Duration)
            /// Reports that the current loop wait was cancelled.
            case waitCancelled(loopID: UInt)
            /// Reports that the configured interval elapsed.
            case intervalElapsed(loopID: UInt)
        }

        /// The time when the executor emitted this event on its coordination path.
        public let emittedAt: Date
        /// The lifecycle payload emitted at `emittedAt`.
        public let kind: Kind

        /// Creates a lifecycle event.
        ///
        /// - Parameters:
        ///   - emittedAt: The event's emission time.
        ///   - kind: The lifecycle transition represented by the event.
        public init(emittedAt: Date = .now, kind: Kind) {
            self.emittedAt = emittedAt
            self.kind = kind
        }
    }

    /// Observes lifecycle events synchronously on the executor's coordination path.
    ///
    /// Handlers must be safe to transfer across isolation domains. Keep handlers
    /// lightweight and use ``events(bufferingPolicy:)`` for actor-isolated or asynchronous work.
    public typealias EventHandler = @Sendable (Event) -> Void

    /// Describes what triggered an execution.
    public enum ExecutionSource: Sendable, Equatable {
        /// Identifies an explicit `runNow()` request.
        case runNow(requestID: UInt)
        /// Identifies a scheduled loop tick.
        case scheduledLoop(loopID: UInt)
    }

    /// Describes the execution currently being run.
    public struct ExecutionContext: Sendable, Equatable {
        /// Identifies this specific execution.
        ///
        /// The same identifier appears in the matching execution lifecycle events.
        public let executionID: UInt
        /// Describes what triggered this execution.
        ///
        /// The same source appears in the matching execution lifecycle events.
        public let source: ExecutionSource

        /// Creates an execution context.
        ///
        /// - Parameters:
        ///   - executionID: The identifier for this execution.
        ///   - source: The trigger that started this execution.
        public init(executionID: UInt, source: ExecutionSource) {
            self.executionID = executionID
            self.source = source
        }
    }

    /// Reports how an immediate execution request completed.
    ///
    /// A request that has already started ends as `finished`, `cancelled`, or
    /// `failed`. Only a request replaced before it starts ends as `superseded`.
    public enum RunNowResult: Sendable {
        /// The requested execution finished successfully.
        case finished(ExecutionContext)
        /// The requested execution started, then ended through cancellation.
        ///
        /// This includes cooperative task cancellation and a `CancellationError`
        /// thrown by the execution closure.
        case cancelled(ExecutionContext)
        /// The requested execution started, then failed with a non-cancellation error.
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
    public enum Policy: Sendable, Equatable {
        /// Disables future scheduled executions.
        case disabled
        /// Waits for the duration before each scheduled execution.
        ///
        /// The duration must be greater than zero; ``SequentialExecutor/updatePolicy(_:)``
        /// traps otherwise. The first execution waits for one full duration, and each
        /// later wait starts after the prior execution exits. This is fixed-delay
        /// scheduling rather than fixed-rate scheduling.
        case interval(Duration)

        fileprivate var interval: Duration? {
            if case let .interval(interval) = self {
                return interval
            }
            return nil
        }
    }

    // MARK: Stored Properties

    private let execute: @Sendable (ExecutionContext) async throws -> Void
    private let eventHandler: EventHandler?
    private let clock = ContinuousClock()
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    private var activeLoop: ActiveLoop?
    private var loopPolicy = Policy.disabled

    private var activeExecution: ActiveExecution?

    private var lastIssuedID: UInt = 0
    private var latestImmediateExecutionRequestID: UInt = 0
    private var pendingImmediateExecutionCount = 0

    // MARK: Lifecycle

    /// Creates a sequential executor.
    ///
    /// - Parameters:
    ///   - execute: The single unit of work to run each time the executor fires.
    ///     The executor passes the current execution context, including the
    ///     execution identifier and the trigger source. The executor emits the
    ///     matching `executionStarted` event synchronously before awaiting this closure.
    ///     This closure is expected to cooperate with Swift Concurrency cancellation.
    ///     When `runNow()` needs to replace an in-flight execution, it cancels the
    ///     current task and then waits for this closure to return. If the closure does
    ///     not observe cancellation, the replacement execution cannot start promptly.
    ///   - eventHandler: An optional observer for lifecycle events.
    ///     The executor invokes this `@Sendable` callback synchronously on its
    ///     coordination path in the same order the events are emitted. The handler
    ///     cannot synchronously access state isolated elsewhere, such as MainActor UI
    ///     state. Keep it lightweight and use ``events(bufferingPolicy:)`` for isolated or asynchronous
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
        activeLoop?.task.cancel()
        activeExecution?.task.cancel()
        eventContinuations.values.forEach { $0.finish() }
    }
}

// MARK: Active Work

private extension SequentialExecutor {
    /// The scheduled loop that currently owns waiting and scheduled executions.
    ///
    /// Pairing the identifier with its task guarantees that a tracked loop always
    /// has an identifier, and that clearing one clears the other.
    struct ActiveLoop {
        let id: UInt
        let task: Task<Void, Never>
    }

    /// The execution that is currently running, regardless of its trigger.
    struct ActiveExecution {
        let id: UInt
        let task: Task<ExecutionCompletion, Never>
    }
}

// MARK: Public API

public extension SequentialExecutor {
    /// Applies a new loop policy.
    ///
    /// Updating the policy may start, stop, or restart the scheduled loop. Disabling
    /// or changing the policy cancels an active interval wait, but does not cancel an
    /// execution that has already started. That execution is allowed to exit before
    /// the executor applies the next scheduled wait.
    ///
    /// - Precondition: An `interval` policy must carry a duration greater than zero.
    func updatePolicy(_ policy: Policy) {
        if case let .interval(interval) = policy {
            precondition(interval > .zero, "SequentialExecutor.Policy.interval must be greater than zero.")
        }
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
    ///
    /// - Important: Cancelling the caller's task does not withdraw the request or
    ///   cancel the executor's work. A newer `runNow()` request asks the current
    ///   execution to cancel.
    @discardableResult
    func runNow() async -> RunNowResult {
        await runImmediately()
    }

    /// Returns an async sequence view of the executor lifecycle events.
    ///
    /// The stream observes future `Event` values emitted after this subscription is
    /// created; it does not replay earlier events. The default policy buffers every
    /// event, so a subscriber that cannot keep up retains an increasing number of
    /// events. Bounded policies may drop events without emitting an additional
    /// notification.
    func events(
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Event> {
        let subscriberID = UUID()
        var continuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: bufferingPolicy) {
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

// MARK: Scheduled Loop Coordination

private extension SequentialExecutor {
    func reconcile(with policy: Policy) {
        let previousPolicy = loopPolicy
        let shouldRestartScheduledExecutionLoop = activeLoop != nil
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
        guard let activeLoop else { return }
        emit(.loopStopped(loopID: activeLoop.id, reason: reason))
        activeLoop.task.cancel()
        self.activeLoop = nil
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

        guard activeExecution == nil else { return }
        guard activeLoop == nil else { return }

        let loopID = nextID()
        let clock = self.clock
        emit(.loopStarted(loopID: loopID))
        // The detached task first hops back onto the actor, so it cannot observe
        // `activeLoop` before this synchronous assignment completes.
        let task = Task<Void, Never>.detached { [weak self, clock] in
            // Waiting happens outside actor isolation so a sleeping loop does not keep
            // the executor alive. Each execution still runs in its own replaceable task.
            while let interval = await self?.beginScheduledWait(loopID: loopID) {
                let waitOutcome: ScheduledWaitOutcome
                do {
                    try await clock.sleep(for: interval)
                    try Task.checkCancellation()
                    waitOutcome = .elapsed
                } catch {
                    // ContinuousClock.sleep is documented to throw only CancellationError,
                    // so any error here means the wait was cancelled.
                    waitOutcome = .cancelled
                }

                guard await self?.completeScheduledWait(loopID: loopID, outcome: waitOutcome) == true else { break }
                guard !Task.isCancelled else { break }
                guard let executionTask = await self?.startScheduledExecution(loopID: loopID) else { break }
                _ = await executionTask.value
                guard !Task.isCancelled else { break }
            }
            await self?.loopDidExit(loopID: loopID)
        }
        activeLoop = ActiveLoop(id: loopID, task: task)
    }

    enum ScheduledWaitOutcome: Sendable {
        case elapsed
        case cancelled
    }

    func beginScheduledWait(loopID: UInt) -> Duration? {
        guard activeLoop?.id == loopID, let interval = loopPolicy.interval else { return nil }
        emit(.waitStarted(loopID: loopID, interval: interval))
        return interval
    }

    func completeScheduledWait(loopID: UInt, outcome: ScheduledWaitOutcome) -> Bool {
        switch outcome {
        case .cancelled:
            emit(.waitCancelled(loopID: loopID))
            return false
        case .elapsed:
            guard activeLoop?.id == loopID else {
                emit(.waitCancelled(loopID: loopID))
                return false
            }
            emit(.intervalElapsed(loopID: loopID))
            return true
        }
    }

    func startScheduledExecution(loopID: UInt) -> Task<ExecutionCompletion, Never>? {
        guard activeLoop?.id == loopID else { return nil }
        guard loopPolicy.interval != nil else { return nil }
        guard pendingImmediateExecutionCount == 0 else { return nil }
        guard activeExecution == nil else { return nil }
        return startExecution(source: .scheduledLoop(loopID: loopID))
    }

    func loopDidExit(loopID: UInt) {
        emit(.loopExited(loopID: loopID))
        guard activeLoop?.id == loopID else { return }
        activeLoop = nil
        reconcileLoopTask()
    }
}

// MARK: Immediate Request Coordination

private extension SequentialExecutor {
    func runImmediately() async -> RunNowResult {
        let requestID = nextID()
        latestImmediateExecutionRequestID = requestID
        emit(.requested(requestID: requestID))
        pendingImmediateExecutionCount += 1
        // Every accepted request contributes exactly once to the handoff count.
        // Reconcile from one shared exit path because actor continuations waiting on
        // different executions may resume in any order.
        defer {
            precondition(pendingImmediateExecutionCount > 0)
            pendingImmediateExecutionCount -= 1
            reconcileLoopTask()
        }

        // Latest request wins. Stop the loop, cancel the current execution if needed,
        // and replace it with a new immediate execution.
        stopScheduledExecutionLoop(reason: .runNowRequested)
        await cancelCurrentExecutionAndWait()

        // After resuming from the suspension point, a newer runNow() request
        // may have already been queued. Only the latest request should proceed;
        // older requests yield to avoid parallel executions.
        guard latestImmediateExecutionRequestID == requestID else {
            return .superseded(requestID: requestID, byRequestID: latestImmediateExecutionRequestID)
        }

        let task = startExecution(source: .runNow(requestID: requestID))
        let completion = await task.value

        return RunNowResult(completion)
    }

    func cancelCurrentExecutionAndWait() async {
        guard let activeExecution else { return }
        activeExecution.task.cancel()
        _ = await activeExecution.task.value
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
        let executionID = nextID()
        let context = ExecutionContext(executionID: executionID, source: source)
        // Emit synchronously so `executionStarted` is ordered before any event the
        // actor processes next. The task body only emits the execution's outcome.
        emit(.executionStarted(executionID: executionID, source: source))
        let task = Task { [weak self, execute] in
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
        activeExecution = ActiveExecution(id: executionID, task: task)
        return task
    }

    func finishExecution(executionID: UInt, source: ExecutionSource, outcome: ExecutionOutcome) {
        switch outcome {
        case .finished: emit(.executionFinished(executionID: executionID, source: source))
        case .cancelled: emit(.executionCancelled(executionID: executionID, source: source))
        case let .failed(error): emit(.executionFailed(executionID: executionID, source: source, error: error))
        }

        guard activeExecution?.id == executionID else { return }
        activeExecution = nil

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

// MARK: Identifiers

private extension SequentialExecutor {
    /// Issues the next identifier shared by requests, loops, and executions.
    func nextID() -> UInt {
        lastIssuedID &+= 1
        return lastIssuedID
    }
}
