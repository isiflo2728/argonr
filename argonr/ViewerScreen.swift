//
//  ViewerScreen.swift
//  argonr
//
//  AR fills the screen; controls float over it in thin material — the one
//  place a material is right, since it sits on a live camera feed.
//
//  Two interactions carry the demo and both are one tap, never behind a
//  sheet: picking an earlier version swaps the model in place, and Iterate
//  asks for another pass without leaving AR.
//

import SwiftUI

struct ViewerScreen: View {
    var app: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var arNote = ""
    @State private var showDefects = false
    @State private var instruction = ""
    @FocusState private var instructionFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainerView(modelURL: app.selectedModelURL,
                            kind: app.kind) { note in
                arNote = note
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if showDefects { defectPanel }
                bottomBar
            }

            // Sits over the AR view rather than replacing it. Leaving AR would
            // tear down the session and cost the user their floor every pass.
            if app.isWorking { workingOverlay }
        }
        .animation(motion, value: app.selected)
        .animation(motion, value: app.isWorking)
        .animation(motion, value: showDefects)
    }

    /// Honour Reduce Motion — SwiftUI leaves custom animations running.
    private var motion: Animation? { reduceMotion ? nil : .snappy }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            scoreCard
            Spacer()
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("v\(app.selected)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 4) {
                Text("score \(app.scoreText)")
                if let match = app.matchText {
                    Text("· match \(match)")
                }
                if let objects = app.objectCountText {
                    Text("· \(objects)")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
    }

    private var closeButton: some View {
        Button("Start over", systemImage: "xmark", action: app.startOver)
            .labelStyle(.iconOnly)
            .font(.footnote.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: .circle)
            .buttonStyle(.plain)
    }

    // MARK: - Defects

    private var defectPanel: some View {
        let defects = app.selectedIteration?.defects ?? []

        return VStack(alignment: .leading, spacing: 0) {
            if defects.isEmpty {
                Text("No defects recorded for this version.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(defects) { defect in
                    if defect.id != defects.first?.id {
                        Divider().padding(.vertical, 12)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(defect.rubric)
                                .font(.caption.weight(.bold))
                                .monospaced()
                            Text(defect.severity.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(defect.isHigh ? AnyShapeStyle(.orange)
                                                               : AnyShapeStyle(.secondary))
                        }
                        Text(defect.evidence)
                            .font(.footnote)
                        if let fix = defect.fix {
                            Text(fix)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if !arNote.isEmpty {
                Text(arNote)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            if let headline = app.selectedIteration?.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(app.iterations) { iteration in
                            versionChip(iteration)
                        }
                    }
                }

                Button(showDefects ? "Hide defects" : "Show defects",
                       systemImage: showDefects ? "list.bullet.circle.fill" : "list.bullet.circle",
                       action: toggleDefects)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: .circle)
                    .buttonStyle(.plain)
            }

            promptBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var promptBar: some View {
        HStack(spacing: 8) {
            TextField("Make the mug taller…", text: $instruction, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($instructionFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: .capsule)
                .accessibilityLabel("What should change")

            Button("Send this change", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial),
                            in: .circle)
                .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .buttonStyle(.plain)
                .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        app.canIterate && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggleDefects() {
        showDefects.toggle()
    }

    private func send() {
        guard canSend else { return }
        instructionFocused = false
        app.iterate(instruction: instruction)
        instruction = ""
    }

    // MARK: - Working

    private var workingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text(app.status?.stageLabel ?? "Working")
                    .font(.headline)
                    .contentTransition(.opacity)

                if !app.lastInstruction.isEmpty {
                    Text("\u{201C}\(app.lastInstruction)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if let defect = app.iterations.last?.defects.first {
                    Text(defect.evidence)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .transition(.opacity)
    }

    private func versionChip(_ iteration: IterationInfo) -> some View {
        let isSelected = iteration.index == app.selected
        let isReady = app.modelURLs[iteration.index] != nil

        return Button {
            app.select(iteration.index)
        } label: {
            VStack(spacing: 4) {
                Text("v\(iteration.index)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(String(format: "%.2f", iteration.score))
                    .font(.caption.weight(.light))
                    .monospacedDigit()
            }
            .frame(width: 56, height: 48)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial),
                        in: .rect(cornerRadius: 10))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .opacity(isReady ? 1 : 0.3)
        }
        .disabled(!isReady)
        .accessibilityLabel("Version \(iteration.index), score \(String(format: "%.2f", iteration.score))")
        .accessibilityHint(isReady ? "Shows this version in AR" : "Still rendering")
    }
}
