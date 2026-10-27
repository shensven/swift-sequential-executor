import Foundation
import Testing
@testable import SequentialExecutor

// MARK: Event Matchers - General

extension SequentialExecutor.Event {
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

    var isRunStarted: Bool {
        if case .runStarted = kind { return true }
        return false
    }

    var isRunEnded: Bool {
        if case .runEnded = kind { return true }
        return false
    }

    var runStartedID: UInt? {
        if case let .runStarted(runID) = kind { return runID }
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

    var isIntervalElapsed: Bool {
        if case .intervalElapsed = kind { return true }
        return false
    }

    var waitInterval: Duration? {
        if case let .waitStarted(interval) = kind { return interval }
        return nil
    }

    var isExecutionStarted: Bool {
        if case .executionStarted = kind { return true }
        return false
    }
}

enum ExecutionEventSignature: Equatable {
    case requested(UInt)
    case started(UInt, SequentialExecutor.ExecutionSource)
    case finished(UInt, SequentialExecutor.ExecutionSource)
    case cancelled(UInt, SequentialExecutor.ExecutionSource)
}

extension SequentialExecutor.Event {
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

extension SequentialExecutor.Event {
    var isScheduledExecutionStarted: Bool {
        if case .executionStarted(_, .scheduled) = kind { return true }
        return false
    }

    var isScheduledExecutionCancelled: Bool {
        if case .executionCancelled(_, .scheduled) = kind { return true }
        return false
    }

    var isScheduledExecutionFinished: Bool {
        if case .executionFinished(_, .scheduled) = kind { return true }
        return false
    }

    var isScheduledExecutionFailed: Bool {
        if case .executionFailed(_, .scheduled, _) = kind { return true }
        return false
    }
}

// MARK: Event Matchers - Immediate Executions

extension SequentialExecutor.Event {
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

// MARK: Result Matchers

extension SequentialExecutor.RunNowResult {
    /// The request identifier of a result whose execution actually started.
    var startedRequestID: UInt? {
        switch self {
        case let .finished(context), let .cancelled(context), let .failed(context, _):
            if case let .runNow(requestID) = context.source { return requestID }
            return nil
        case .superseded, .notRunning:
            return nil
        }
    }

    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
