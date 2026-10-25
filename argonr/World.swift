//
//  World.swift
//  argonr
//
//  A whole playable world, written by Argon in one pass.
//
//  Behaviour is a name, not code: the model picks from a set this app already
//  implements, so a generated world cannot crash the thing simulating it. The
//  worst a bad world can do is play badly — which is exactly what the loop is
//  for.
//

import Foundation
import simd

struct World: Codable, Equatable {
    var name: String
    var pitch: String
    var ground: Ground
    var teams: [Team]
    var entities: [Entity]
    var victory: String?
    var notes: String?

    struct Ground: Codable, Equatable {
        var size: [Float]
        var color: [Float]?

        var width: Float { size.first ?? 0.8 }
        var depth: Float { size.count > 1 ? size[1] : 0.5 }
    }

    struct Team: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var color: [Float]
    }

    struct Entity: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var team: String
        var behaviour: Behaviour
        var hp: Float
        var damage: Float
        var range: Float
        var speed: Float
        var position: [Float]
        var meshes: [Mesh]

        var origin: SIMD3<Float> {
            SIMD3(position.first ?? 0, 0, position.count > 2 ? position[2] : 0)
        }
    }

    struct Mesh: Codable, Equatable {
        var name: String
        var color: [Float]
        var vertices: [[Float]]
        var faces: [[Int]]
    }

    /// Unknown values fall back rather than failing the whole world — a
    /// generated world should degrade, never collapse.
    enum Behaviour: String, Codable {
        case charge, hold, skirmish, ranged, `static`, wander

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Behaviour(rawValue: raw.lowercased()) ?? .charge
        }
    }

    var teamColors: [String: SIMD3<Float>] {
        Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0.color.rgb) })
    }

    var fighterCount: Int {
        entities.filter { $0.behaviour != .static && $0.team != "neutral" }.count
    }

    var vertexCount: Int {
        entities.reduce(0) { $0 + $1.meshes.reduce(0) { $0 + $1.vertices.count } }
    }
}

// MARK: - The loop

/// One line of the streamed loop. Every pass sends several.
struct LoopEvent: Decodable {
    let event: String
    let pass: Int?
    let score: Double?
    let verdict: String?
    let bugs: [Bug]?
    let playable: Bool?
    let avgSeconds: Double?
    let winners: [String: Int]?
    let frames: Int?
    let programChars: Int?
    let telemetry: Telemetry?
    let world: World?
    let history: [PassRecord]?
    let after: Telemetry?
    let detail: String?

    struct Bug: Decodable, Identifiable, Equatable {
        let severity: String
        let kind: String
        let evidence: String
        let cause: String?
        let fix: String?

        var id: String { kind + evidence }
        var isHigh: Bool { severity.lowercased() == "high" }
    }

    struct Telemetry: Decodable, Equatable {
        let runs: Int
        let resolved: Int
        let avgSeconds: Double?
        let winners: [String: Int]
        let playable: Bool
    }

    struct PassRecord: Decodable, Identifiable {
        let pass: Int
        let score: Double?
        let verdict: String?
        var id: Int { pass }
    }
}

/// What the UI shows for one pass of the loop.
struct LoopPass: Identifiable, Equatable {
    let index: Int
    var stage: Stage = .playing
    var score: Double?
    var verdict: String?
    var bugs: [LoopEvent.Bug] = []
    var playable: Bool?
    var avgSeconds: Double?
    var winners: [String: Int] = [:]
    var programChars: Int?

    var id: Int { index }

    enum Stage: String {
        case playing   = "Playing it"
        case rendering = "Rendering"
        case watching  = "Argon is watching"
        case fixing    = "Rewriting the world"
        case done      = "Done"
        case failed    = "Rewrite failed"
    }

    var scoreText: String { score.map { String(format: "%.2f", $0) } ?? "—" }

    var winnerText: String? {
        guard !winners.isEmpty else { return nil }
        return winners.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · ")
    }
}

extension Array where Element == Float {
    var rgb: SIMD3<Float> {
        SIMD3(count > 0 ? self[0] : 0.6,
              count > 1 ? self[1] : 0.6,
              count > 2 ? self[2] : 0.6)
    }
}
