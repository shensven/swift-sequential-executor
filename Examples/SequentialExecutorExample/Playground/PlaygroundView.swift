//
//  PlaygroundView.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct PlaygroundView: View {
    @Bindable var vm: ViewModel

    private let runLoopRangeSeconds: ClosedRange<Double> = 0.1 ... 9.9
    private let simulationRangeSeconds: ClosedRange<Double> = 0.1 ... 9.9
    private let simulationSuccessRange: ClosedRange<Double> = 0 ... 1

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                        let wait = vm.waitSnapshot(at: context.date)
                        let execution = vm.executionSnapshot(at: context.date)

                        HStack(spacing: 32) {
                            CountdownRing(
                                progress: wait.progress,
                                content: {
                                    CountdownValueText(left: wait.leftSeconds, total: wait.totalSeconds, label: "interval").padding(.top, 6)
                                }
                            )

                            CountdownRing(
                                progress: execution.progress,
                                content: {
                                    CountdownValueText(left: execution.leftSeconds, total: execution.totalSeconds, label: "execution").padding(.top, 6)
                                },
                                stroke: .orange
                            )
                        }.frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                Section("Policy") {
                    Picker(
                        "RunLoop",
                        selection: Binding(
                            get: { vm.runLoopSelection },
                            set: { newValue in
                                vm.runLoopSelection = newValue
                                vm.updatePolicy()
                            }
                        )
                    ) {
                        ForEach(ViewModel.RunLoopSelection.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }.pickerStyle(.segmented)

                    Slider(
                        value: Binding(
                            get: { vm.runLoopIntervalSeconds },
                            set: { newValue in
                                vm.runLoopIntervalSeconds = (newValue * 10).rounded() / 10
                            }
                        ),
                        in: runLoopRangeSeconds,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                vm.updatePolicy()
                            }
                        },
                        minimumValueLabel: Text(
                            runLoopRangeSeconds.lowerBound,
                            format: .number.precision(.fractionLength(1))
                        ).monospacedDigit(),
                        maximumValueLabel: Text(
                            runLoopRangeSeconds.upperBound,
                            format: .number.precision(.fractionLength(1))
                        ).monospacedDigit(),
                        label: {
                            Text("Duration")
                        }
                    ).disabled(vm.runLoopSelection == .disabled)
                }

                Section(
                    content: {
                        Toggle(
                            "Random Duration",
                            isOn: Binding(
                                get: { vm.usesRandomSimulationDuration },
                                set: vm.setSimulationUsesRandomDuration
                            )
                        )

                        Slider(
                            value: Binding(
                                get: { Double(vm.sliderSimulationDurationMilliseconds) / 1000 },
                                set: { newValue in
                                    vm.setSimulationDuration(
                                        milliseconds: Int((newValue * 10).rounded() * 100)
                                    )
                                }
                            ),
                            in: simulationRangeSeconds,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    vm.executeNow()
                                }
                            },
                            minimumValueLabel: Text(
                                simulationRangeSeconds.lowerBound,
                                format: .number.precision(.fractionLength(1))
                            ).monospacedDigit(),
                            maximumValueLabel: Text(
                                simulationRangeSeconds.upperBound,
                                format: .number.precision(.fractionLength(1))
                            ).monospacedDigit(),
                            label: {
                                Text("Simulated Duration")
                            }
                        ).disabled(vm.usesRandomSimulationDuration)

                        Slider(
                            value: Binding(
                                get: { vm.simulationSuccessRate },
                                set: vm.setSimulationSuccessRate
                            ),
                            in: simulationSuccessRange,
                            step: 0.1,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    vm.executeNow()
                                }
                            },
                            minimumValueLabel: Text(
                                simulationSuccessRange.lowerBound,
                                format: .number.precision(.fractionLength(1))
                            ).monospacedDigit(),
                            maximumValueLabel: Text(
                                simulationSuccessRange.upperBound,
                                format: .number.precision(.fractionLength(1))
                            ).monospacedDigit(),
                            label: {
                                Text("Success Rate")
                            }
                        )

                        LabeledContent(
                            content: {
                                HStack(spacing: 8) {
                                    Button("Execute Now", action: vm.executeNow)
                                    Button("Fail Now", action: vm.failNow)
                                        .disabled(!vm.isExecuting)
                                }
                            },
                            label: {
                                Text("Trigger")
                            }
                        )
                    },
                    header: {
                        Text("Preemptive Simulator")
                        Text("Configure the simulated workload and immediate runs.")
                    }
                )
            }
            .formStyle(.grouped)

            List(vm.eventList, selection: $vm.selectedEventID) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.body.weight(.medium))
                    Text(event.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.plain)
        }
    }
}

#Preview {
    PlaygroundView(vm: ViewModel())
}
