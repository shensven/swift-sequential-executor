//
//  PlaygroundView.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct PlaygroundView: View {
    @Bindable var vm: ViewModel
    @State private var runLoopDraft: ViewModel.RunLoopConfig
    @State private var isEditingRunLoopInterval = false

    private let runLoopRangeSeconds = ViewModel.runLoopIntervalRangeSeconds
    private let nextExecutionDurationRangeSeconds: ClosedRange<Double> = 1 ... 9
    private let nextExecutionSuccessRateRange: ClosedRange<Double> = 0 ... 1
    private static let footerSecondsFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))

    init(vm: ViewModel) {
        self.vm = vm
        _runLoopDraft = State(initialValue: vm.runLoopConfig)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section(
                    content: {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                            let wait = vm.waitSnapshot(at: context.date)
                            let execution = vm.executionSnapshot(at: context.date)

                            HStack(alignment: .top, spacing: 32) {
                                CountdownRing(
                                    progress: wait.progress,
                                    content: {
                                        CountdownValueText(
                                            isActive: wait.isActive,
                                            left: wait.leftSeconds,
                                            total: wait.totalSeconds,
                                            inactiveStateText: wait.totalSeconds > 0 ? "Idle" : "Disabled"
                                        )
                                    },
                                    header: { Text("Waiting").font(.headline) },
                                    footer: { Text(policyDurationFooterText).font(.footnote).foregroundStyle(.secondary).monospacedDigit() }
                                )

                                CountdownRing(
                                    progress: execution.progress,
                                    content: {
                                        CountdownValueText(
                                            isActive: execution.isActive,
                                            left: execution.leftSeconds,
                                            total: execution.totalSeconds,
                                            inactiveStateText: "Idle"
                                        )
                                    },
                                    header: { Text("Execution").font(.headline) },
                                    footer: {
                                        Text(nextExecutionDurationFooterText).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                                        Text(nextExecutionSuccessRateFooterText).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                                    },
                                    stroke: .orange
                                )
                            }.frame(maxWidth: .infinity, alignment: .center)
                        }
                    },
                    header: {
                        sectionHeader(
                            title: "Applied Runtime State",
                            description: "These rings reflect the latest state confirmed by SequentialExecutor events."
                        )
                    }
                )

                Section(
                    content: {
                        Picker(
                            "RunLoop",
                            selection: Binding(
                                get: { runLoopDraft.selection },
                                set: { selection in
                                    runLoopDraft.selection = selection
                                    vm.setRunLoopConfig(runLoopDraft)
                                }
                            )
                        ) {
                            ForEach(ViewModel.RunLoopSelection.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }.pickerStyle(.segmented)

                        Slider(
                            value: $runLoopDraft.intervalSeconds,
                            in: runLoopRangeSeconds,
                            step: 1,
                            onEditingChanged: { isEditing in
                                isEditingRunLoopInterval = isEditing
                                if !isEditing {
                                    vm.setRunLoopConfig(runLoopDraft)
                                }
                            },
                            minimumValueLabel: Text(
                                runLoopRangeSeconds.lowerBound,
                                format: .number.precision(.fractionLength(0))
                            ).monospacedDigit(),
                            maximumValueLabel: Text(
                                runLoopRangeSeconds.upperBound,
                                format: .number.precision(.fractionLength(0))
                            ).monospacedDigit(),
                            label: {
                                Text("Next Interval")
                            }
                        ).disabled(runLoopDraft.selection == .disabled)
                    },
                    header: {
                        sectionHeader(
                            title: "Desired RunLoop Policy",
                            description: "These controls edit the next policy to apply. The runtime state above changes after the executor confirms the update."
                        )
                    }
                )

                Section(
                    content: {
                        Toggle("Random Duration", isOn: Binding(
                            get: { vm.nextExecutionStrategy.usesRandomDuration },
                            set: vm.setNextExecutionUsesRandomDuration
                        ))

                        Slider(
                            value: Binding(
                                get: {
                                    let milliseconds =
                                        vm.nextExecutionStrategy.usesRandomDuration
                                            ? vm.nextExecutionPreviewDurationMilliseconds
                                            : vm.nextExecutionStrategy.fixedDurationMilliseconds
                                    return Double(milliseconds) / 1000
                                },
                                set: { newValue in
                                    vm.setNextExecutionFixedDuration(
                                        milliseconds: .init(newValue * 1000)
                                    )
                                }
                            ),
                            in: nextExecutionDurationRangeSeconds,
                            step: 1,
                            minimumValueLabel: Text(
                                nextExecutionDurationRangeSeconds.lowerBound,
                                format: .number.precision(.fractionLength(0))
                            ).monospacedDigit(),
                            maximumValueLabel: Text(
                                nextExecutionDurationRangeSeconds.upperBound,
                                format: .number.precision(.fractionLength(0))
                            ).monospacedDigit(),
                            label: {
                                Text("Next Duration")
                            }
                        ).disabled(vm.nextExecutionStrategy.usesRandomDuration)

                        Slider(
                            value: Binding(
                                get: { vm.nextExecutionStrategy.successRate },
                                set: { vm.setNextExecutionSuccessRate($0) }
                            ),
                            in: nextExecutionSuccessRateRange,
                            step: 0.1,
                            minimumValueLabel: Text(
                                nextExecutionSuccessRateRange.lowerBound,
                                format: .number.precision(.fractionLength(0))
                            ).monospacedDigit(),
                            maximumValueLabel: Text(
                                nextExecutionSuccessRateRange.upperBound,
                                format: .number.precision(.fractionLength(0))
                            ).monospacedDigit(),
                            label: {
                                Text("Next Success Rate")
                            }
                        )

                        LabeledContent(
                            content: {
                                HStack(spacing: 8) {
                                    Button("Execute Now", action: vm.executeNow)
                                    Button("Fail Now", action: vm.requestFailure).disabled(!vm.isExecuting)
                                }
                            },
                            label: {
                                Text("Trigger")
                            }
                        )
                    },
                    header: {
                        sectionHeader(
                            title: "Next Execution Draft",
                            description: "These controls configure the next execution that starts. They do not change the current runtime state until a new execution begins."
                        )
                    }
                )
            }
            .formStyle(.grouped)
            .onChange(of: vm.runLoopConfig) { _, newValue in
                guard !isEditingRunLoopInterval else { return }
                runLoopDraft = newValue
            }

            List(vm.eventList, selection: $vm.selectedEventID) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.body.weight(.medium))
                    Text(event.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .toolbar {
                LogToolbar(
                    logLimit: Binding(
                        get: { vm.logLimit },
                        set: vm.setLogLimit
                    ),
                    onClear: vm.clearEventHistory
                )
            }
        }
    }

    private var policyDurationFooterText: String {
        guard runLoopDraft.selection == .interval else { return "Next Interval: nil" }
        let seconds = runLoopDraft.intervalSeconds.formatted(Self.footerSecondsFormat)
        return "Next Interval: \(seconds)"
    }

    private var nextExecutionDurationFooterText: String {
        let seconds = (Double(vm.nextExecutionPreviewDurationMilliseconds) / 1000).formatted(.number.precision(.fractionLength(1)))
        return "Next Duration: \(seconds)"
    }

    private var nextExecutionSuccessRateFooterText: String {
        let rate = vm.nextExecutionStrategy.successRate.formatted(.number.precision(.fractionLength(1)))
        return "Next Success Rate: \(rate)"
    }

    private func sectionHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description).font(.caption).foregroundStyle(.secondary).textCase(nil)
        }
    }
}

#Preview {
    PlaygroundView(vm: ViewModel())
}
