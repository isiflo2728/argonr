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
    /// USD is what RealityKit loads. The backend builds it from the same part
    /// list it uses for GLB, so nothing is lost by asking for it directly.
    let format = "usda"
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

/// POST /refine — hands the backend a photo of the model sitting in the real
/// world, so the next pass can correct what only that view reveals: scale
/// against real objects, proportions seen from a human angle, parts that
/// read wrong at actual size.
///
/// The response is the same shape as /model3d, so a refined model replaces
/// the current one with no special handling.
struct RefineRequest: Encodable {
    /// Which model this is a view of.
    let filename: String
    /// What it was originally asked to be.
    let prompt: String
    /// JPEG of the AR view, base64.
    let imageB64: String
    /// Optional: what the person wants changed.
    let note: String
    let format = "usda"

    enum CodingKeys: String, CodingKey {
        case filename, prompt, note, format
        case imageB64 = "image_b64"
    }
}
