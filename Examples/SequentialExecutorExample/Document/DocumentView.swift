//
//  DocumentView.swift
//  SequentialExecutorExample
//
//  Created by DevSven on 2026/3/13.
//

import SwiftUI

struct DocumentView: View {
    var body: some View {
        HStack {
            Image(systemName: "laurel.leading")
            Text("Made with ❤️ in Kunming by Sven")
            Image(systemName: "laurel.trailing")
        }
    }
}

#Preview {
    DocumentView()
}
