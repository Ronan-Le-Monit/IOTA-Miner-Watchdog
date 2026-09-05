//
//  StatePresentation.swift
//  IOTA Watchdog
//
//  How each state looks in the menu bar and the menu.
//

import SwiftUI

extension WatchdogState {

    /// Short label for the menu header.
    var label: String {
        switch self {
        case .training: return "Training"
        case .otherPhase(let phase):
            switch phase {
            case .weightsUploading: return "Uploading weights"
            case .mergingPartitions: return "Merging partitions"
            case .training: return "Training"
            case .other: return "Running"
            }
        case .settling(let reason): return "Settling (\(reason))"
        case .waitingForSync(let until):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "Waiting for network sync (~\(formatter.string(from: until)))"
        case .stopped: return "Stopped"
        case .stoppedByUser: return "Stopped by you"
        case .frozen: return "Frozen"
        case .notProgressing: return "No progress"
        case .networkOutage: return "Network unreachable"
        case .runStalled(let hours):
            return String(format: "Run has stalled (%.0fh since it synced)", hours)
        case .needsAttention(let reason): return "Needs attention (\(reason))"
        case .paused: return "Paused"
        case .unknown: return "Checking…"
        }
    }

    /// Colour for the status dot.
    var tint: Color {
        switch self {
        case .training: return Theme.activeGreen
        case .otherPhase, .settling, .waitingForSync: return Color(hex: 0xFBBF24)
        case .stopped, .frozen, .needsAttention: return Theme.inactiveRed
        case .notProgressing, .runStalled: return Color(hex: 0xFB923C)
        case .networkOutage: return Color(hex: 0xFB923C)
        case .stoppedByUser, .paused, .unknown: return Theme.mutedText
        }
    }

    /// SF Symbol for the menu bar itself. Deliberately distinct shapes, not just colours, since
    /// the menu bar renders them monochrome by default.
    var symbol: String {
        switch self {
        case .training: return "cube.fill"
        case .otherPhase: return "cube"
        case .settling: return "clock"
        case .waitingForSync: return "clock.badge"
        case .stopped, .frozen: return "exclamationmark.triangle.fill"
        case .notProgressing: return "exclamationmark.circle"
        case .networkOutage: return "wifi.slash"
        case .runStalled: return "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        case .needsAttention: return "exclamationmark.octagon.fill"
        case .stoppedByUser: return "pause.circle"
        case .paused: return "pause.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Formats a duration as "3s", "12 min", "2h 5m".
func formatAge(_ seconds: TimeInterval?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
    if seconds < 60 { return "\(Int(seconds))s" }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
