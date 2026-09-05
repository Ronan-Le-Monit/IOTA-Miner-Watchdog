//
//  AppLinks.swift
//  IOTA Watchdog
//
//  Outward-facing links. Kept in one place so releasing the app is a one-line change.
//

import Foundation

enum AppLinks {

    /// Where "Support this project" points. Set this to your donation page before releasing;
    /// while it is nil the menu item is hidden rather than showing a dead link.
    ///
    /// Examples:
    ///   URL(string: "https://github.com/sponsors/<you>")
    ///   URL(string: "https://ko-fi.com/<you>")
    ///   URL(string: "https://buymeacoffee.com/<you>")
    static let donation: URL? = nil

    /// Project home, used by "Report an issue" when set.
    static let repository = URL(string: "https://github.com/Ronan-Le-Monit/IOTA-Miner-Watchdog")
}
