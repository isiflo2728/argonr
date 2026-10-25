//
//  APIClient.swift
//  argonr
//

import Foundation

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case badURL
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let detail):
            detail.isEmpty ? "Server returned \(code)" : detail
        case .badURL:
            "Bad server address"
        case .unsupportedFormat(let what):
            "The server sent \(what)"
        }
    }
}

struct APIClient {
    static let shared = APIClient()

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        // Building a model is a long model call, not a web request.
        c.timeoutIntervalForRequest = 300
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    // MARK: - Backend

    /// POST /model3d — asks the backend to build an object and return its URL.
    func generate(prompt: String) async throws -> GeneratedModel {
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("model3d"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GenerateRequest(prompt: prompt))

        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(GeneratedModel.self, from: data)
    }

    /// POST /model3d/refine — hands the backend a photo of the model sitting
    /// in the real world and gets back a corrected one. Multipart, because
    /// the image goes up as a file rather than base64 in JSON.
    func refine(model: String, imageJPEG: Data, note: String) async throws -> RefinedModel {
        let boundary = "argonr.\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        field("model", model)
        field("note", note)
        field("format", "glb")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"view.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageJPEG)
        body.append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: Config.baseURL
            .appendingPathComponent("model3d")
            .appendingPathComponent("refine"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try decoder.decode(RefinedModel.self, from: data)
    }

    /// GET /models — everything built so far.
    func library() async throws -> [LibraryModel] {
        let (data, response) = try await session.data(
            from: Config.baseURL.appendingPathComponent("models"))
        try check(response, data)
        return try decoder.decode([LibraryModel].self, from: data)
    }

    /// GET /health — used to tell "wrong address" from "backend is down".
    func isReachable() async -> Bool {
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Fetching the model itself

    /// Downloads a model named by a path or a fully-qualified URL.
    ///
    /// The file is saved with a USD extension because RealityKit dispatches on
    /// it. The URL is not trusted to carry one — signed cloud links end in a
    /// query string and object keys often have no extension — so the format is
    /// sniffed from the bytes, which cannot lie.
    /// Both files: the USD the viewer needs, and the original the backend
    /// sent. The original is kept because that is the one other tools want —
    /// GLB opens in Blender, Unity and Quick Look, and an asset you cannot
    /// take out of the app is not really an asset.
    struct Downloaded {
        let usd: URL
        let original: URL?
        var originalFormat: String { original?.pathExtension.uppercased() ?? "" }
    }

    func downloadModel(path: String, name: String) async throws -> Downloaded {
        guard let url = URL(string: path, relativeTo: Config.baseURL) else { throw APIError.badURL }

        let (temp, response) = try await session.download(from: url)
        try check(response, Data())

        let data = try Data(contentsOf: temp)
        try? FileManager.default.removeItem(at: temp)

        // The backend serves GLB today. RealityKit will not read it, so it is
        // converted here — which keeps the app working against the deployed
        // backend with nothing else running. USD passes straight through, so
        // this costs nothing once the backend's USD exporter ships.
        let base = FileManager.default.temporaryDirectory
        let stem = (name as NSString).deletingPathExtension

        let dest: URL
        let payload: Data
        var original: URL?

        if GLBConverter.isGLTF(data) {
            dest = base.appendingPathComponent("\(stem).usda")
            payload = Data(try GLBConverter.usda(from: data).utf8)

            // Keep what the backend actually sent, for export.
            let kept = base.appendingPathComponent("\(stem).glb")
            try? FileManager.default.removeItem(at: kept)
            try? data.write(to: kept)
            original = FileManager.default.fileExists(atPath: kept.path) ? kept : nil
        } else {
            let suffix = try Self.usdExtension(of: data, urlHint: url.pathExtension)
            dest = base.appendingPathComponent("\(stem).\(suffix)")
            payload = data
        }

        try? FileManager.default.removeItem(at: dest)
        try payload.write(to: dest)
        return Downloaded(usd: dest, original: original)
    }

    static func usdExtension(of data: Data, urlHint: String) throws -> String {
        let head = data.prefix(8)

        if head.starts(with: Data("#usda".utf8))    { return "usda" }
        if head.starts(with: Data("PXR-USDC".utf8)) { return "usdc" }
        if head.starts(with: Data([0x50, 0x4B]))    { return "usdz" }

        if ["usda", "usdc", "usdz"].contains(urlHint) { return urlHint }

        throw APIError.unsupportedFormat(urlHint.isEmpty ? "an unrecognised file" : ".\(urlHint)")
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        // FastAPI puts the useful part in "detail".
        var detail = String(decoding: data, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["detail"] as? String {
            detail = message
        }
        throw APIError.badStatus(http.statusCode, String(detail.prefix(300)))
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
