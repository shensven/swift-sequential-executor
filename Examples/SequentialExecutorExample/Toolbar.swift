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
    @Binding var logLimit: Int
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
                label: {
                    Text("Category")
                }
            ).pickerStyle(.segmented)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("Log Limit", selection: $logLimit) {
                ForEach([10, 20, 50, 100], id: \.self) { limit in
                    Text("\(limit)").tag(limit)
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Clear", systemImage: "trash", action: onClear)
        }
    }
}
