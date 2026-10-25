//
//  AppModel.swift
//  argonr
//
//  Owns the job lifecycle: send the photo, poll the laptop, pull each .usdz
//  down as it lands. The viewer opens as soon as iteration 0 arrives, so the
//  model is on the table while the loop is still improving it.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {

    enum Phase { case capture, generating, viewing }

    var phase: Phase = .capture
    var capturedImage: UIImage?
    var hint: String = ""
    var serverBase: String = Config.serverBase

    var status: JobStatus?
    var iterations: [IterationInfo] = []
    var selected: Int = 0
    var modelURLs: [Int: URL] = [:]
    var errorMessage: String?
    var loaderNote: String = ""
    var isIterating: Bool = false

    private var jobId: String?
    private var pollTask: Task<Void, Never>?

    var selectedModelURL: URL? { modelURLs[selected] }
    var selectedIteration: IterationInfo? { iterations.first { $0.index == selected } }
    var isRunning: Bool { !(status?.done ?? true) }

    var canGenerate: Bool {
        capturedImage != nil || !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Iterating only makes sense once a pass has finished.
    var canIterate: Bool {
        jobId != nil && !isRunning && !isIterating
    }

    var scoreText: String {
        guard let score = selectedIteration?.score else { return "—" }
        return String(format: "%.2f", score)
    }

    var matchText: String? {
        guard let match = selectedIteration?.matchScore else { return nil }
        return String(format: "%.0f%%", match * 100)
    }

    // MARK: - Lifecycle

    func generate() {
        guard canGenerate else { return }

        Config.serverBase = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let jpeg = capturedImage?.jpegData(compressionQuality: 0.8)
        let hintText = hint.trimmingCharacters(in: .whitespacesAndNewlines)

        resetJob()
        phase = .generating

        pollTask = Task {
            do {
                let id = try await APIClient.shared.start(imageJPEG: jpeg, hint: hintText)
                jobId = id
                await poll(job: id)
            } catch {
                fail(error)
            }
        }
    }

    /// One more pass, on demand. This is the demo gesture — tap it in AR and
    /// watch the model on the table sharpen.
    func iterate() {
        guard let job = jobId, canIterate else { return }
        isIterating = true

        pollTask = Task {
            do {
                try await APIClient.shared.iterate(job: job)
                await poll(job: job)
            } catch {
                loaderNote = error.localizedDescription
            }
            isIterating = false
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .capture
    }

    func startOver() {
        pollTask?.cancel()
        pollTask = nil
        resetJob()
        capturedImage = nil
        hint = ""
        phase = .capture
    }

    func select(_ index: Int) {
        selected = index
    }

    private func resetJob() {
        status = nil
        iterations = []
        modelURLs = [:]
        selected = 0
        errorMessage = nil
        loaderNote = ""
        jobId = nil
        isIterating = false
    }

    // MARK: - Polling

    private func poll(job: String) async {
        while !Task.isCancelled {
            do {
                let snapshot = try await APIClient.shared.status(job: job)
                status = snapshot
                iterations = snapshot.iterations.sorted { $0.index < $1.index }

                if let message = snapshot.error, !message.isEmpty {
                    errorMessage = message
                }

                await downloadNewModels(job: job)

                if snapshot.done { break }
            } catch {
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

                // First model down: get it onto the table immediately.
                if phase == .generating {
                    selected = iteration.index
                    phase = .viewing
                }
            } catch {
                loaderNote = "Couldn't fetch v\(iteration.index): \(error.localizedDescription)"
            }
        }
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        phase = .capture
    }
}
