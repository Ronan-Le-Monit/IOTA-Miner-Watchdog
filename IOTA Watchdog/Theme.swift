//
//  Theme.swift
//  IOTA_Miner_Dashboard
//
//  Color palette and shared style constants for the dark, card-based look.
//

import SwiftUI

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `0xE8EEF7`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

enum Theme {
    /// Very dark navy screen background.
    static let background = Color(red: 16 / 255, green: 20 / 255, blue: 30 / 255)

    // Card
    static let cardFill = Color.white.opacity(0.035)
    static let cardBorder = Color.white.opacity(0.06)
    static let cardCornerRadius: CGFloat = 12

    // Text
    static let primaryText = Color(hex: 0xE8EEF7)
    static let mutedText = Color(hex: 0x6B7A90)
    static let secondaryMuted = Color(hex: 0x8AA0BB)
    static let rankText = Color.white
    static let titleText = Color(hex: 0x9FB3CC)

    // Status
    static let activeGreen = Color(hex: 0x4ADE80)
    static let inactiveRed = Color(hex: 0xF87171)
}
