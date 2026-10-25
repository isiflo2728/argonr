//
//  Models.swift
//  argonr
//
//  The JSON contract with the loop server. Server speaks snake_case; the
//  decoder converts. This file is the only coupling between the two halves —
//  change it and the server's schema together, or neither.
//

import Foundation

struct StartResponse: Decodable {
    let jobId: String
}

struct JobStatus: Decodable {
    /// generating | rendering | watching | critiquing | fixing | done | error
    let stage: String
    let iteration: Int
    let totalIterations: Int
    let done: Bool
    let iterations: [IterationInfo]
    let error: String?

    var stageLabel: String {
        switch stage {
        case "generating": "Modelling from your photo"
        case "rendering":  "Rendering turntable"
        case "watching":   "Argon is comparing to your photo"
        case "critiquing": "Finding what is wrong"
        case "fixing":     "Applying fixes"
        case "done":       "Finished"
        case "error":      "Failed"
        default:           stage.capitalized
        }
    }
}

struct IterationInfo: Decodable, Identifiable, Equatable {
    let index: Int
    /// Overall rubric score, 0–1.
    let score: Double
    /// How closely the render matches the reference photo, 0–1. Nil for a
    /// text-only job, where there is nothing to match against.
    let matchScore: Double?
    /// Server path, e.g. "/model/abc123/2.usdz". Nil until the export lands.
    let modelPath: String?
    /// One line for the history strip: "normals flipped -> fixed"
    let headline: String?
    let defects: [Defect]

    var id: Int { index }

    static func == (a: IterationInfo, b: IterationInfo) -> Bool {
        a.index == b.index && a.score == b.score && a.modelPath == b.modelPath
    }
}

struct Defect: Decodable, Identifiable, Equatable {
    let id: String
    let rubric: String
    let severity: String
    let evidence: String
    let cause: String?
    let fix: String?

    var isHigh: Bool { severity.lowercased() == "high" }
}
