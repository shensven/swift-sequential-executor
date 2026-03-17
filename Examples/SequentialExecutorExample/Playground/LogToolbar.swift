//
//  LogToolbar.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/17.
//

import SwiftUI

struct LogToolbar: ToolbarContent {
    @Binding var logLimit: Int
    let onClear: () -> Void

    var body: some ToolbarContent {
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
