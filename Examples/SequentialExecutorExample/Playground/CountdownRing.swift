//
//  CountdownRing.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct CountdownRing<Content: View>: View {
    private let lineWidth: CGFloat = 12
    private let ringSize: CGFloat = 104
    private let progress: Double
    private let content: Content
    private let stroke: Color

    init(progress: Double, @ViewBuilder content: () -> Content, stroke: Color = .accentColor) {
        self.progress = max(0, min(progress, 1))
        self.content = content()
        self.stroke = stroke
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            content
        }.frame(width: ringSize, height: ringSize)
    }
}

#Preview {
    CountdownRing(
        progress: 0.75,
        content: { EmptyView() }
    )
}
