//
//  WorldScreen.swift
//  argonr
//
//  The world on the table, with the loop a swipe away. The version strip is
//  the point: tap back to Argon's first attempt, tap forward to what it
//  arrived at.
//

import SwiftUI

struct WorldScreen: View {
    @Bindable var model: WorldModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var battle: WorldBattle?
    @State private var isRunning = true
    @State private var showLoop = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WorldARView(world: model.world, isRunning: isRunning && !model.isBusy) {
                battle = $0
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: model.selected)
        .sheet(isPresented: $showLoop) {
            NavigationStack {
                LoopScreen(model: model)
                    .navigationTitle("The loop")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.world?.name ?? "World")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.caption)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))

            Spacer()

            Button(isRunning ? "Pause" : "Play",
                   systemImage: isRunning ? "pause.fill" : "play.fill") {
                isRunning.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.footnote.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: .circle)
            .buttonStyle(.plain)

            Button("Start over", systemImage: "xmark", action: model.startOver)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: .circle)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var status: String {
        if let battle, battle.isOver {
            return battle.winner.map { "\($0) wins" } ?? "everyone is down"
        }
        if let battle, !battle.livingByTeam.isEmpty {
            return battle.livingByTeam.map { "\($0.team) \($0.count)" }.joined(separator: "  ")
        }
        guard let world = model.world else { return "" }
        return "\(world.entities.count) entities · \(world.vertexCount.formatted()) verts"
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
            }

            if model.isIterating, let pass = model.passes.last {
                // What the loop is doing right now, without leaving the table.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Pass \(pass.index + 1): \(pass.stage.rawValue)")
                        .font(.caption)
                    if let score = pass.score {
                        Text(String(format: "%.2f", score))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: .capsule)
            }

            if model.versions.count > 1 {
                versionStrip
            }

            HStack(spacing: 8) {
                Button {
                    model.iterate()
                } label: {
                    HStack(spacing: 8) {
                        if model.isIterating {
                            ProgressView().controlSize(.small)
                            Text("Argon is playtesting")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Playtest and fix")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canIterate)

                if !model.passes.isEmpty {
                    Button("Show the loop", systemImage: "list.bullet.rectangle") {
                        showLoop = true
                    }
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: .circle)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var versionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(model.versions.enumerated()), id: \.offset) { index, _ in
                    let isSelected = index == model.selected
                    let score = model.passes.first { $0.index == index - 1 }?.score

                    Button {
                        model.select(index)
                    } label: {
                        VStack(spacing: 4) {
                            Text("v\(index)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text(score.map { String(format: "%.2f", $0) } ?? "—")
                                .font(.caption.weight(.light))
                                .monospacedDigit()
                        }
                        .frame(width: 56, height: 48)
                        .background(isSelected ? AnyShapeStyle(.tint)
                                               : AnyShapeStyle(.ultraThinMaterial),
                                    in: .rect(cornerRadius: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white)
                                                    : AnyShapeStyle(.primary))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Version \(index)")
                    .accessibilityHint("Shows this version on the table")
                }
            }
        }
    }
}
