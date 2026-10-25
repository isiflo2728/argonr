//
//  ViewerScreen.swift
//  argonr
//
//  AR fills the screen; controls float over it in thin material, which is the
//  one place a material belongs — it sits on a live camera feed.
//

import SwiftUI

struct ViewerScreen: View {
    @Bindable var app: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainerView(modelURL: app.modelURL,
                            kind: .object,
                            captureTicket: app.captureTicket,
                            onNote: { note = $0 },
                            onCapture: app.receive(shot:))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !note.isEmpty { noteBubble }
                bottomBar
            }

            if app.isRefining { refiningOverlay }
        }
        .animation(motion, value: note)
        .animation(motion, value: app.isRefining)
        .animation(motion, value: app.assessment)
    }

    private var motion: Animation? { reduceMotion ? nil : .snappy }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if !app.subtitle.isEmpty {
                    Text(app.subtitle)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))

            Spacer()

            Button("Back", systemImage: "xmark", action: app.startOver)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: .circle)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// What the last refinement judged and changed. The reasoning is the
    /// interesting part of a correction, so it is shown rather than swallowed.
    private var assessmentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let assessment = app.assessment {
                Text(assessment)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let scaleNote = app.scaleNote {
                Label(scaleNote, systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }

            ForEach(app.changes, id: \.self) { change in
                Label(change, systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if app.assessment != nil || !app.changes.isEmpty {
                assessmentCard
            }

            if let error = app.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            HStack(spacing: 8) {
                TextField("Optional: what looks wrong", text: $app.refineNote, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($noteFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: .capsule)
                    .accessibilityLabel("What looks wrong")

                Button("Improve from this view", systemImage: "camera.viewfinder",
                       action: capture)
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(app.canRefine ? AnyShapeStyle(.tint)
                                              : AnyShapeStyle(.ultraThinMaterial),
                                in: .circle)
                    .foregroundStyle(app.canRefine ? AnyShapeStyle(.white)
                                                   : AnyShapeStyle(.secondary))
                    .buttonStyle(.plain)
                    .disabled(!app.canRefine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func capture() {
        noteFocused = false
        app.requestCapture()
    }

    private var refiningOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                if let shot = app.lastShot {
                    // Show exactly what was sent — the frame is the input.
                    Image(uiImage: shot)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(.rect(cornerRadius: 10))
                }
                ProgressView().controlSize(.large)
                Text("Improving from this view")
                    .font(.headline)
                if !app.refineNote.isEmpty {
                    Text("\u{201C}\(app.refineNote)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
        .transition(.opacity)
    }

    private var noteBubble: some View {
        Text(note)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(.bottom, 24)
    }
}
