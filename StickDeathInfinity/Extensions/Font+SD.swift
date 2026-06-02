// ═══════════════════════════════════════════════════════════════════
// Font+SD — Typography system
// Matches: React CSS — Special Elite for headings, system for body
// Fonts: "Special Elite" (Google Fonts), "Anybody" (body alt)
// NOTE: Add SpecialElite-Regular.ttf to the Xcode project bundle
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

extension Font {
    /// Special Elite — the signature SD∞ typewriter font
    static func specialElite(_ size: CGFloat) -> Font {
        .custom("SpecialElite-Regular", size: size)
    }

    /// Anybody — body text alternative
    static func anybody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Anybody-Regular", size: size)
    }
}
