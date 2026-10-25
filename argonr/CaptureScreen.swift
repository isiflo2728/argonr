//
//  CaptureScreen.swift
//  argonr
//
//  Record an orbit of the thing, or a desk of things. The capture is both the
//  input and the reference the critique scores against, so it does double
//  duty — which is why the guidance about keeping it centred matters.
//
//  Spacing grid: 4 / 8 / 12 / 16 / 20 / 24 / 32. Card radius: 10.
//

import SwiftUI
import PhotosUI

struct CaptureScreen: View {
    @Bindable var app: AppModel

    @State private var cameraMode: CameraPicker.Mode?
    @State private var videoItem: PhotosPickerItem?
    @FocusState private var hintFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                captureWell
                captureButtons
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
                    Text(app.isPreparing ? "Compressing" : "Build it")
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
        .fullScreenCover(item: $cameraMode) { mode in
            CameraPicker(mode: mode,
                         onPhoto: { app.acceptPhoto($0) },
                         onVideo: { app.acceptVideo($0) })
                .ignoresSafeArea()
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: MovieFile.self) {
                    app.acceptVideo(movie.url)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("argonr")
                .font(.largeTitle.weight(.semibold))
            Text("Walk a slow circle around it. Argon builds the scene, compares it to your footage, and fixes what it got wrong.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Well

    @ViewBuilder
    private var captureWell: some View {
        if let preview = app.previewImage {
            Image(uiImage: preview)
                .resizable()
                .scaledToFill()
                .frame(height: 240)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) { wellBadge }
                .overlay(alignment: .topTrailing) { clearButton }
                .accessibilityLabel(app.capturedVideo != nil ? "Reference clip" : "Reference photo")
        } else {
            VStack(spacing: 8) {
                if app.isPreparing {
                    ProgressView()
                    Text("Compressing")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.largeTitle.weight(.light))
                        .foregroundStyle(.tertiary)
                    Text("Nothing captured yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        }
    }

    private var wellBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: app.capturedVideo != nil ? "video.fill" : "photo.fill")
            Text(app.capturedVideo != nil
                 ? (app.durationText ?? "clip")
                 : "single photo")
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .capsule)
        .padding(8)
    }

    private var clearButton: some View {
        Button {
            app.clearCapture()
            videoItem = nil
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: .circle)
        }
        .padding(8)
        .accessibilityLabel("Remove capture")
    }

    // MARK: - Buttons

    private var captureButtons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    cameraMode = .video
                } label: {
                    Label("Record orbit", systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Choose clip", systemImage: "film")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            Text("Up to \(Int(MediaPrep.maxSeconds))s, kept centred. Several things on one surface works better than a whole room.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                cameraMode = .photo
            } label: {
                Label("Use a single photo instead", systemImage: "camera")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Fields

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

            Text("Material, style, or something the footage never shows.")
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

extension CameraPicker.Mode: Identifiable {
    public var id: Int {
        switch self {
        case .photo: 0
        case .video: 1
        }
    }
}
