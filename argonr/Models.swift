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
        case "generating": "Modelling from your capture"
        case "rendering":  "Rendering turntable"
        case "watching":   "Argon is comparing to your capture"
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
    /// How closely the render matches the reference, 0–1. Nil when there was
    /// nothing to match against (a hint-only job).
    let matchScore: Double?
    /// For scenes: how many distinct objects the model contains. Nil for a
    /// single-object job.
    let objectCount: Int?
    /// Server path, e.g. "/model/abc123/2.usdz". Nil until the export lands.
    let modelPath: String?
    /// One line for the history strip: "normals flipped -> fixed"
    let headline: String?
    let defects: [Defect]

    var id: Int { index }

    init(index: Int, score: Double, matchScore: Double?, objectCount: Int?,
         modelPath: String?, headline: String?, defects: [Defect]) {
        self.index = index
        self.score = score
        self.matchScore = matchScore
        self.objectCount = objectCount
        self.modelPath = modelPath
        self.headline = headline
        self.defects = defects
    }

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
