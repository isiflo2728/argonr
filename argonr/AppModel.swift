//
//  AppModel.swift
//  argonr
//
//  This app is the viewer. Models are built elsewhere; its job is to put one
//  on the table in front of you, let you say what should change, and show the
//  result without losing your place in the room.
//
//  Two ways in, because a demo should not depend on a backend being up:
//
//    direct  — paste a URL, render it. Always works if the file exists.
//    job     — attach to a job on the loop server. Adds versions and the
//              ability to ask for changes.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {

    enum Phase { case load, viewing }

    var phase: Phase = .load

    // Entry
    var directURL = ""
    var jobIdInput = ""
    var serverBase: String = Config.serverBase

    // Session
    var kind: CaptureKind = .scene
    var status: JobStatus?
    var iterations: [IterationInfo] = []
    var selected = 0
    var modelURLs: [Int: URL] = [:]
    var errorMessage: String?
    var loaderNote = ""
    var isIterating = false
    var isLoadingDirect = false

    /// What the user last asked for, shown while that pass runs.
    var lastInstruction = ""
    /// Everything they have asked for, in order.
    var requests: [String] = []

    private var jobId: String?
    private var pollTask: Task<Void, Never>?

    // MARK: - Derived

    var selectedModelURL: URL? { modelURLs[selected] }
    var selectedIteration: IterationInfo? { iterations.first { $0.index == selected } }

    var isRunning: Bool { status.map { !$0.done } ?? false }
    var isWorking: Bool { isRunning || isIterating || isLoadingDirect }

    /// Only a job can be iterated — a pasted URL has nothing behind it.
    var canIterate: Bool { jobId != nil && !isWorking }
    var isAttached: Bool { jobId != nil }

    var canOpenDirect: Bool {
        !isWorking && URL(string: directURL.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme != nil
    }

    var canAttach: Bool {
        !isWorking && !jobIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var scoreText: String {
        guard let score = selectedIteration?.score else { return "—" }
        return String(format: "%.2f", score)
    }

    var matchText: String? {
        guard let match = selectedIteration?.matchScore else { return nil }
        return String(format: "%.0f%%", match * 100)
    }

    var objectCountText: String? {
        guard let count = selectedIteration?.objectCount else { return nil }
        return count == 1 ? "1 object" : "\(count) objects"
    }

    // MARK: - Direct

    /// Paste a URL, render it. No job, no versions, no iteration — but it
    /// cannot be broken by a backend that is down.
    func openDirect() {
        let text = directURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let _ = URL(string: text) else { return }

        reset()
        isLoadingDirect = true

        Task {
            do {
                let local = try await APIClient.shared.downloadModel(
                    path: text, job: "direct", iteration: 0)
                modelURLs[0] = local
                iterations = [IterationInfo(
                    index: 0, score: 0, matchScore: nil, objectCount: nil,
                    modelPath: text, headline: "loaded", defects: [])]
                selected = 0
                phase = .viewing
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingDirect = false
        }
    }

    // MARK: - Job

    func attachToJob() {
        Config.serverBase = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = jobIdInput.trimmingCharacters(in: .whitespacesAndNewlines)

        reset()
        jobId = job

        pollTask = Task { await poll(job: job) }
    }

    /// Another pass, steered by what the user asked for. This is the whole
    /// interaction: stand in the scene, say what is wrong, watch it change.
    func iterate(instruction: String = "") {
        guard let job = jobId, canIterate else { return }
        let asked = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        isIterating = true
        lastInstruction = asked
        if !asked.isEmpty { requests.append(asked) }

        pollTask = Task {
            do {
                try await APIClient.shared.iterate(job: job, instruction: asked)
                await poll(job: job)
            } catch {
                loaderNote = error.localizedDescription
            }
            isIterating = false
        }
    }

    func select(_ index: Int) { selected = index }

    func startOver() {
        pollTask?.cancel()
        pollTask = nil
        reset()
        phase = .load
    }

    private func reset() {
        status = nil
        iterations = []
        modelURLs = [:]
        selected = 0
        errorMessage = nil
        loaderNote = ""
        jobId = nil
        isIterating = false
        lastInstruction = ""
        requests = []
    }

    // MARK: - Polling

    private func poll(job: String) async {
        var sawAnything = false

        while !Task.isCancelled {
            do {
                let snapshot = try await APIClient.shared.status(job: job)
                sawAnything = true
                status = snapshot
                iterations = snapshot.iterations.sorted { $0.index < $1.index }

                if let message = snapshot.error, !message.isEmpty {
                    errorMessage = message
                }

                await downloadNewModels(job: job)

                if snapshot.done {
                    if modelURLs.isEmpty && phase != .viewing {
                        errorMessage = "That job has not produced a model yet."
                        phase = .load
                    }
                    break
                }
            } catch {
                if !sawAnything {
                    errorMessage = "Couldn't reach that job — \(error.localizedDescription)"
                    phase = .load
                    return
                }
                // A dropped poll on venue wifi is not fatal — keep trying.
                loaderNote = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(Config.pollSeconds))
        }
    }

    private func downloadNewModels(job: String) async {
        for iteration in iterations {
            guard modelURLs[iteration.index] == nil,
                  let path = iteration.modelPath else { continue }
            do {
                let url = try await APIClient.shared.downloadModel(
                    path: path, job: job, iteration: iteration.index)
                modelURLs[iteration.index] = url

                // First model down: get it into the room immediately.
                if phase == .load {
                    selected = iteration.index
                    phase = .viewing
                } else if iteration.index > selected {
                    // A newer version landed while watching — show it.
                    selected = iteration.index
                }
            } catch {
                loaderNote = "Couldn't fetch v\(iteration.index): \(error.localizedDescription)"
            }
        }
    }
}
