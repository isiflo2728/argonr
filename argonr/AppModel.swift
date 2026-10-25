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

    var isBusy: Bool { isBuilding || isFetching }

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
                try await show(path: text, name: "pasted-\(UUID().uuidString.prefix(8))")
            } catch {
                await report(error)
            }
            isFetching = false
        }
    }

    // MARK: - Shared

    private func show(path: String, name: String) async throws {
        modelURL = try await APIClient.shared.downloadModel(path: path, name: name)
        phase = .viewing
    }

    func startOver() {
        modelURL = nil
        title = ""
        subtitle = ""
        arNote = ""
        errorMessage = nil
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
