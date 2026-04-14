// ThemeManager.swift
// Global theming — bold, high-contrast dark theme with orange accent
// v2: Higher contrast surfaces, visible text fields, Bebas Neue headlines

import SwiftUI

class ThemeManager: ObservableObject {
    @Published var accentColor: Color = .orange

    // Colors — high contrast for visibility
    static let background = Color(hex: "#0A0A0A")
    static let surface = Color(hex: "#1C1C1E")          // Brighter surface for fields
    static let surfaceLight = Color(hex: "#2C2C2E")      // Even brighter for hover/active
    static let border = Color(hex: "#48484A")             // Visible borders
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#AEAEB2")      // Brighter secondary text
    static let brand = Color.orange
    static let danger = Color.red
    static let success = Color.green

    // Input field style — bright border + background so you can see where to type
    static let inputBackground = Color(hex: "#1C1C1E")
    static let inputBorder = Color(hex: "#636366")        // Visible border on fields
    static let inputFocusBorder = Color.orange             // Orange when focused

    // Headline font (Bebas Neue — must be added to project bundle)
    // Fallback to system heavy if not bundled yet
    static func headline(size: CGFloat) -> Font {
        .custom("BebasNeue-Regular", size: size, relativeTo: .largeTitle)
    }

    static func headlineBold(size: CGFloat) -> Font {
        .custom("BebasNeue-Bold", size: size, relativeTo: .largeTitle)
    }
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

// MARK: - Reusable Input Field Style
struct StickDeathTextField: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding()
            .background(ThemeManager.inputBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? ThemeManager.inputFocusBorder : ThemeManager.inputBorder, lineWidth: isFocused ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .tint(.orange)  // Orange cursor
            .focused($isFocused)
    }
}

extension View {
    func stickDeathTextField() -> some View {
        modifier(StickDeathTextField())
    }
}
