//
//  WorldPromptScreen.swift
//  argonr
//
//  Spacing grid: 4 / 8 / 12 / 16 / 20 / 24 / 32. Card radius: 10.
//

import SwiftUI

struct WorldPromptScreen: View {
    @Bindable var model: WorldModel
    @FocusState private var promptFocused: Bool
    @State private var showSettings = false

    private let examples = [
        "a Star Wars Hoth battle: rebels and a snowspeeder against stormtroopers and an AT-ST",
        "knights storming a castle wall against archers on the battlements",
        "pirates boarding a merchant ship, cannons and cutlasses",
        "giant ants defending their hill from an army of beetles",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                TextField("a Star Wars battle on the ice plains of Hoth",
                          text: $model.prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($promptFocused)
                    .padding(16)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                    .accessibilityLabel("The game to build")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or try")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(examples, id: \.self) { example in
                        Button {
                            model.prompt = example
                            promptFocused = false
                        } label: {
                            Text(example)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground),
                                            in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button(action: buildTapped) {
                    Text("Build the world")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canBuild)

                settings
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("argonr")
                .font(.largeTitle.weight(.semibold))
            Text("Describe a game. Argon writes one program that builds every model, lays out the field and sets the rules — then plays it, finds what's broken, and rewrites it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(showSettings ? "Hide settings" : "Settings") { showSettings.toggle() }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            if showSettings {
                TextField(Config.fallback, text: $model.serverBase)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                    .accessibilityLabel("Backend address")
            }
        }
    }

    private func buildTapped() {
        promptFocused = false
        model.build()
    }
}
