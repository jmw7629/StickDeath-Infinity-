// ═══════════════════════════════════════════════════════════════════
// Font+SD — Typography system
// Matches: React CSS — Special Elite for headings, system for body
// Font: "Special Elite" (Google Fonts). SpecialElite-Regular.ttf is bundled
// with the native application; no other custom face is bundled or referenced.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

extension Font {
    /// Special Elite — the signature SD∞ typewriter font
    static func specialElite(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("SpecialElite-Regular", size: size, relativeTo: style)
    }
}
