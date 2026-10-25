//
//  APIClient.swift
//  argonr
//

import Foundation

enum APIError: LocalizedError {
    case badStatus(Int)
    case badURL
    case noInput
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Server returned \(code)"
        case .badURL:              "Bad server address"
        case .noInput:             "Need a photo or a hint first"
        case .unsupportedFormat(let what): "The server sent \(what)"
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

    /// POST /iterate/{job} — another pass, optionally steered by the user.
    /// An empty instruction means "keep improving on your own judgement".
    func iterate(job: String, instruction: String) async throws {
        var req = URLRequest(url: Config.baseURL
            .appendingPathComponent("iterate")
            .appendingPathComponent(job))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["instruction": instruction])

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

    /// Fetches the model named by `model_path`.
    ///
    /// That path may be relative to the loop server, or a fully-qualified URL
    /// somewhere else entirely — cloud storage, a CDN, a signed link. Both
    /// work: an absolute string ignores the base.
    ///
    /// The file is saved with a USD extension because RealityKit dispatches on
    /// it. We do not trust the URL to carry one — signed links often end in a
    /// query string, and object keys frequently have no extension at all — so
    /// the format is sniffed from the bytes, which cannot lie.
    func downloadModel(path: String, job: String, iteration: Int) async throws -> URL {
        guard let url = URL(string: path, relativeTo: Config.baseURL) else { throw APIError.badURL }

        let (temp, response) = try await session.download(from: url)
        try check(response)

        let suffix = try Self.usdExtension(of: temp, urlHint: url.pathExtension)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(job)-\(iteration).\(suffix)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    /// Identifies the USD flavour from the file's leading bytes.
    static func usdExtension(of file: URL, urlHint: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 8) ?? Data()

        if head.starts(with: Data("#usda".utf8))    { return "usda" }
        if head.starts(with: Data("PXR-USDC".utf8)) { return "usdc" }
        if head.starts(with: Data([0x50, 0x4B]))    { return "usdz" }   // zip

        // Nothing recognisable. If the URL claimed a USD extension, take its
        // word; otherwise say plainly what arrived, because the usual cause is
        // a glTF or OBJ from the other half of the pipeline.
        if ["usda", "usdc", "usdz"].contains(urlHint) { return urlHint }

        let sniff = String(decoding: head.prefix(4), as: UTF8.self)
        if sniff == "glTF" || urlHint == "glb" || urlHint == "gltf" {
            throw APIError.unsupportedFormat("glTF — the viewer needs USD (.usda, .usdc or .usdz)")
        }
        throw APIError.unsupportedFormat(urlHint.isEmpty ? "an unrecognised file" : ".\(urlHint)")
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
