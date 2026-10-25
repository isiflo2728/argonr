//
//  LoadScreen.swift
//  argonr
//
//  Spacing grid: 4 / 8 / 12 / 16 / 20 / 24 / 32. Card radius: 10.
//

import SwiftUI

struct LoadScreen: View {
    @Bindable var app: AppModel

    @FocusState private var promptFocused: Bool
    @State private var showAdvanced = false

    /// Spread across categories on purpose: four chairs made an open-ended
    /// tool look like a furniture catalogue.
    private let examples = [
        "a red fire hydrant",
        "a low-poly treasure chest",
        "a potted monstera",
        "a yellow school bus",
        "a stack of pancakes with butter",
        "a desk lamp, brushed steel",
        "a wizard's staff with a blue crystal",
        "a vintage rotary telephone",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                connectionRow
                buildSection
                if !app.library.isEmpty { librarySection }
                advancedSection

                if let error = app.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await app.refreshLibrary() }
        .refreshable { await app.refreshLibrary() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("argonr")
                .font(.largeTitle.weight(.semibold))
            Text("Describe anything. It gets built, placed on a real surface at its true size, and you can take the file away.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(app.isReachable == true ? AnyShapeStyle(.green)
                      : app.isReachable == false ? AnyShapeStyle(.orange)
                      : AnyShapeStyle(.tertiary))
                .frame(width: 8, height: 8)

            Text(app.serverBase)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(showAdvanced ? "Done" : "Change") {
                showAdvanced.toggle()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Backend \(app.serverBase), "
                            + (app.isReachable == true ? "reachable"
                               : app.isReachable == false ? "not reachable" : "not checked"))
    }

    // MARK: - Build

    private var buildSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("anything — an object, a creature, a vehicle",
                      text: $app.prompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($promptFocused)
                .padding(16)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                .accessibilityLabel("What to build")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(examples, id: \.self) { example in
                        Button(example) {
                            app.prompt = example
                            promptFocused = false
                        }
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: .capsule)
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(action: buildTapped) {
                Text(app.isBuilding ? "Building" : "Build it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.canBuild)

            if app.isBuilding {
                Text("Argon is modelling it. Up to a minute.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func buildTapped() {
        promptFocused = false
        app.build()
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Already built")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if app.isLoadingLibrary {
                    ProgressView().controlSize(.mini)
                }
            }

            ForEach(app.library) { model in
                Button {
                    app.open(model)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.prompt ?? model.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text("\(model.format.uppercased()) · \(model.sizeText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.needsConversion {
                            // Honest rather than a surprise failure later.
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityHint(model.needsConversion
                                   ? "Not USD — may not load on device"
                                   : "Places this model in AR")
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showAdvanced {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Backend")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField(Config.fallback, text: $app.serverBase)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                        .accessibilityLabel("Backend address")
                        .onSubmit(app.recheck)

                    Text("Or open a model URL directly")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)

                    TextField("https://…/model.usda", text: $app.directURL)
                        .textFieldStyle(.plain)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                        .accessibilityLabel("Model URL")

                    Button("Open in AR", action: app.openDirect)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .disabled(!app.canOpenDirect)
                }
            }
        }
    }
}
