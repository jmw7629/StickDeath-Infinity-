// ═══════════════════════════════════════════════════════════════════
// Color+Hex — Hex color initializer used by Spatter commands
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

extension Color {
    /// Initialize a Color from a hex string (e.g. "#FF0000" or "FF0000").
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexString = clean.hasPrefix("#") ? String(clean.dropFirst()) : clean

        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)

        let r, g, b: Double
        if hexString.count == 6 {
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8) & 0xFF) / 255.0
            b = Double(rgb & 0xFF) / 255.0
        } else {
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}
