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

    static let simulationDurationRangeMilliseconds: ClosedRange<Int> = 100 ... 9900

    // MARK: - Types

    struct CountdownSnapshot {
        let progress: Double
        let leftSeconds: Double
        let totalSeconds: Double
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

    var runLoopSelection: RunLoopSelection = .disabled
    var runLoopIntervalSeconds: Double = 5.0

    // MARK: - Simulation

    var usesRandomSimulationDuration = false
    var configuredSimulationDurationMilliseconds = 9900
    var simulationSuccessRate = 1.0

    // MARK: - Outputs

    private(set) var eventList: [EventRecord] = []
    private(set) var displayedSimulationDurationMilliseconds = 9900
    private(set) var isExecuting = false

    var sliderSimulationDurationMilliseconds: Int {
        usesRandomSimulationDuration
            ? displayedSimulationDurationMilliseconds
            : configuredSimulationDurationMilliseconds
    }

    // MARK: - Internals

    private var policy: SequentialExecutor.Policy {
        switch runLoopSelection {
        case .disabled: return .init()
        case .interval: return .init(runLoop: .interval(.milliseconds(runLoopIntervalMilliseconds)))
        }
    }

    private var runLoopIntervalMilliseconds: Int {
        Int((runLoopIntervalSeconds * 10).rounded() * 100)
    }

    @ObservationIgnored private var waitCountdown = CountdownState()
    @ObservationIgnored private var executionCountdown = CountdownState()
    @ObservationIgnored private var waitLoopID: UUID?
    @ObservationIgnored private var forceFailNow = false
    @ObservationIgnored private var forceFailNext = false
    @ObservationIgnored private var pendingPolicy: SequentialExecutor.Policy?
    @ObservationIgnored private var policyUpdateTask: Task<Void, Never>?
    @ObservationIgnored private lazy var executor = makeExecutor()

    init() {
        updatePolicy()
    }

    // MARK: - Policy API

    func updatePolicy() {
        if runLoopSelection == .disabled {
            waitCountdown.reset()
        }
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

    func failNow() {
        if isExecuting {
            forceFailNow = true
        } else {
            forceFailNext = true
        }
    }

    func clearEventHistory() {
        eventList.removeAll()
    }

    // MARK: - Simulation API

    func setSimulationUsesRandomDuration(_ isEnabled: Bool) {
        if isEnabled {
            displayedSimulationDurationMilliseconds = Self.randomSimulationDurationMilliseconds()
        } else {
            configuredSimulationDurationMilliseconds = displayedSimulationDurationMilliseconds
        }
        usesRandomSimulationDuration = isEnabled
        syncSimulationDurationDisplay()
        executeNow()
    }

    func setSimulationDuration(milliseconds: Int) {
        configuredSimulationDurationMilliseconds = min(
            max(milliseconds, Self.simulationDurationRangeMilliseconds.lowerBound),
            Self.simulationDurationRangeMilliseconds.upperBound
        )
        syncSimulationDurationDisplay()
    }

    func setSimulationSuccessRate(_ rate: Double) {
        simulationSuccessRate = min(max(rate, 0), 1)
    }

    // MARK: - Snapshots

    func waitSnapshot(at date: Date) -> CountdownSnapshot {
        let configuredTotal = runLoopIntervalSeconds
        let activeTotal = waitCountdown.totalSeconds
        let totalSeconds = activeTotal > 0 ? activeTotal : configuredTotal
        return .init(
            progress: waitCountdown.progress(at: date),
            leftSeconds: waitCountdown.remainingSeconds(at: date),
            totalSeconds: totalSeconds
        )
    }

    func executionSnapshot(at date: Date) -> CountdownSnapshot {
        .init(
            progress: executionCountdown.progress(at: date),
            leftSeconds: executionCountdown.remainingSeconds(at: date),
            totalSeconds: Double(displayedSimulationDurationMilliseconds) / 1000
        )
    }

    // MARK: - Execution lifecycle

    private func startExecutionCountdown() -> Int {
        let duration: Int
        if usesRandomSimulationDuration {
            duration = Self.randomSimulationDurationMilliseconds()
        } else {
            duration = configuredSimulationDurationMilliseconds
        }

        displayedSimulationDurationMilliseconds = duration
        waitCountdown.reset()
        executionCountdown.start(milliseconds: duration)
        return duration
    }

    private func simulateExecution(durationMilliseconds: Int) async throws {
        let clampedRate = min(max(simulationSuccessRate, 0), 1)
        let failureChance = 1 - clampedRate
        let willFail = Double.random(in: 0 ... 1) < failureChance
        let endDate = Date().addingTimeInterval(Double(max(durationMilliseconds, 0)) / 1000)

        var scheduledFailureDate: Date?
        if forceFailNext {
            forceFailNext = false
            scheduledFailureDate = Date()
        } else if willFail, durationMilliseconds > 0 {
            let failureTime = Int.random(in: 0 ... durationMilliseconds)
            scheduledFailureDate = Date().addingTimeInterval(Double(failureTime) / 1000)
        }

        while true {
            let now = Date()
            if forceFailNow {
                forceFailNow = false
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

    private func syncSimulationDurationDisplay(now: Date = .now) {
        guard !executionCountdown.isActive(at: now) else { return }
        guard !usesRandomSimulationDuration else { return }
        displayedSimulationDurationMilliseconds = configuredSimulationDurationMilliseconds
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

    // MARK: - Event handling

    private func handle(_ event: SequentialExecutor.Event) {
        append(event)

        switch event {
        case let .waitStarted(loopID, interval):
            executionCountdown.reset()
            waitLoopID = loopID
            waitCountdown.start(milliseconds: interval.millisecondsValue)

        case let .waitCancelled(loopID),
             let .waitFailed(loopID, _),
             let .intervalElapsed(loopID):
            if waitLoopID == loopID {
                waitLoopID = nil
                waitCountdown.reset()
            }

        case let .loopStopped(loopID, _),
             let .loopExited(loopID):
            if waitLoopID == loopID {
                waitLoopID = nil
                waitCountdown.reset()
            }

        case .executionStarted:
            isExecuting = true
            waitLoopID = nil
            waitCountdown.reset()

        case .executionFinished, .executionCancelled, .executionFailed:
            isExecuting = false
            forceFailNow = false
            executionCountdown.reset()

        case .requested, .loopStarted, .policyUpdated:
            break
        }
    }

    private func append(_ event: SequentialExecutor.Event) {
        eventList.append(.init(
            title: event.title,
            subtitle: "\(timestampText()) • \(event.detail)"
        ))
        eventList = Array(eventList.suffix(40))
    }

    private func timestampText() -> String {
        Date.now.formatted(Self.timestampFormat)
    }

    private static func randomSimulationDurationMilliseconds() -> Int {
        Int.random(in: 1 ... 99) * 100
    }

    // MARK: - Executor

    private func makeExecutor() -> SequentialExecutor {
        SequentialExecutor(
            execute: { [weak self] in
                let duration = await self?.startExecutionCountdown() ?? 0
                try await self?.simulateExecution(durationMilliseconds: duration)
            },
            eventHandler: { [weak self] event in
                Task { @MainActor in
                    self?.handle(event)
                }
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

private extension SequentialExecutor.Event {
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
        case .disabled:
            return "disabled"
        case let .interval(interval):
            return "interval: \(interval.millisecondsValue)ms"
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
