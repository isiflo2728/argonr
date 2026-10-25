//
//  LoadScreen.swift
//  argonr
//
//  Two ways in, because the backend may not be reachable when you need to
//  demo. Pasting a URL always works — if a model exists anywhere on the
//  network, it renders. Connecting to a job additionally gets you versions
//  and the ability to ask for changes.
//
//  Spacing grid: 4 / 8 / 12 / 16 / 20 / 24 / 32. Card radius: 10.
//

import SwiftUI

struct LoadScreen: View {
    @Bindable var app: AppModel

    @FocusState private var focus: Field?
    private enum Field { case url, job, server }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                directSection
                orDivider
                jobSection

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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("argonr")
                .font(.largeTitle.weight(.semibold))
            Text("Put a generated scene on the table in front of you, then say what should change.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Paste a URL

    private var directSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model URL")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("https://storage.googleapis.com/…/scene.usda", text: $app.directURL)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focus, equals: .url)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                .accessibilityLabel("Model URL")

            Text("USD only — .usda, .usdc or .usdz.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                focus = nil
                app.openDirect()
            } label: {
                Text(app.isWorking ? "Loading" : "Open in AR")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.canOpenDirect)
        }
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.separator).frame(height: 1)
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    // MARK: - Attach to a job

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Job on the laptop")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("job id", text: $app.jobIdInput)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .job)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                .accessibilityLabel("Job identifier")

            TextField(Config.fallback, text: $app.serverBase)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focus, equals: .server)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
                .accessibilityLabel("Server address")

            Text("Gets you every version and the ability to ask for changes.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                focus = nil
                app.attachToJob()
            } label: {
                Text("Attach")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.bordered)
            .disabled(!app.canAttach)
        }
    }
}
