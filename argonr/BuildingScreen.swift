//
//  BuildingScreen.swift
//  argonr
//

import SwiftUI

struct BuildingScreen: View {
    @Bindable var model: WorldModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().controlSize(.large)

            VStack(spacing: 8) {
                Text("Building the world")
                    .font(.title3.weight(.semibold))
                Text(model.buildNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("One pass writes every model, the layout and the rules together. It takes a few minutes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .padding(24)
    }
}
