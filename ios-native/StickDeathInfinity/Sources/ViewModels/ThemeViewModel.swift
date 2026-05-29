// ═══════════════════════════════════════════════════════════════════
// ThemeViewModel — Theme state
// Matches: src/contexts/ThemeContext.tsx
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@MainActor
final class ThemeViewModel: ObservableObject {
    @Published var isDarkMode = true
    @Published var accentColor: Color = .sdRed
}
