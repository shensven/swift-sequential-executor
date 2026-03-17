//
//  CountdownRing.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct CountdownRing<Content: View, Header: View, Footer: View>: View {
    private let lineWidth: CGFloat = 12
    private let ringSize: CGFloat = 96
    private let progress: Double
    private let content: Content
    private let header: Header
    private let footer: Footer
    private let stroke: Color

    init(
        progress: Double,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer,
        stroke: Color = .accentColor
    ) {
        self.progress = max(0, min(progress, 1))
        self.content = content()
        self.header = header()
        self.footer = footer()
        self.stroke = stroke
    }

    var body: some View {
        VStack {
            header

            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                content
            }
            .frame(width: ringSize, height: ringSize)
            .padding(lineWidth / 2)

            footer
        }.transaction { $0.animation = nil }
    }
}

#Preview {
    CountdownRing(
        progress: 0.75,
        content: { EmptyView() },
        header: { EmptyView() },
        footer: { EmptyView() }
    )
}
