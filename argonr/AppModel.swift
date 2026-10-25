//
//  AppModel.swift
//  argonr
//
//  Owns the job lifecycle: send the capture, poll the laptop, pull each .usdz
//  down as it lands. The viewer opens as soon as iteration 0 arrives, so the
//  result is on the floor while the loop is still improving it.
//
//  Video is the primary input — an orbit gives Argon every side, and Argon is
//  strongest on video. A single photo stays supported because on the day
//  someone's recording will fail and you want a one-tap retreat.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {

    enum Phase { case capture, generating, viewing }

    var phase: Phase = .capture
    var kind: CaptureKind = .scene

    /// Set for a photo capture.
    var capturedImage: UIImage?
    /// Set for a video capture, already compressed and trimmed.
    var capturedVideo: URL?
    /// First frame of the video, for the capture well.
    var videoThumbnail: UIImage?
    var videoSeconds: Double?
    var isPreparing = false

    var hint: String = ""
    var serverBase: String = Config.serverBase

    var status: JobStatus?
    var iterations: [IterationInfo] = []
    var selected: Int = 0
    var modelURLs: [Int: URL] = [:]
    var errorMessage: String?
    var loaderNote: String = ""
    var isIterating = false
    /// What the user last asked for, shown while that pass runs.
    var lastInstruction = ""
    /// Everything they have asked for, in order.
    var requests: [String] = []

    private var jobId: String?
    private var pollTask: Task<Void, Never>?

    // MARK: - Derived

    var selectedModelURL: URL? { modelURLs[selected] }
    var selectedIteration: IterationInfo? { iterations.first { $0.index == selected } }
    var isRunning: Bool { !(status?.done ?? true) }
    /// Anything in flight — used to cover the viewer while a pass runs.
    var isWorking: Bool { isRunning || isIterating }

    /// What the capture well shows — video thumbnail or the photo.
    var previewImage: UIImage? { videoThumbnail ?? capturedImage }

    var hasCapture: Bool { capturedVideo != nil || capturedImage != nil }

    var canGenerate: Bool {
        guard !isPreparing else { return false }
        return hasCapture || !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Iterating only makes sense once a pass has finished.
    var canIterate: Bool { jobId != nil && !isRunning && !isIterating }

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

    var durationText: String? {
        guard let seconds = videoSeconds else { return nil }
        return String(format: "%.1fs", seconds)
    }

    // MARK: - Capture

    /// Compresses off the main thread and keeps the thumbnail in step.
    func acceptVideo(_ source: URL) {
        isPreparing = true
        errorMessage = nil
        capturedImage = nil

        Task {
            do {
                let compressed = try await MediaPrep.compress(source)
                capturedVideo = compressed
                videoThumbnail = await MediaPrep.thumbnail(compressed)
                videoSeconds = await MediaPrep.seconds(of: compressed)
                kind = .scene
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparing = false
        }
    }

    func acceptPhoto(_ image: UIImage) {
        clearCapture()
        capturedImage = image
        kind = .object
    }

    func clearCapture() {
        capturedImage = nil
        capturedVideo = nil
        videoThumbnail = nil
        videoSeconds = nil
    }

    // MARK: - Lifecycle

    func generate() {
        guard canGenerate else { return }

        Config.serverBase = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        let video = capturedVideo
        let jpeg = capturedImage?.jpegData(compressionQuality: 0.8)
        let hintText = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureKind = kind

        resetJob()
        phase = .generating

        pollTask = Task {
            do {
                let id = try await APIClient.shared.start(
                    videoURL: video, imageJPEG: jpeg, hint: hintText, kind: captureKind)
                jobId = id
                await poll(job: id)
            } catch {
                fail(error)
            }
        }
    }

    /// Another pass, steered by what the user asked for. This is the whole
    /// interaction: stand in the scene, say what is wrong, watch it change.
    /// An empty instruction lets the loop keep going on its own judgement.
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

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        phase = .capture
    }

    func startOver() {
        pollTask?.cancel()
        pollTask = nil
        resetJob()
        clearCapture()
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
        lastInstruction = ""
        requests = []
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

                if snapshot.done {
                    // A job can finish having produced no model at all — most
                    // often because Blender is missing on the laptop. Say so
                    // instead of parking on the progress screen forever.
                    if modelURLs.isEmpty && phase != .viewing {
                        errorMessage = iterations.isEmpty
                            ? "The laptop finished without building anything. Is the loop server running?"
                            : "The loop ran but exported no model. Is Blender installed on the laptop?"
                        phase = .capture
                    }
                    break
                }
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

                // First model down: get it into the room immediately.
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
