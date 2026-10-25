//
//  WorldAPI.swift
//  argonr
//

import Foundation

struct WorldAPI {
    static let shared = WorldAPI()

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        // One decode writes fifty thousand characters of Python. It takes
        // minutes, not seconds.
        c.timeoutIntervalForRequest = 900
        return URLSession(configuration: c)
    }

    /// POST /world — one pass, a whole playable world.
    func build(prompt: String) async throws -> World {
        var request = URLRequest(url: Config.baseURL.appendingPathComponent("world"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])

        let (data, response) = try await session.data(for: request)
        try check(response, data)

        struct Wrapper: Decodable { let world: World }
        return try decoder.decode(Wrapper.self, from: data).world
    }

    /// POST /world/iterate/stream — Argon plays its own game and fixes it,
    /// reporting each step as it happens. Newline-delimited JSON, because a
    /// pass takes a couple of minutes and watching the score climb is the
    /// point.
    func iterate(world: World, goal: String, passes: Int) -> AsyncThrowingStream<LoopEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: Config.baseURL
                        .appendingPathComponent("world")
                        .appendingPathComponent("iterate")
                        .appendingPathComponent("stream"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let payload: [String: Any] = [
                        "world": try JSONSerialization.jsonObject(
                            with: JSONEncoder().encode(world)),
                        "goal": goal,
                        "passes": passes,
                        "runs": 5,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        throw APIError.badStatus(http.statusCode, "Loop failed")
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        if let event = try? decoder.decode(LoopEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        var detail = String(decoding: data, as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["detail"] as? String {
            detail = message
        }
        throw APIError.badStatus(http.statusCode, String(detail.prefix(300)))
    }
}
