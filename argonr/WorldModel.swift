//
//  WorldModel.swift
//  argonr
//
//  Describe a game, Argon builds it, plays it, finds what is broken, and
//  rewrites it. The improvement is the product, so every pass is kept and
//  shown rather than only the final result.
//

import Foundation
import Observation

@MainActor
@Observable
final class WorldModel {

    enum Phase { case prompt, building, playing }

    var phase: Phase = .prompt
    var prompt = ""
    var serverBase = Config.serverBase

    /// Every version, oldest first. Index 0 is Argon's first pass.
    var versions: [World] = []
    var selected = 0
    var passes: [LoopPass] = []

    var isBuilding = false
    var isIterating = false
    var errorMessage: String?
    var buildNote = ""

    private var goal = ""

    var world: World? { versions.indices.contains(selected) ? versions[selected] : nil }
    var isBusy: Bool { isBuilding || isIterating }
    var canBuild: Bool { !isBusy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canIterate: Bool { !isBusy && world != nil }

    /// The pitch: does the score actually climb?
    var improvement: (from: Double, to: Double)? {
        let scored = passes.compactMap(\.score)
        guard let first = scored.first, let last = scored.last, scored.count > 1 else { return nil }
        return (first, last)
    }

    func build() {
        let asked = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        Config.serverBase = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)

        goal = asked
        isBuilding = true
        errorMessage = nil
        buildNote = "Argon is writing the program that builds every asset…"
        phase = .building

        Task {
            do {
                let built = try await WorldAPI.shared.build(prompt: asked)
                versions = [built]
                selected = 0
                passes = []
                phase = .playing
            } catch {
                errorMessage = error.localizedDescription
                phase = .prompt
            }
            isBuilding = false
        }
    }

    /// Argon plays what it made, works out what is broken, and rewrites it.
    func iterate(passCount: Int = 3) {
        guard let current = world, !isBusy else { return }
        isIterating = true
        errorMessage = nil
        passes = []

        Task {
            do {
                for try await event in WorldAPI.shared.iterate(
                    world: current, goal: goal, passes: passCount) {
                    apply(event)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isIterating = false
        }
    }

    private func apply(_ event: LoopEvent) {
        let index = event.pass ?? passes.count

        func update(_ change: (inout LoopPass) -> Void) {
            if let position = passes.firstIndex(where: { $0.index == index }) {
                change(&passes[position])
            } else {
                var fresh = LoopPass(index: index)
                change(&fresh)
                passes.append(fresh)
            }
        }

        switch event.event {
        case "pass_start":
            update { $0.stage = .playing }

        case "playtested":
            update {
                $0.stage = .rendering
                $0.playable = event.telemetry?.playable
                $0.avgSeconds = event.telemetry?.avgSeconds
                $0.winners = event.telemetry?.winners ?? [:]
            }

        case "rendered":
            update { $0.stage = .watching }

        case "critiqued":
            update {
                $0.stage = .fixing
                $0.score = event.score
                $0.verdict = event.verdict
                $0.bugs = event.bugs ?? []
                $0.playable = event.playable
                $0.avgSeconds = event.avgSeconds
                $0.winners = event.winners ?? [:]
            }

        case "fixed":
            update {
                $0.stage = .done
                $0.programChars = event.programChars
            }
            // A rewritten world is a new version, not a replacement — the
            // point is being able to look back at what it started from.
            if let revised = event.world {
                versions.append(revised)
                selected = versions.count - 1
            }

        case "fix_failed":
            update { $0.stage = .failed }
            errorMessage = event.detail

        case "done":
            update { if $0.stage != .failed { $0.stage = .done } }

        case "error":
            errorMessage = event.detail

        default:
            break
        }
    }

    func select(_ index: Int) {
        guard versions.indices.contains(index) else { return }
        selected = index
    }

    func startOver() {
        versions = []
        passes = []
        selected = 0
        errorMessage = nil
        phase = .prompt
    }
}
