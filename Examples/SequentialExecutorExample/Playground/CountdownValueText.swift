//
//  CountdownValueText.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct CountdownValueText: View, Animatable {
    var isActive: Bool
    var left: Double
    var total: Double
    var inactiveStateText = "Idle"

    var animatableData: Double {
        get { left }
        set { left = newValue }
    }

    private static let secondsFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))

    private var leftText: String {
        left.formatted(Self.secondsFormat)
    }

    private var totalText: String {
        total.formatted(Self.secondsFormat)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isActive {
                Text("\(leftText) / \(totalText)").monospacedDigit()
                Text("remaining").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(inactiveStateText).fontWeight(.medium)
                Text("status").font(.footnote).foregroundStyle(.secondary)
            }
        }.transaction { $0.animation = nil }
    }
}

#Preview {
    CountdownValueText(isActive: false, left: 0, total: 0)
}
