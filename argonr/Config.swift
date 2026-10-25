//
//  Config.swift
//  argonr
//
//  Where the laptop running the loop lives. Editable from the capture screen
//  so you can fix it on venue wifi without a rebuild.
//

import Foundation

enum Config {
    private static let key = "argonr.serverBase"
    static let fallback = "http://192.168.1.100:8787"

    /// Find yours with:  ipconfig getifaddr en0
    static var serverBase: String {
        get { UserDefaults.standard.string(forKey: key) ?? fallback }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var baseURL: URL { URL(string: serverBase) ?? URL(string: fallback)! }

    /// How often the phone asks the laptop what the loop is doing.
    static let pollSeconds: UInt64 = 1
}

/// What the user captured, which decides how big the result lands in AR and
/// what the server is being asked to build.
enum CaptureKind {
    case object      // one photo, one thing
    case scene       // an orbit video of several things on a surface

    /// Longest side the result is scaled to when placed. A desk scene needs
    /// room; a single mug does not.
    var fitMeters: Float {
        switch self {
        case .object: 0.3
        case .scene:  0.8
        }
    }

    var serverValue: String {
        switch self {
        case .object: "object"
        case .scene:  "scene"
        }
    }
}
