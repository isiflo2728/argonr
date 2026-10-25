//
//  AppModel.swift
//  argonr
//
//  Describe an object, the backend builds it, it lands on the table in front
//  of you. Everything already built is browsable, and a bare URL still works
//  when nothing else does.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {

    enum Phase { case load, viewing }

    var phase: Phase = .load

    // Entry
    var prompt = ""
    var directURL = ""
    var serverBase: String = Config.serverBase

    // Library
    var library: [LibraryModel] = []
    var isLoadingLibrary = false
    /// Optional steer sent alongside the snapshot.
    var refineNote = ""
    /// nil until checked. Drives the dot next to the address.
    var isReachable: Bool?

    // Session
    var modelURL: URL?
    var title = ""
    var subtitle = ""
    var isBuilding = false
    var isFetching = false
    var errorMessage: String?
    var arNote = ""

    // Refinement
    /// Bumped to ask the AR view for a snapshot.
    var captureTicket = 0
    var isRefining = false
    /// The last frame sent, kept so the user can see what Argon was given.
    var lastShot: UIImage?
    /// What the backend judged, and what it did about it. Worth showing —
    /// the interesting part of a refinement is the reasoning, not the file.
    var assessment: String?
    var changes: [String] = []
    var scaleNote: String?
    /// Longest side of what is actually on the table, in metres. Shown so a
    /// size correction is visible rather than merely claimed.
    var sizeMetres: Float?

    var sizeText: String? {
        guard let sizeMetres else { return nil }
        return sizeMetres < 1
            ? "\(Int((sizeMetres * 100).rounded())) cm"
            : String(format: "%.2f m", sizeMetres)
    }
    /// Identifies the model being refined, and what it was asked to be.
    private var currentFilename = ""
    private var currentPrompt = ""

    var isBusy: Bool { isBuilding || isFetching || isRefining }

    /// Only a model that came from the backend can be refined — a pasted
    /// URL has no filename the backend would recognise.
    var canRefine: Bool { !isBusy && !currentFilename.isEmpty }

    var canBuild: Bool {
        !isBusy && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canOpenDirect: Bool {
        !isBusy && URL(string: directURL.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme != nil
    }

    // MARK: - Build

    /// Ask the backend for a new object, then pull it down and show it.
    func build() {
        let asked = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        Config.serverBase = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)

        isBuilding = true
        errorMessage = nil

        Task {
            do {
                let built = try await APIClient.shared.generate(prompt: asked)
                title = asked
                subtitle = built.summary
                currentFilename = built.filename
                currentPrompt = asked
                clearAssessment()
                try await show(path: built.url, name: built.filename)
                prompt = ""
                await refreshLibrary()
            } catch {
                await report(error)
            }
            isBuilding = false
        }
    }

    // MARK: - Library

    func refreshLibrary() async {
        Config.serverBase = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        // Check reachability first: it is a 5s timeout rather than the 300s
        // one a build needs, so a wrong address fails fast and visibly.
        isReachable = await APIClient.shared.isReachable()
        guard isReachable == true else {
            library = []
            return
        }
        do {
            library = try await APIClient.shared.library()
        } catch {
            library = []
        }
    }

    /// Re-check after the address is edited.
    func recheck() {
        Task { await refreshLibrary() }
    }

    func open(_ model: LibraryModel) {
        isFetching = true
        errorMessage = nil
        Task {
            do {
                title = model.prompt ?? model.name
                subtitle = "\(model.format.uppercased()) · \(model.sizeText)"
                currentFilename = model.name
                currentPrompt = model.prompt ?? model.name
                clearAssessment()
                try await show(path: model.bestURL, name: model.name)
            } catch {
                await report(error)
            }
            isFetching = false
        }
    }

    // MARK: - Direct URL

    /// The fallback that cannot be broken by the backend being down: if the
    /// file is reachable, it renders.
    func openDirect() {
        let text = directURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: text) != nil else { return }

        isFetching = true
        errorMessage = nil
        Task {
            do {
                title = "Pasted model"
                subtitle = ""
                currentFilename = ""        // nothing the backend could match
                currentPrompt = ""
                clearAssessment()
                try await show(path: text, name: "pasted-\(UUID().uuidString.prefix(8))")
            } catch {
                await report(error)
            }
            isFetching = false
        }
    }

    func observe(sizeMetres metres: Float) {
        sizeMetres = metres > 0 ? metres : nil
    }

    // MARK: - Refine

    /// Asks the AR view for a frame. The result arrives in `receive(shot:)`.
    func requestCapture() {
        guard canRefine else { return }
        captureTicket += 1
    }

    /// A snapshot came back: send it with the model's identity and let the
    /// backend decide what to fix.
    func receive(shot: UIImage) {
        guard !isRefining, !currentFilename.isEmpty,
              let jpeg = shot.jpegData(compressionQuality: 0.8) else { return }

        lastShot = shot
        isRefining = true
        errorMessage = nil

        let filename = currentFilename
        let note = refineNote.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let refined = try await APIClient.shared.refine(
                    model: filename, imageJPEG: jpeg, note: note)

                subtitle = refined.summary
                currentFilename = refined.filename
                assessment = refined.assessment
                changes = refined.changes ?? []
                scaleNote = refined.scaleNote
                try await show(path: refined.url, name: refined.filename)
                refineNote = ""
                await refreshLibrary()
            } catch {
                await report(error)
            }
            isRefining = false
        }
    }

    // MARK: - Shared

    private func show(path: String, name: String) async throws {
        modelURL = try await APIClient.shared.downloadModel(path: path, name: name)
        phase = .viewing
    }

    private func clearAssessment() {
        assessment = nil
        changes = []
        scaleNote = nil
    }

    func startOver() {
        modelURL = nil
        title = ""
        subtitle = ""
        arNote = ""
        errorMessage = nil
        clearAssessment()
        phase = .load
    }

    /// Distinguishes "wrong address" from "backend is down", because the fix
    /// is different and the error alone does not say which.
    private func report(_ error: Error) async {
        let reachable = await APIClient.shared.isReachable()
        errorMessage = reachable
            ? error.localizedDescription
            : "Can't reach \(Config.serverBase) — is the backend running?"
    }
}
