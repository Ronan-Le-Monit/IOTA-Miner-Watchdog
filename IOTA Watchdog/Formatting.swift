//
//  Formatting.swift
//  IOTA_Miner_Dashboard
//
//  Pure, unit-testable formatting helpers for stats, uptime and data age.
//

import Foundation

enum StatFormat {
    /// Compact number formatting:
    /// `< 1,000` → plain integer; `>= 1,000` → `1.5k` (one decimal);
    /// `>= 1,000,000` → `1.50M` (two decimals).
    static func compact(_ value: Double) -> String {
        let v = abs(value)
        if v >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        } else if v >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        } else {
            return String(format: "%.0f", value)
        }
    }

    static func compact(_ value: Int) -> String {
        compact(Double(value))
    }

    /// Uptime as `Xh Ym`, e.g. `21h 8m`. Negative values are clamped to zero.
    static func uptime(seconds: Int) -> String {
        let s = max(0, seconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    /// Data-age label in whole minutes only.
    static func dataAge(minutes: Int) -> String {
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1 min ago" }
        return "\(minutes) mins ago"
    }

    /// Whole minutes elapsed between two dates (never negative).
    static func minutesElapsed(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }
}
