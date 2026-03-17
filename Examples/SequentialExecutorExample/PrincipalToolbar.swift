//
//  PrincipalCategoryToolbar.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

enum PrincipalCategory: String, CaseIterable {
    case playground
    case document
}

struct PrincipalToolbar: ToolbarContent {
    @Binding var selection: PrincipalCategory

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(
                selection: $selection.animation(),
                content: {
                    ForEach(PrincipalCategory.allCases, id: \.self) {
                        Text($0.rawValue.uppercased())
                    }
                },
                label: {
                    Text("Category")
                }
            ).pickerStyle(.segmented)
        }
    }
}
