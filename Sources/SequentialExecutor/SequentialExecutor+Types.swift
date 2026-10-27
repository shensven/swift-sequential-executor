import Foundation

// MARK: Public Nested Types

// The executor's public contract: events, triggers, results, and the policy. These
// are pure values; the coordination that produces them lives in SequentialExecutor.swift.

extension SequentialExecutor {
    /// Reports the executor's observable lifecycle.
    ///
    /// Request, run, and execution identifiers are issued from one monotonically
    /// increasing counter per executor, so within one executor no two of them share
    /// a number and a larger identifier was always issued later.
    public struct Event: Sendable {
        /// Identifies a lifecycle transition.
        public enum Kind: Sendable {
            /// Reports that a caller requested an immediate execution.
            ///
            /// No scheduled execution starts until this request has settled. The next
            /// `executionStarted` event belongs either to this request or to a newer
            /// request that superseded it.
            case requested(requestID: UInt)

            /// Reports that a single execution started.
            ///
            /// The executor emits this synchronously when it selects the execution,
            /// before awaiting `execute(context)`. It is always ordered before that
            /// execution's finished, cancelled, or failed event.
            case executionStarted(executionID: UInt, source: ExecutionSource)
            /// Reports that `execute` returned normally and no cancellation was requested.
            case executionFinished(executionID: UInt, source: ExecutionSource)
            /// Reports that the executor requested cancellation before `execute` returned,
            /// or that `execute` threw `CancellationError`.
            case executionCancelled(executionID: UInt, source: ExecutionSource)
            /// Reports that `execute` threw a non-cancellation error while no cancellation
            /// was requested.
            case executionFailed(executionID: UInt, source: ExecutionSource, error: any Error & Sendable)

            /// Reports that the policy changed.
            case policyUpdated(previous: Policy, new: Policy)

            /// Reports that `run()` started driving the executor.
            case runStarted(runID: UInt)
            /// Reports that `run()` is returning. No wait or execution of this run is still active.
            case runEnded(runID: UInt)

            /// Reports that the run started waiting for the interval.
            case waitStarted(interval: Duration)
            /// Reports that the current wait ended before the interval elapsed, because the
            /// policy changed, an immediate request arrived, or the run was cancelled.
            case waitCancelled
            /// Reports that the configured interval elapsed.
            case intervalElapsed
        }

        /// The time when the executor emitted this event on its coordination path.
        public let emittedAt: Date
        /// The lifecycle payload emitted at `emittedAt`.
        public let kind: Kind

        /// Creates a lifecycle event stamped with the current time.
        ///
        /// Only the executor creates events, so this initializer stays internal.
        init(kind: Kind) {
            emittedAt = .now
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
        /// Identifies an execution started because the interval elapsed.
        case scheduled
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
        /// Only the executor creates contexts, so this initializer stays internal.
        init(executionID: UInt, source: ExecutionSource) {
            self.executionID = executionID
            self.source = source
        }
    }

    /// Reports how an immediate execution request completed.
    ///
    /// The outcome of a started execution is decided by whether the executor requested
    /// its cancellation, not by whether `execute` happened to finish its work: when
    /// `execute` returns normally after a cancellation request, the executor cannot
    /// tell completed work from abandoned work, so it reports `cancelled`.
    public enum RunNowResult: Sendable {
        /// `execute` returned normally and no cancellation was requested.
        case finished(ExecutionContext)
        /// The executor requested cancellation before `execute` returned, or `execute`
        /// threw `CancellationError`. An error thrown after a cancellation request is
        /// not reported.
        case cancelled(ExecutionContext)
        /// `execute` threw a non-cancellation error while no cancellation was requested.
        case failed(ExecutionContext, any Error & Sendable)
        /// A newer immediate request replaced this request before it started.
        case superseded(requestID: UInt, byRequestID: UInt)
        /// No `run()` was driving the executor when the request was made, or the run
        /// ended before the request started.
        case notRunning(requestID: UInt)
    }

    /// Controls whether the run waits for an interval between executions.
    public enum Policy: Sendable, Equatable {
        /// The run idles until the policy changes or `runNow()` is called.
        case paused
        /// The run waits for the duration before each scheduled execution.
        ///
        /// The duration must be greater than zero; ``SequentialExecutor/updatePolicy(_:)``
        /// traps otherwise. The first execution waits for one full duration, and each
        /// later wait starts after the prior execution exits. This is fixed-delay
        /// scheduling rather than fixed-rate scheduling.
        case interval(Duration)

        var interval: Duration? {
            if case let .interval(interval) = self {
                return interval
            }
            return nil
        }
    }
}
