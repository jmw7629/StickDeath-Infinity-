// ThemeManager.swift
// Global theming — matches web design exactly
// BG: #0a0a0f, Cards: #111118, Surface: #1a1a24, Border: #2a2a3a

import SwiftUI

@MainActor
class ThemeManager: ObservableObject {
    @Published var accentColor: Color = .red

    // ── Exact web colors ──
    static let background = Color(hex: "#0a0a0f")
    static let card = Color(hex: "#111118")
    static let surface = Color(hex: "#1a1a24")
    static let surfaceLight = Color(hex: "#111118")
    static let border = Color(hex: "#2a2a3a")
    static let borderHover = Color(hex: "#3a3a4a")
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#9090a8")
    static let textMuted = Color(hex: "#72728a")
    static let textDim = Color(hex: "#5a5a6e")
    static let brand = Color(hex: "#dc2626")
    static let brandDark = Color(hex: "#991b1b")
    static let danger = Color(hex: "#FF4444")
    static let success = Color.green
    static let flipaclipPink = Color(hex: "#ff2d55")
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
