//
//  CaptureScreen.swift
//  argonr
//
//  Photograph the object. The photo is both the input and the reference the
//  critique loop scores against, so it does double duty — which is why there
//  is no way to discard it once a job is running.
//
//  Spacing grid: 4 / 8 / 12 / 16 / 24 / 32. Card radius: 10. Nothing else.
//

import SwiftUI
import PhotosUI

struct CaptureScreen: View {
    @Bindable var app: AppModel

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @FocusState private var hintFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                photoWell
                sourceButtons
                hintField
                serverField

                if let error = app.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button {
                    hintFocused = false
                    app.generate()
                } label: {
                    Text("Build it")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!app.canGenerate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in app.capturedImage = image }
                .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    app.capturedImage = image
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("argonr")
                .font(.largeTitle.weight(.semibold))
            Text("Photograph an object. Argon models it, compares the model to your photo, and fixes what it got wrong.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var photoWell: some View {
        if let image = app.capturedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 240)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    Button {
                        app.capturedImage = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .padding(8)
                    .accessibilityLabel("Remove photo")
                }
                .accessibilityLabel("Reference photo")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.largeTitle.weight(.light))
                    .foregroundStyle(.tertiary)
                Text("No photo yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        }
    }

    private var sourceButtons: some View {
        HStack(spacing: 12) {
            Button {
                showCamera = true
            } label: {
                Label("Take photo", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
        }
    }

    private var hintField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hint (optional)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("glazed ceramic, keep it low-poly", text: $app.hint, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .focused($hintFocused)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))

            Text("Material, style, or a part the photo hides.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Laptop")
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
                .accessibilityLabel("Server address")
        }
    }
}
