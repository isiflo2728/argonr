//
//  ContentView.swift
//  argonr
//
//  Created by Isidoro Flores on 10/25/26.
//

import SwiftUI

struct ContentView: View {
    @State private var app = AppModel()

    var body: some View {
        switch app.phase {
        case .capture:
            CaptureScreen(app: app)
        case .generating:
            GeneratingScreen(app: app)
        case .viewing:
            ViewerScreen(app: app)
        }
    }
}

#Preview {
    ContentView()
}
