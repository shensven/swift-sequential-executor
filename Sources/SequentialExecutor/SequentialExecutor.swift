// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

/// Runs one execution at a time.
///
/// `run()` drives the executor: it waits for the configured interval or for an
/// immediate request, performs one execution, and waits again. Waiting and
/// executing happen in tasks that `run()` owns and always awaits, so cancelling the
/// task that called `run()` cancels them cooperatively and `run()` returns. Nothing
/// outlives it.
///
/// Scheduled work uses fixed-delay semantics: the run waits for the configured
/// interval, executes once, and starts the next wait only after that execution exits.
/// Setting an interval does not execute immediately, and executions never overlap.
///
/// `runNow()` takes precedence over the schedule. It ends the current wait or
/// requests cancellation of the in-flight execution, then runs the newest pending
/// request. The schedule resumes afterward when the policy still has an interval.
///
/// The public surface is intentionally small:
/// - `execute` defines the unit of work.
/// - `run()` drives waiting and executing for as long as its task lives.
/// - `updatePolicy(_:)` pauses the schedule or sets its interval.
/// - `runNow()` requests an immediate execution that takes precedence over the schedule.
/// - `eventHandler` and `events(bufferingPolicy:)` observe lifecycle events.
public actor SequentialExecutor {
    // MARK: Stored Properties

    private let execute: @Sendable (ExecutionContext) async throws -> Void
    private let eventHandler: EventHandler?
    private let clock = ContinuousClock()
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var changeWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    private var policy = Policy.paused
    private var activeRunID: UInt?
    private var activeExecution: Task<ExecutionOutcome, Never>?
    private var pendingRequest: PendingRequest?
    private var lastIssuedID: UInt = 0

    // MARK: Lifecycle

    /// Creates a sequential executor.
    ///
    /// - Parameters:
    ///   - execute: The single unit of work to run each time the executor fires.
    ///     The executor passes the current execution context, including the
    ///     execution identifier and the trigger source. The executor emits the
    ///     matching `executionStarted` event synchronously before awaiting this closure.
    ///     This closure is expected to cooperate with Swift Concurrency cancellation,
    ///     either by throwing `CancellationError` or by returning early; the executor
    ///     reports both as a cancelled execution. When `runNow()` needs to replace an
    ///     in-flight execution, it cancels the execution's task and waits for this
    ///     closure to return. If the closure does not observe cancellation, the
    ///     replacement execution cannot start promptly.
    ///   - eventHandler: An optional observer for lifecycle events.
    ///     The executor invokes this `@Sendable` callback synchronously on its
    ///     coordination path in the same order the events are emitted. The handler
    ///     cannot synchronously access state isolated elsewhere, such as MainActor UI
    ///     state. Keep it lightweight and use ``events(bufferingPolicy:)`` for isolated
    ///     or asynchronous event processing.
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
}

// MARK: Internal Types

private extension SequentialExecutor {
    /// The newest `runNow()` request that has not started yet.
    struct PendingRequest {
        let id: UInt
        let continuation: CheckedContinuation<RunNowResult, Never>
    }

    enum Trigger {
        case elapsed
        case immediate(PendingRequest)
        case cancelled
    }

    enum WaitOutcome: Sendable {
        case elapsed
        case changed
        case cancelled
    }

    enum ExecutionOutcome: Sendable {
        case finished
        case cancelled
        case failed(any Error & Sendable)
    }
}

// MARK: Public API

public extension SequentialExecutor {
    /// Drives the executor until the calling task is cancelled.
    ///
    /// Waiting and executing happen in tasks this call owns and awaits, so cancelling
    /// the caller cancels an active wait or execution cooperatively and this method
    /// returns once that work has exited. Only one run is active at a time: a call
    /// made while another run is active waits for that run to end before starting.
    ///
    /// An immediate request still pending when the run ends completes with
    /// ``RunNowResult/notRunning(requestID:)``.
    func run() async {
        while activeRunID != nil {
            await awaitChange()
            if Task.isCancelled { return }
        }
        if Task.isCancelled { return }

        let runID = nextID()
        activeRunID = runID
        emit(.runStarted(runID: runID))

        await drive()

        activeRunID = nil
        if let pendingRequest = takePendingRequest() {
            pendingRequest.continuation.resume(returning: .notRunning(requestID: pendingRequest.id))
        }
        emit(.runEnded(runID: runID))
        notifyChange()
    }

    /// Applies a new policy.
    ///
    /// The policy only controls waiting. Pausing or changing the interval ends an
    /// active wait and the run re-evaluates immediately; it never cancels an execution
    /// that has already started, and a new interval applies after that execution exits.
    /// Applying the current policy again does nothing.
    ///
    /// - Precondition: An `interval` policy must carry a duration greater than zero.
    func updatePolicy(_ policy: Policy) {
        if case let .interval(interval) = policy {
            precondition(interval > .zero, "SequentialExecutor.Policy.interval must be greater than zero.")
        }
        guard policy != self.policy else { return }
        let previous = self.policy
        self.policy = policy
        emit(.policyUpdated(previous: previous, new: policy))
        notifyChange()
    }

    /// Requests a new immediate execution.
    ///
    /// Immediate execution has priority over the schedule. An active wait ends, an
    /// interval that elapses at the same moment is taken by the request, and an
    /// in-flight execution is cancelled before this method emits `requested`; the
    /// request starts once that execution has exited. If several requests arrive before
    /// one starts, the newest one runs and the others complete as
    /// ``RunNowResult/superseded(requestID:byRequestID:)``.
    /// Cancellation remains cooperative: the executor does not forcibly terminate
    /// non-cooperative work.
    ///
    /// This method returns after the requested execution exits, or as soon as the
    /// request is superseded. Without an active ``run()`` it returns
    /// ``RunNowResult/notRunning(requestID:)`` immediately.
    ///
    /// - Important: Cancelling the caller's task does not withdraw the request. The
    ///   execution belongs to the run, and only a newer request or the end of the run
    ///   stops it.
    @discardableResult
    func runNow() async -> RunNowResult {
        let requestID = nextID()
        guard activeRunID != nil else {
            emit(.requested(requestID: requestID))
            return .notRunning(requestID: requestID)
        }

        if let superseded = takePendingRequest() {
            superseded.continuation.resume(returning: .superseded(requestID: superseded.id, byRequestID: requestID))
        }
        // Cancel the in-flight execution before observers learn about the request, so a
        // handler reacting to `requested` already sees the handoff under way.
        activeExecution?.cancel()
        emit(.requested(requestID: requestID))
        return await withCheckedContinuation { continuation in
            pendingRequest = PendingRequest(id: requestID, continuation: continuation)
            notifyChange()
        }
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

// MARK: Run Loop

private extension SequentialExecutor {
    /// Alternates between waiting for a trigger and performing one execution until the
    /// run is cancelled.
    func drive() async {
        while !Task.isCancelled {
            switch await awaitTrigger() {
            case .cancelled:
                return
            case .elapsed:
                await perform(source: .scheduled, request: nil)
            case let .immediate(request):
                await perform(source: .runNow(requestID: request.id), request: request)
            }
        }
    }

    /// Waits until the interval elapses or an immediate request is pending.
    ///
    /// A pending request is checked before any wait and again when the interval
    /// elapses, so it preempts the schedule even when both happen at the same moment.
    /// A change to the policy or a new request ends the current wait, and the loop
    /// re-evaluates both. The wait and the change listener race as child tasks.
    func awaitTrigger() async -> Trigger {
        while true {
            if Task.isCancelled { return .cancelled }
            if let request = takePendingRequest() { return .immediate(request) }

            let interval = policy.interval
            if let interval {
                emit(.waitStarted(interval: interval))
            }

            // Register the change listener in this job, before any child task runs, so a
            // change that arrives between the checks above and the child's suspension is
            // buffered rather than lost.
            let listener = registerChangeListener()
            defer { removeChangeListener(listener.id) }
            let clock = self.clock
            let outcome = await withTaskGroup(of: WaitOutcome.self, returning: WaitOutcome.self) { group in
                group.addTask {
                    for await _ in listener.stream {
                        break
                    }
                    return Task.isCancelled ? .cancelled : .changed
                }
                if let interval {
                    group.addTask {
                        do {
                            try await clock.sleep(for: interval)
                            return .elapsed
                        } catch {
                            // ContinuousClock.sleep is documented to throw only CancellationError.
                            return .cancelled
                        }
                    }
                }
                let first = await group.next() ?? .cancelled
                group.cancelAll()
                return first
            }

            switch outcome {
            case .elapsed:
                emit(.intervalElapsed)
                // A request registered while the timer was firing takes the elapsed tick:
                // the immediate execution replaces the scheduled one.
                if let request = takePendingRequest() { return .immediate(request) }
                return .elapsed
            case .changed:
                if interval != nil {
                    emit(.waitCancelled)
                }
            case .cancelled:
                if interval != nil {
                    emit(.waitCancelled)
                }
                return .cancelled
            }
        }
    }

    /// Performs one execution and reports its outcome.
    ///
    /// The execution runs in a task the run owns: `perform` always awaits it, a newer
    /// immediate request cancels it synchronously through `runNow()`, and cancelling
    /// the run is forwarded to it. Nothing outlives this call.
    func perform(source: ExecutionSource, request: PendingRequest?) async {
        let execute = self.execute
        let context = ExecutionContext(executionID: nextID(), source: source)
        // Emit synchronously so `executionStarted` is ordered before any event the
        // actor processes next.
        emit(.executionStarted(executionID: context.executionID, source: source))

        let task = Task {
            await Self.execute(execute, context: context)
        }
        activeExecution = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        activeExecution = nil

        let result: RunNowResult
        switch outcome {
        case .finished:
            emit(.executionFinished(executionID: context.executionID, source: source))
            result = .finished(context)
        case .cancelled:
            emit(.executionCancelled(executionID: context.executionID, source: source))
            result = .cancelled(context)
        case let .failed(error):
            emit(.executionFailed(executionID: context.executionID, source: source, error: error))
            result = .failed(context, error)
        }
        request?.continuation.resume(returning: result)
    }

    /// Runs `execute` off the actor and classifies how it exited.
    ///
    /// A cancellation request takes precedence over how the closure exited: once the
    /// task is cancelled, a normal return or a thrown error both count as cancelled.
    nonisolated static func execute(
        _ execute: @Sendable (ExecutionContext) async throws -> Void,
        context: ExecutionContext
    ) async -> ExecutionOutcome {
        do {
            try Task.checkCancellation()
            try await execute(context)
            return Task.isCancelled ? .cancelled : .finished
        } catch is CancellationError {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .failed(error)
        }
    }

    func takePendingRequest() -> PendingRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }
}

// MARK: Change Notification

private extension SequentialExecutor {
    /// A one-slot stream that receives one element per `notifyChange()` while registered.
    struct ChangeListener {
        let id: UUID
        let stream: AsyncStream<Void>
    }

    /// Registers a listener for the next change.
    ///
    /// A change that arrives after registration and before the listener is consumed is
    /// buffered, so a caller that checks its condition and registers in the same actor
    /// job cannot miss a change between the two.
    func registerChangeListener() -> ChangeListener {
        let id = UUID()
        var continuation: AsyncStream<Void>.Continuation?
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }

        guard let continuation else {
            preconditionFailure("AsyncStream failed to provide a continuation.")
        }

        changeWaiters[id] = continuation
        return ChangeListener(id: id, stream: stream)
    }

    func removeChangeListener(_ id: UUID) {
        changeWaiters[id] = nil
    }

    /// Suspends until the actor's coordination state changes or the current task is
    /// cancelled. Callers check their condition first, in the same actor job.
    func awaitChange() async {
        let listener = registerChangeListener()
        defer { removeChangeListener(listener.id) }
        for await _ in listener.stream {
            return
        }
    }

    /// Wakes every suspended `awaitChange()` caller.
    func notifyChange() {
        for continuation in changeWaiters.values {
            continuation.yield()
        }
    }
}

// MARK: Event Emission

private extension SequentialExecutor {
    func removeEventContinuation(_ subscriberID: UUID) {
        eventContinuations.removeValue(forKey: subscriberID)
    }

    func emit(_ kind: Event.Kind) {
        let event = Event(kind: kind)
        eventHandler?(event)
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}

// MARK: Identifiers

private extension SequentialExecutor {
    /// Issues the next identifier shared by requests, runs, and executions.
    func nextID() -> UInt {
        lastIssuedID &+= 1
        return lastIssuedID
    }
}
