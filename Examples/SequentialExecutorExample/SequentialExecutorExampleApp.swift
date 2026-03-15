//
//  SequentialExecutorExampleApp.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

@main
struct SequentialExecutorExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().frame(
                minWidth: Constant.windowWidth,
                maxWidth: Constant.windowWidth,
                minHeight: Constant.windowHeight,
                maxHeight: .infinity
            )
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
