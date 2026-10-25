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
    static let fallback = "https://argonr-backend-641066446400.us-central1.run.app"

    /// The deployed backend. Override in Settings to point at a laptop
    /// running `uvicorn app.main:app` — find its address with
    /// `ipconfig getifaddr en0`.
    /// Addresses that were defaults in earlier builds. A stored value wins
    /// over the compiled default, so without this a stale placeholder keeps
    /// being dialled long after the real one changed — which looks like a
    /// network failure rather than a wrong setting.
    private static let stale = ["http://192.168.1.100:8787",
                                "http://192.168.1.100:8000",
                                "http://10.1.63.55:8010"]

    static var serverBase: String {
        get {
            let stored = UserDefaults.standard.string(forKey: key)
            guard let stored, !stale.contains(stored) else { return fallback }
            return stored
        }
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

    /// Smallest surface the anchor will settle on. Proportional to what is
    /// being placed — otherwise a desk scene lands on a laptop lid.
    var minimumPlaneMeters: Float {
        switch self {
        case .object: 0.15
        case .scene:  0.5
        }
    }

    var serverValue: String {
        switch self {
        case .object: "object"
        case .scene:  "scene"
        }
    }
}
