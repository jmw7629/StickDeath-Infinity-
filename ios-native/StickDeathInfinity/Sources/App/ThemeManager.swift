// ThemeManager.swift
// Global theming

import SwiftUI

class ThemeManager: ObservableObject {
    @Published var accentColor: Color = .orange

    // Colors
    static let background = Color(hex: "#0A0A0A")
    static let surface = Color(hex: "#141414")
    static let surfaceLight = Color(hex: "#1E1E1E")
    static let border = Color(hex: "#2A2A2A")
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#888888")
    static let brand = Color.orange
    static let danger = Color.red
    static let success = Color.green
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            (r, g, b) = (Double((int >> 16) & 0xFF) / 255, Double((int >> 8) & 0xFF) / 255, Double(int & 0xFF) / 255)
        default:
            (r, g, b) = (1, 1, 1)
        }
        self.init(red: r, green: g, blue: b)
    }
}
