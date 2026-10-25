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
    @Bindable var app: AppModel

    @State private var arNote = ""
    @State private var showDefects = false
    @State private var showReference = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainerView(modelURL: app.selectedModelURL) { note in
                arNote = note
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if showDefects { defectPanel }
                bottomBar
            }
        }
        .animation(.snappy, value: app.selected)
        .animation(.snappy, value: showDefects)
        .sheet(isPresented: $showReference) { referenceSheet }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            scoreCard
            Spacer()
            if app.isRunning { workingPill }
            if app.capturedImage != nil { referenceButton }
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

    private var workingPill: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(app.status?.stageLabel ?? "Working")
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: .capsule)
    }

    private var referenceButton: some View {
        Button {
            showReference = true
        } label: {
            if let image = app.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
        .accessibilityLabel("Compare with your photo")
    }

    private var closeButton: some View {
        Button {
            app.startOver()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: .circle)
        }
        .accessibilityLabel("Start over")
    }

    private var referenceSheet: some View {
        VStack(spacing: 16) {
            if let image = app.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Your reference photo")
            }
            Text("What Argon scores the model against")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .padding(.top, 24)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Defects

    private var defectPanel: some View {
        let defects = app.selectedIteration?.defects ?? []

        return VStack(alignment: .leading, spacing: 16) {
            if defects.isEmpty {
                Text("No defects recorded for this version.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(defects) { defect in
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

                Button {
                    showDefects.toggle()
                } label: {
                    Image(systemName: showDefects ? "list.bullet.circle.fill" : "list.bullet.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel(showDefects ? "Hide defects" : "Show defects")
            }

            iterateButton
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var iterateButton: some View {
        Button {
            app.iterate()
        } label: {
            HStack(spacing: 8) {
                if app.isRunning || app.isIterating {
                    ProgressView().controlSize(.small)
                    Text("Improving")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Iterate")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!app.canIterate)
        .accessibilityHint("Asks Argon for another pass at this model")
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
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8))
                                                : AnyShapeStyle(.secondary))
            }
            .frame(width: 56, height: 48)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.ultraThinMaterial),
                        in: .rect(cornerRadius: 10))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .opacity(isReady ? 1 : 0.4)
        }
        .disabled(!isReady)
        .accessibilityLabel("Version \(iteration.index), score \(String(format: "%.2f", iteration.score))")
        .accessibilityHint(isReady ? "Shows this version in AR" : "Still rendering")
    }
}
