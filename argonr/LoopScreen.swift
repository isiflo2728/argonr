//
//  LoopScreen.swift
//  argonr
//
//  The loop, made watchable. The improvement is the product, so each pass
//  stays on screen with its score, what Argon found, and what it changed —
//  not just the final result.
//

import SwiftUI

struct LoopScreen: View {
    @Bindable var model: WorldModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let improvement = model.improvement {
                    improvementBanner(improvement)
                }

                ForEach(model.passes) { pass in
                    passCard(pass)
                }

                if model.passes.isEmpty && model.isIterating {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Starting the first pass")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .animation(reduceMotion ? nil : .snappy, value: model.passes)
    }

    /// The headline number: did the score actually climb?
    private func improvementBanner(_ change: (from: Double, to: Double)) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Argon's own score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(String(format: "%.2f", change.from))
                        .font(.title2.weight(.light))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.2f", change.to))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(change.to >= change.from
                                         ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                }
            }
            Spacer()
            Text("\(model.versions.count) versions")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    private func passCard(_ pass: LoopPass) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Pass \(pass.index + 1)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                if pass.stage != .done && pass.stage != .failed {
                    ProgressView().controlSize(.mini)
                }

                Text(pass.stage.rawValue)
                    .font(.caption)
                    .foregroundStyle(pass.stage == .failed
                                     ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))

                Spacer()

                Text(pass.scoreText)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            if let verdict = pass.verdict {
                Text(verdict)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Measured facts, which is what the critique is anchored to.
            if pass.avgSeconds != nil || !pass.winners.isEmpty {
                HStack(spacing: 12) {
                    if let seconds = pass.avgSeconds {
                        Label(String(format: "%.1fs matches", seconds),
                              systemImage: "stopwatch")
                    }
                    if let winners = pass.winnerText {
                        Label(winners, systemImage: "flag.checkered")
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            ForEach(pass.bugs) { bug in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(bug.kind)
                            .font(.caption.weight(.bold))
                            .monospaced()
                        Text(bug.severity.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(bug.isHigh ? AnyShapeStyle(.orange)
                                                        : AnyShapeStyle(.secondary))
                    }
                    Text(bug.evidence)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fix = bug.fix {
                        Label(fix, systemImage: "wrench.adjustable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 10))
            }

            if let chars = pass.programChars {
                Label("Argon rewrote \(chars.formatted()) characters of Python",
                      systemImage: "curlybraces")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }
}
