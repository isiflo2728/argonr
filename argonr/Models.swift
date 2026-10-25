//
//  Models.swift
//  argonr
//
//  The JSON contract with the backend. Server speaks snake_case; the decoder
//  converts. Change this file and the server's schema together, or neither.
//

import Foundation

/// POST /model3d
struct GenerateRequest: Encodable {
    let prompt: String
    /// The deployed backend offers glb/obj/stl. GLB is the only one of those
    /// that carries colour, and the app converts it to USD on arrival.
    /// Switch to "usda" once the backend's USD exporter ships — the download
    /// path already passes USD straight through.
    let format = "glb"
}

/// What /model3d returns.
struct GeneratedModel: Decodable {
    let url: String
    let storage: String
    let format: String
    let filename: String
    let parts: Int
    let vertices: Int
    let faces: Int

    var summary: String {
        "\(parts) parts · \(vertices) verts · \(faces) faces"
    }
}

/// One row of GET /models.
struct LibraryModel: Decodable, Identifiable, Equatable {
    let name: String
    let format: String
    let size: Int
    let created: String
    /// Path on the backend, or an absolute URL.
    let url: String
    let prompt: String?
    /// Set when the model was uploaded to cloud storage. Signed links expire,
    /// so this can be present and still fail later.
    let publicUrl: String?

    var id: String { name }

    /// Prefer the uploaded copy: the backend's own disk is ephemeral.
    var bestURL: String { publicUrl ?? url }

    var isViewable: Bool { ["usda", "usdc", "usdz", "glb", "obj", "stl"].contains(format) }

    /// Only USD loads on device without a conversion hop.
    var needsConversion: Bool { !["usda", "usdc", "usdz"].contains(format) }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// What POST /model3d/refine sends back.
///
/// Richer than a plain build: the backend says what it judged and what it
/// changed, which is worth showing rather than swallowing.
struct RefinedModel: Decodable {
    let url: String
    let storage: String
    let format: String
    let filename: String
    let parts: Int
    let vertices: Int
    let faces: Int

    /// Filename this was derived from.
    let parent: String?
    /// Plain-language judgement of the model against the photo.
    let assessment: String?
    /// What it actually altered.
    let changes: [String]?
    /// Factor applied to size, where 1 is unchanged.
    let scale: Double?
    /// How big it looked in the photo, and how big it should be.
    let apparentSizeM: Double?
    let targetSizeM: Double?
    let sizeM: [Double]?
    /// Edits it decided against, and why.
    let skippedEdits: [String]?

    var summary: String { "\(parts) parts · \(vertices) verts · \(faces) faces" }

    /// One line for the viewer: the size correction, when there was one.
    var scaleNote: String? {
        guard let scale, abs(scale - 1) > 0.01 else { return nil }
        let percent = Int(((scale - 1) * 100).rounded())
        return percent > 0 ? "scaled up \(percent)%" : "scaled down \(-percent)%"
    }
}
