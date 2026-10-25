//
//  Config.swift
//  argonr
//
//  Where the laptop running loop.py lives. Editable from the prompt screen
//  so you can fix it on the venue wifi without a rebuild.
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
