//
//  ContentView.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct ContentView: View {
    @State private var vm = ViewModel()
    @State private var toolbarSelection: ToolbarSelection = .playground

    @ViewBuilder private var selectedView: some View {
        switch toolbarSelection {
        case .playground: PlaygroundView(vm: vm).id(ToolbarSelection.playground).transition(.move(edge: .leading))
        case .document: DocumentView().id(ToolbarSelection.document).transition(.move(edge: .trailing))
        }
    }

    var body: some View {
        selectedView.toolbar {
            Toolbar(
                selection: $toolbarSelection,
                onClear: vm.clearEventHistory
            )
        }
    }
}

#Preview {
    ContentView()
}
