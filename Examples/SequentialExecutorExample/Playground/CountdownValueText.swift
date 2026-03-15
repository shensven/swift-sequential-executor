//
//  CountdownValueText.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct CountdownValueText: View, Animatable {
    var left: Double
    var total: Double
    var label: String

    var animatableData: Double {
        get { left }
        set { left = newValue }
    }

    private static let secondsFormat =
        FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))

    private var leftText: String {
        left.formatted(Self.secondsFormat)
    }

    private var totalText: String {
        total.formatted(Self.secondsFormat)
    }

    var body: some View {
        VStack(spacing: 0) {
            if total <= 0 {
                Text("nil").monospacedDigit()
            } else if left <= 0 {
                Text("nil / \(totalText)").monospacedDigit()
            } else {
                Text("\(leftText) / \(totalText)").monospacedDigit()
            }
            Text(label).font(.footnote).opacity(0.7)
        }
    }
}

#Preview {
    CountdownValueText(left: 0, total: 0, label: "wait")
}
