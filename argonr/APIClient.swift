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
    func downloadModel(path: String, name: String) async throws -> URL {
        guard let url = URL(string: path, relativeTo: Config.baseURL) else { throw APIError.badURL }

        let (temp, response) = try await session.download(from: url)
        try check(response, Data())

        let suffix = try Self.usdExtension(of: temp, urlHint: url.pathExtension)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).\(suffix)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    static func usdExtension(of file: URL, urlHint: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8) ?? Data()

        if head.starts(with: Data("#usda".utf8))    { return "usda" }
        if head.starts(with: Data("PXR-USDC".utf8)) { return "usdc" }
        if head.starts(with: Data([0x50, 0x4B]))    { return "usdz" }

        if ["usda", "usdc", "usdz"].contains(urlHint) { return urlHint }

        if String(decoding: head.prefix(4), as: UTF8.self) == "glTF"
            || ["glb", "gltf"].contains(urlHint) {
            throw APIError.unsupportedFormat("glTF — ask the backend for format=usda")
        }
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
