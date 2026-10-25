//
//  APIClient.swift
//  argonr
//

import Foundation

enum APIError: LocalizedError {
    case badStatus(Int)
    case badURL
    case noInput

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Server returned \(code)"
        case .badURL:              "Bad server address"
        case .noInput:             "Need a photo or a hint first"
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
        c.timeoutIntervalForRequest = 120  // a 720p clip takes a moment to push
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    /// POST /generate — multipart: `video` (mp4) or `image` (jpeg), plus
    /// `hint` and `kind`. Returns the job id.
    func start(videoURL: URL?, imageJPEG: Data?, hint: String, kind: CaptureKind) async throws -> String {
        guard videoURL != nil || imageJPEG != nil || !hint.isEmpty else { throw APIError.noInput }

        let boundary = "argonr.\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        func file(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.append("Content-Type: \(mime)\r\n\r\n")
            body.append(data)
            body.append("\r\n")
        }

        field("hint", hint)
        field("kind", kind.serverValue)

        if let videoURL {
            file("video", "reference.mp4", "video/mp4", try Data(contentsOf: videoURL))
        } else if let imageJPEG {
            file("image", "reference.jpg", "image/jpeg", imageJPEG)
        }
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: Config.baseURL.appendingPathComponent("generate"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        try check(response)
        return try decoder.decode(StartResponse.self, from: data).jobId
    }

    /// POST /iterate/{job} — asks for one more pass on demand.
    func iterate(job: String) async throws {
        var req = URLRequest(url: Config.baseURL
            .appendingPathComponent("iterate")
            .appendingPathComponent(job))
        req.httpMethod = "POST"
        let (_, response) = try await session.data(for: req)
        try check(response)
    }

    /// GET /status/{job}
    func status(job: String) async throws -> JobStatus {
        let url = Config.baseURL
            .appendingPathComponent("status")
            .appendingPathComponent(job)
        let (data, response) = try await session.data(from: url)
        try check(response)
        return try decoder.decode(JobStatus.self, from: data)
    }

    /// Downloads the model to the temp dir, keeping whatever USD flavour the
    /// server sent. The extension matters — RealityKit dispatches on it and
    /// refuses a file that does not end in .usda / .usdc / .usdz.
    func downloadModel(path: String, job: String, iteration: Int) async throws -> URL {
        guard let url = URL(string: path, relativeTo: Config.baseURL) else { throw APIError.badURL }
        let (temp, response) = try await session.download(from: url)
        try check(response)

        let known = ["usda", "usdc", "usdz"]
        let suffix = known.contains(url.pathExtension) ? url.pathExtension : "usdz"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(job)-\(iteration).\(suffix)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
