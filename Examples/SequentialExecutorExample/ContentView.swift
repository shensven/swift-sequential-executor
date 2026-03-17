//
//  ContentView.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct ContentView: View {
    @State private var vm = ViewModel()
    @State private var principalCategory: PrincipalCategory = .playground

    @ViewBuilder private var selectedView: some View {
        switch principalCategory {
        case .playground: PlaygroundView(vm: vm).id(PrincipalCategory.playground).transition(.move(edge: .leading))
        case .document: DocumentView().id(PrincipalCategory.document).transition(.move(edge: .trailing))
        }
    }

    var body: some View {
        selectedView.toolbar {
            PrincipalToolbar(selection: $principalCategory)
        }
    }
}

#Preview {
    ContentView()
}
