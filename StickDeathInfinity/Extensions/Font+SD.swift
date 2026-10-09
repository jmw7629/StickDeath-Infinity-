// ═══════════════════════════════════════════════════════════════════
// Font+SD — Typography system
// Matches: React CSS — Special Elite for headings, system for body
// Fonts: "Special Elite" (Google Fonts), "Anybody" (body alt)
// SpecialElite-Regular.ttf is bundled with the native application.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

extension Font {
    /// Special Elite — the signature SD∞ typewriter font
    static func specialElite(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("SpecialElite-Regular", size: size, relativeTo: style)
    }

    /// Anybody — body text alternative
    static func anybody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Anybody-Regular", size: size)
    }
}
