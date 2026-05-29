// ═══════════════════════════════════════════════════════════════════
// Color+SD — Full StickDeath color system
// Matches: src/index.css CSS custom properties exactly
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

extension Color {
    // MARK: - Core Palette
    /// #0a0a0a — Main background
    static let sdBackground = Color(hex: "0A0A0A")
    /// #111111 — Surface / cards
    static let sdSurface = Color(hex: "111111")
    /// #1a1a1a — Elevated surface
    static let sdSurface2 = Color(hex: "1A1A1A")
    /// #222222 — Tertiary surface
    static let sdSurface3 = Color(hex: "222222")
    /// #1E1E1E — Surface light (for elevated elements)
    static let sdSurfaceLight = Color(hex: "1E1E1E")

    // MARK: - Red (Primary)
    /// #C80000 — Primary red
    static let sdRed = Color(hex: "C80000")
    /// #8B0000 — Dark red
    static let sdRedDeep = Color(hex: "8B0000")
    /// #FF1A1A — Bright red (highlights)
    static let sdRedBright = Color(hex: "FF1A1A")
    /// Primary gradient (red → darkRed)
    static let sdPrimaryGradient = LinearGradient(
        colors: [Color(hex: "C80000"), Color(hex: "8B0000")],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Text
    /// #e0e0e0 — Primary text
    static let sdTextPrimary = Color(hex: "E0E0E0")
    /// #999999 — Secondary text
    static let sdTextSecondary = Color(hex: "999999")
    /// #666666 — Muted text
    static let sdTextMuted = Color(hex: "666666")

    // MARK: - Borders
    /// #1f1f1f — Default border
    static let sdBorder = Color(hex: "1F1F1F")
    /// #2a2a2a — Light border
    static let sdBorderLight = Color(hex: "2A2A2A")

    // MARK: - Semantic
    /// #C80000 — Destructive / error
    static let sdDestructive = Color(hex: "C80000")
    /// #00C853 — Success green
    static let sdSuccess = Color(hex: "00C853")
    /// #FFD600 — Warning yellow
    static let sdWarning = Color(hex: "FFD600")

    // MARK: - Glow
    /// Red glow color for text-shadow effect
    static let sdGlowRed = Color(hex: "C80000")

    // MARK: - Hex Initializer
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            (r, g, b) = (Double((int >> 16) & 0xFF)/255, Double((int >> 8) & 0xFF)/255, Double(int & 0xFF)/255)
        case 8:
            (r, g, b) = (Double((int >> 16) & 0xFF)/255, Double((int >> 8) & 0xFF)/255, Double(int & 0xFF)/255)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - View Modifiers (Red Glow)
extension View {
    func sdRedGlow(radius: CGFloat = 12, opacity: Double = 0.5) -> some View {
        self.shadow(color: .sdGlowRed.opacity(opacity), radius: radius)
    }
}
