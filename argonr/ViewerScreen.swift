//
//  ViewerScreen.swift
//  argonr
//
//  AR fills the screen; controls float over it in thin material, which is the
//  one place a material belongs — it sits on a live camera feed.
//

import SwiftUI

struct ViewerScreen: View {
    var app: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var note = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainerView(modelURL: app.modelURL, kind: .object) { incoming in
                note = incoming
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !note.isEmpty { noteBubble }
            }
        }
        .animation(motion, value: note)
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

    private var noteBubble: some View {
        Text(note)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(.bottom, 24)
    }
}
