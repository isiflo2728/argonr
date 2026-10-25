//
//  ContentView.swift
//  argonr
//

import SwiftUI

struct ContentView: View {
    @State private var model = WorldModel()

    var body: some View {
        switch model.phase {
        case .prompt:
            WorldPromptScreen(model: model)
        case .building:
            BuildingScreen(model: model)
        case .playing:
            WorldScreen(model: model)
        }
    }
}

#Preview {
    ContentView()
}
