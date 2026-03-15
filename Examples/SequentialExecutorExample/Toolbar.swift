//
//  Toolbar.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

enum ToolbarSelection: String, CaseIterable {
    case playground
    case document
}

struct Toolbar: ToolbarContent {
    @Binding var selection: ToolbarSelection
    let onClear: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(
                selection: $selection.animation(),
                content: {
                    ForEach(ToolbarSelection.allCases, id: \.self) {
                        Text($0.rawValue.uppercased())
                    }
                },
                label: { EmptyView() }
            ).pickerStyle(.segmented)
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Clear", systemImage: "trash", action: onClear)
        }
    }
}
