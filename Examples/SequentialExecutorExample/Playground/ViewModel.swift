//
//  ViewModel.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/14.
//

import Foundation
import Observation
import SequentialExecutor

@MainActor
@Observable
final class ViewModel {
    // MARK: - Constants

    private static let timestampFormat = Date.FormatStyle()
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .secondFraction(.fractional(3))

    static let runLoopIntervalRangeSeconds: ClosedRange<Double> = 1 ... 9
    static let executionDurationRangeMilliseconds: ClosedRange<Int> = 1000 ... 9000

    // MARK: - Types

    struct CountdownSnapshot {
        let isActive: Bool
        let progress: Double
        let leftSeconds: Double
        let totalSeconds: Double
    }

    struct NextExecutionStrategy: Equatable {
        var usesRandomDuration = false
        var fixedDurationMilliseconds = 9000
        var successRate = 1.0
    }

    struct ExecutionPlan {
        enum FailureMode {
            case none
            case immediate
            case scheduled(afterMilliseconds: Int)
        }

        let durationMilliseconds: Int
        let failureMode: FailureMode
    }

    struct ActiveExecution {
        let executionID: UUID
        let source: SequentialExecutor.ExecutionSource
        let plan: ExecutionPlan
        var isFailureRequested = false
    }

    struct PendingExecutionStart {
        let executionID: UUID
        let source: SequentialExecutor.ExecutionSource
        var isFailureRequested = false
    }

    struct EventRecord: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
    }

    // MARK: - Policy

    enum RunLoopSelection: String, CaseIterable, Identifiable {
        case disabled
        case interval

        var id: String {
            rawValue
        }
    }

    struct RunLoopConfig: Equatable {
        var selection: RunLoopSelection = .disabled
        var intervalSeconds: Double = 5.0
    }

    // The controls edit the desired policy immediately.
    // The wait ring only trusts the last policy confirmed by `.policyUpdated`.
    private(set) var runLoopConfig = RunLoopConfig()
    private var appliedRunLoopConfig = RunLoopConfig()

    // MARK: - Next execution strategy

    /// These inputs configure the next execution that starts.
    /// Once an execution is prepared, its plan is frozen by `executionID`.
    private(set) var nextExecutionStrategy = NextExecutionStrategy()

    // MARK: - Outputs

    private(set) var logLimit = 20
    var selectedEventID: EventRecord.ID?
    private(set) var eventList: [EventRecord] = []
    private(set) var nextExecutionPreviewDurationMilliseconds = 9000
    var isExecuting: Bool {
        activeExecution != nil || pendingExecutionStart != nil
    }

    // MARK: - Internals

    private var policy: SequentialExecutor.Policy {
        switch runLoopConfig.selection {
        case .disabled: return .init()
        case .interval: return .init(runLoop: .interval(.milliseconds(runLoopIntervalMilliseconds)))
        }
    }

    private var runLoopIntervalMilliseconds: Int {
        Int((runLoopConfig.intervalSeconds * 10).rounded() * 100)
    }

    @ObservationIgnored private var waitCountdown = CountdownState()
    @ObservationIgnored private var executionCountdown = CountdownState()
    @ObservationIgnored private var waitLoopID: UUID?
    // `.executionStarted` can reach the UI before the main-actor simulator has
    // finished preparing the matching execution plan. Keep a lightweight placeholder
    // so the wait ring does not briefly reappear and `Fail Now` can still target
    // the correct execution.
    private var pendingExecutionStart: PendingExecutionStart?
    private var activeExecution: ActiveExecution?
    @ObservationIgnored private var pendingPolicy: SequentialExecutor.Policy?
    @ObservationIgnored private var policyUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var eventObservationTask: Task<Void, Never>?
    @ObservationIgnored private lazy var executor = makeExecutor()

    init() {
        refreshNextExecutionPreview()
        startObservingEvents()
        updatePolicy()
    }

    deinit {
        policyUpdateTask?.cancel()
        eventObservationTask?.cancel()
    }

    // MARK: - Policy API

    func setRunLoopConfig(_ config: RunLoopConfig) {
        let normalized = normalizedRunLoopConfig(from: config)
        guard runLoopConfig != normalized else { return }
        runLoopConfig = normalized
        updatePolicy()
    }

    private func updatePolicy() {
        enqueuePolicyUpdate()
    }

    // MARK: - Execution API

    func executeNow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyLatestPolicy()
            await self.executor.executeNow()
        }
    }

    func requestFailure() {
        if var activeExecution {
            activeExecution.isFailureRequested = true
            self.activeExecution = activeExecution
            return
        }

        guard var pendingExecutionStart else { return }
        pendingExecutionStart.isFailureRequested = true
        self.pendingExecutionStart = pendingExecutionStart
    }

    func clearEventHistory() {
        eventList.removeAll()
        selectedEventID = nil
    }

    func setLogLimit(_ limit: Int) {
        logLimit = max(limit, 1)
        trimEventHistory()
    }

    // MARK: - Next execution strategy API

    func setNextExecutionUsesRandomDuration(_ isEnabled: Bool) {
        nextExecutionStrategy.usesRandomDuration = isEnabled
        refreshNextExecutionPreview()
    }

    func setNextExecutionFixedDuration(milliseconds: Int) {
        nextExecutionStrategy.fixedDurationMilliseconds = min(
            max(milliseconds, Self.executionDurationRangeMilliseconds.lowerBound),
            Self.executionDurationRangeMilliseconds.upperBound
        )
        refreshNextExecutionPreview()
    }

    func setNextExecutionSuccessRate(_ rate: Double) {
        nextExecutionStrategy.successRate = min(max(rate, 0), 1)
    }

    // MARK: - Snapshots

    func waitSnapshot(at date: Date) -> CountdownSnapshot {
        let configuredTotal =
            appliedRunLoopConfig.selection == .interval
                ? appliedRunLoopConfig.intervalSeconds
                : 0
        let activeTotal = waitCountdown.totalSeconds
        let isActive = waitCountdown.isActive(at: date)
        let totalSeconds = activeTotal > 0 ? activeTotal : configuredTotal
        return .init(
            isActive: isActive,
            progress: waitCountdown.progress(at: date),
            leftSeconds: waitCountdown.remainingSeconds(at: date),
            totalSeconds: totalSeconds
        )
    }

    func executionSnapshot(at date: Date) -> CountdownSnapshot {
        let displayedDurationMilliseconds =
            activeExecution?.plan.durationMilliseconds ?? nextExecutionPreviewDurationMilliseconds
        return .init(
            isActive: executionCountdown.isActive(at: date),
            progress: executionCountdown.progress(at: date),
            leftSeconds: executionCountdown.remainingSeconds(at: date),
            totalSeconds: Double(displayedDurationMilliseconds) / 1000
        )
    }

    // MARK: - Execution lifecycle

    private func runExecution(context: SequentialExecutor.ExecutionContext) async throws {
        let activeExecution = beginExecution(context: context)
        defer { endExecution(executionID: context.executionID) }
        try await simulateExecution(activeExecution)
    }

    private func beginExecution(context: SequentialExecutor.ExecutionContext) -> ActiveExecution {
        let duration =
            nextExecutionStrategy.usesRandomDuration
                ? nextExecutionPreviewDurationMilliseconds
                : nextExecutionStrategy.fixedDurationMilliseconds

        let clampedRate = min(max(nextExecutionStrategy.successRate, 0), 1)
        let failureMode: ExecutionPlan.FailureMode
        if clampedRate <= 0 {
            failureMode = .immediate
        } else if clampedRate >= 1 {
            failureMode = .none
        } else {
            let failureChance = 1 - clampedRate
            if Double.random(in: 0 ..< 1) < failureChance {
                let failureTime = Int.random(in: 0 ... duration)
                if failureTime == 0 {
                    failureMode = .immediate
                } else {
                    failureMode = .scheduled(afterMilliseconds: failureTime)
                }
            } else {
                failureMode = .none
            }
        }

        let isFailureRequested = pendingExecutionStart?.executionID == context.executionID
            ? pendingExecutionStart?.isFailureRequested ?? false
            : false

        let activeExecution = ActiveExecution(
            executionID: context.executionID,
            source: context.source,
            plan: .init(durationMilliseconds: duration, failureMode: failureMode),
            isFailureRequested: isFailureRequested
        )

        pendingExecutionStart = nil
        self.activeExecution = activeExecution
        waitLoopID = nil
        waitCountdown.reset()

        switch activeExecution.plan.failureMode {
        case .none, .scheduled:
            executionCountdown.start(milliseconds: activeExecution.plan.durationMilliseconds)
        case .immediate:
            executionCountdown.reset()
        }

        return activeExecution
    }

    private func endExecution(executionID: UUID) {
        if activeExecution?.executionID == executionID {
            activeExecution = nil
            executionCountdown.reset()
        }
        if pendingExecutionStart?.executionID == executionID {
            pendingExecutionStart = nil
        }
        refreshNextExecutionPreview()
    }

    private func simulateExecution(_ activeExecution: ActiveExecution) async throws {
        let plan = activeExecution.plan
        let endDate = Date().addingTimeInterval(Double(max(plan.durationMilliseconds, 0)) / 1000)

        let scheduledFailureDate: Date?
        switch plan.failureMode {
        case .none: scheduledFailureDate = nil
        case .immediate: throw ExecutionFailure.simulated
        case let .scheduled(afterMilliseconds): scheduledFailureDate = Date().addingTimeInterval(Double(afterMilliseconds) / 1000)
        }

        while true {
            let now = Date()
            if shouldFailExecution(executionID: activeExecution.executionID) {
                throw ExecutionFailure.simulated
            }
            if let scheduledFailureDate, now >= scheduledFailureDate {
                throw ExecutionFailure.simulated
            }
            if now >= endDate {
                break
            }

            let remaining = endDate.timeIntervalSince(now)
            let step = min(remaining, 0.05)
            if step > 0 {
                try await Task.sleep(for: .seconds(step))
            } else {
                break
            }
        }
    }

    private func shouldFailExecution(executionID: UUID) -> Bool {
        guard var activeExecution else { return false }
        guard activeExecution.executionID == executionID else { return false }
        guard activeExecution.isFailureRequested else { return false }
        activeExecution.isFailureRequested = false
        self.activeExecution = activeExecution
        return true
    }

    private func refreshNextExecutionPreview() {
        if nextExecutionStrategy.usesRandomDuration {
            nextExecutionPreviewDurationMilliseconds = Self.randomExecutionDurationMilliseconds()
        } else {
            nextExecutionPreviewDurationMilliseconds = nextExecutionStrategy.fixedDurationMilliseconds
        }
    }

    private func normalizedRunLoopConfig(from config: RunLoopConfig) -> RunLoopConfig {
        var normalized = config
        let clampedSeconds = min(
            max(normalized.intervalSeconds, Self.runLoopIntervalRangeSeconds.lowerBound),
            Self.runLoopIntervalRangeSeconds.upperBound
        )
        normalized.intervalSeconds = clampedSeconds.rounded()
        return normalized
    }

    private func runLoopConfig(from policy: SequentialExecutor.Policy) -> RunLoopConfig {
        switch policy.runLoop {
        case .disabled:
            return .init(selection: .disabled, intervalSeconds: 5.0)
        case let .interval(interval):
            return .init(
                selection: .interval,
                intervalSeconds: Double(interval.millisecondsValue) / 1000
            )
        }
    }

    private func enqueuePolicyUpdate() {
        pendingPolicy = policy
        guard policyUpdateTask == nil else { return }

        policyUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let nextPolicy = self.pendingPolicy {
                self.pendingPolicy = nil
                await self.executor.updatePolicy(nextPolicy)
            }
            self.policyUpdateTask = nil
        }
    }

    private func applyLatestPolicy() async {
        enqueuePolicyUpdate()
        await policyUpdateTask?.value
    }

    private func startObservingEvents() {
        eventObservationTask?.cancel()
        eventObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.executor.events()
            for await event in stream {
                self.handle(event)
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: SequentialExecutor.Event) {
        append(event)

        // The wait ring stays event-driven. Execution UI state is bridged through
        // `pendingExecutionStart` and `activeExecution` so the demo still matches
        // real execution start even when event delivery and the main-actor simulator
        // interleave differently.
        switch event.kind {
        case let .waitStarted(loopID, interval):
            guard activeExecution == nil, pendingExecutionStart == nil else { break }
            executionCountdown.reset()
            waitLoopID = loopID
            waitCountdown.start(milliseconds: interval.millisecondsValue)

        case let .waitCancelled(loopID), let .waitFailed(loopID, _), let .intervalElapsed(loopID):
            if waitLoopID == loopID {
                waitLoopID = nil
                waitCountdown.reset()
            }

        case let .loopStopped(loopID, _), let .loopExited(loopID):
            if waitLoopID == loopID {
                waitLoopID = nil
                waitCountdown.reset()
            }

        case let .executionStarted(executionID, source):
            if activeExecution?.executionID != executionID {
                let wasFailureRequested = pendingExecutionStart?.executionID == executionID
                    ? pendingExecutionStart?.isFailureRequested ?? false
                    : false
                pendingExecutionStart = .init(
                    executionID: executionID,
                    source: source,
                    isFailureRequested: wasFailureRequested
                )
            } else {
                pendingExecutionStart = nil
            }
            waitLoopID = nil
            waitCountdown.reset()

        case let .executionFinished(executionID, _), let .executionCancelled(executionID, _), let .executionFailed(executionID, _, _):
            let cleanedVisibleExecution =
                activeExecution?.executionID == executionID || pendingExecutionStart?.executionID == executionID

            if activeExecution?.executionID == executionID {
                activeExecution = nil
                executionCountdown.reset()
            }
            if pendingExecutionStart?.executionID == executionID {
                pendingExecutionStart = nil
            }
            if cleanedVisibleExecution {
                refreshNextExecutionPreview()
            }

        case let .policyUpdated(_, new): appliedRunLoopConfig = runLoopConfig(from: new)

        case .requested, .loopStarted: break
        }
    }

    private func append(_ event: SequentialExecutor.Event) {
        eventList.append(.init(
            title: event.kind.title,
            subtitle: "\(timestampText(event.emittedAt)) • \(event.kind.detail)"
        ))
        trimEventHistory()
    }

    private func trimEventHistory() {
        eventList = Array(eventList.suffix(logLimit))
        if let selectedEventID, !eventList.contains(where: { $0.id == selectedEventID }) {
            self.selectedEventID = nil
        }
    }

    private func timestampText(_ date: Date) -> String {
        date.formatted(Self.timestampFormat)
    }

    private static func randomExecutionDurationMilliseconds() -> Int {
        Int.random(in: 1 ... 9) * 1000
    }

    // MARK: - Executor

    private func makeExecutor() -> SequentialExecutor {
        return SequentialExecutor(
            execute: { [weak self] context in
                guard let self else { return }
                try await self.runExecution(context: context)
            },
            eventHandler: { event in
                print("[SequentialExecutor] \(event.kind.title) • \(event.kind.detail)")
            }
        )
    }
}

private enum ExecutionFailure: Error {
    case simulated
}

private struct CountdownState {
    private var durationSeconds: Double = 0
    private var endDate: Date?

    var totalSeconds: Double {
        durationSeconds
    }

    mutating func start(milliseconds: Int, now: Date = .now) {
        let durationSeconds = max(0, Double(milliseconds) / 1000)
        guard durationSeconds > 0 else {
            reset()
            return
        }

        self.durationSeconds = durationSeconds
        endDate = now.addingTimeInterval(durationSeconds)
    }

    mutating func reset() {
        durationSeconds = 0
        endDate = nil
    }

    func progress(at date: Date) -> Double {
        guard let endDate, durationSeconds > 0 else { return 0 }
        return min(max(endDate.timeIntervalSince(date) / durationSeconds, 0), 1)
    }

    func remainingSeconds(at date: Date) -> Double {
        guard let endDate else { return 0 }
        return max(endDate.timeIntervalSince(date), 0)
    }

    func isActive(at date: Date) -> Bool {
        remainingSeconds(at: date) > 0
    }
}

private extension Duration {
    var millisecondsValue: Int {
        let components = components
        return Int(components.seconds) * 1000 + Int(components.attoseconds) / 1_000_000_000_000_000
    }
}

private extension SequentialExecutor.Event.Kind {
    var title: String {
        switch self {
        case let .requested(requestID): "requested #\(requestID)"
        case .executionStarted: "executionStarted"
        case .executionFinished: "executionFinished"
        case .executionCancelled: "executionCancelled"
        case .executionFailed: "executionFailed"
        case .policyUpdated: "policyUpdated"
        case .loopStarted: "loopStarted"
        case .loopStopped: "loopStopped"
        case .loopExited: "loopExited"
        case .waitStarted: "waitStarted"
        case .waitCancelled: "waitCancelled"
        case .waitFailed: "waitFailed"
        case .intervalElapsed: "intervalElapsed"
        }
    }

    var detail: String {
        switch self {
        case let .requested(requestID):
            "requestID: \(requestID)"
        case let .executionStarted(executionID, source),
             let .executionFinished(executionID, source),
             let .executionCancelled(executionID, source):
            "executionID: \(executionID.shortID) • \(source.description)"
        case let .executionFailed(executionID, source, error):
            "executionID: \(executionID.shortID) • \(source.description) • \(String(describing: error))"
        case let .policyUpdated(previous, new):
            "from: \(previous.description) • to: \(new.description)"
        case let .loopStarted(loopID),
             let .loopExited(loopID):
            "loopID: \(loopID.shortID)"
        case let .loopStopped(loopID, reason):
            "loopID: \(loopID.shortID) • \(reason.description)"
        case let .waitStarted(loopID, interval):
            "loopID: \(loopID.shortID) • interval: \(interval.millisecondsValue)ms"
        case let .waitCancelled(loopID),
             let .intervalElapsed(loopID):
            "loopID: \(loopID.shortID)"
        case let .waitFailed(loopID, error):
            "loopID: \(loopID.shortID) • \(String(describing: error))"
        }
    }
}

private extension SequentialExecutor.Policy {
    var description: String {
        switch runLoop {
        case .disabled: return "disabled"
        case let .interval(interval): return "interval: \(interval.millisecondsValue)ms"
        }
    }
}

private extension SequentialExecutor.ExecutionSource {
    var description: String {
        switch self {
        case let .executeNow(requestID): "executeNow #\(requestID)"
        case let .scheduledLoop(loopID): "scheduledLoop \(loopID.shortID)"
        }
    }
}

private extension SequentialExecutor.LoopStopReason {
    var description: String {
        switch self {
        case .executeNowRequested: "executeNowRequested"
        case .policyDisabled: "policyDisabled"
        case .policyUpdated: "policyUpdated"
        }
    }
}

private extension UUID {
    var shortID: String {
        String(uuidString.suffix(8))
    }
}
