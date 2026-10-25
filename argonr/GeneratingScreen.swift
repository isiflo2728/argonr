//
//  GeneratingScreen.swift
//  argonr
//
//  The loop is the product, so show it running rather than hiding it behind a
//  spinner. Swaps itself out the moment the first model lands.
//

import SwiftUI

struct GeneratingScreen: View {
    @Bindable var app: AppModel

    private let stages = ["generating", "rendering", "watching", "critiquing", "fixing"]

    private enum StagePosition { case done, current, pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text(app.status?.stageLabel ?? "Starting")
                    .font(.title3.weight(.semibold))
                    .contentTransition(.opacity)

                if let status = app.status {
                    Text("Iteration \(status.iteration + 1) of \(status.totalIterations)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            stageList

            if let defect = app.iterations.last?.defects.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Argon found")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(defect.evidence)
                        .font(.subheadline)
                    if let fix = defect.fix {
                        Text(fix)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }

            if !app.loaderNote.isEmpty {
                Text(app.loaderNote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Cancel", role: .cancel) { app.cancel() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .animation(.default, value: app.status?.stage)
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stages, id: \.self) { stage in
                let state = position(of: stage)
                HStack(spacing: 12) {
                    Image(systemName: icon(for: state))
                        .font(.footnote)
                        .foregroundStyle(tint(for: state))
                    Text(stage.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(state == .pending ? AnyShapeStyle(.tertiary)
                                                           : AnyShapeStyle(.primary))
                    Spacer()
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stage), \(label(for: state))")
            }
        }
    }

    private func icon(for state: StagePosition) -> String {
        switch state {
        case .done:    "checkmark.circle.fill"
        case .current: "circle.dotted"
        case .pending: "circle"
        }
    }

    private func tint(for state: StagePosition) -> AnyShapeStyle {
        switch state {
        case .done:    AnyShapeStyle(.green)
        case .current: AnyShapeStyle(.primary)
        case .pending: AnyShapeStyle(.tertiary)
        }
    }

    private func label(for state: StagePosition) -> String {
        switch state {
        case .done:    "done"
        case .current: "in progress"
        case .pending: "waiting"
        }
    }

    private func position(of stage: String) -> StagePosition {
        guard let current = app.status?.stage,
              let currentIndex = stages.firstIndex(of: current),
              let thisIndex = stages.firstIndex(of: stage) else { return .pending }
        if thisIndex < currentIndex { return .done }
        if thisIndex == currentIndex { return .current }
        return .pending
    }
}
