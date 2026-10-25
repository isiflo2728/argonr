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
        case .load:
            LoadScreen(app: app)
        case .viewing:
            ViewerScreen(app: app)
        }
    }
}

#Preview {
    ContentView()
}
