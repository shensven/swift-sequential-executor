//
//  DocumentView.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct DocumentView: View {
    var body: some View {
        VStack {
            ContentUnavailableView {
                Label("SequentialExecutor", systemImage: "book.pages")
            } description: {
                Text("Explore the complete API reference and usage guides online.")
            } actions: {
                Link("Open Documentation", destination: Constant.documentationURL).buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Made with ❤️ in Kunming by Sven")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding()
        }
    }
}

#Preview {
    DocumentView()
}
