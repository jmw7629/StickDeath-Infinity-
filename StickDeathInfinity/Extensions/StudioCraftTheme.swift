import SwiftUI

/// Studio chrome tokens. Layout metrics follow the ArtCraft PhotoCraft
/// "Studio (Dark)" theme (github.com/storytold/photocraft
/// crates/ui-egui/src/theme.rs, MIT OR Apache-2.0; see
/// Resources/Licenses/ArtCraft-NOTICE.txt); colours follow the SD∞ reference
/// design so every Studio panel shares the app's dark-navy chrome and red accent.
enum StudioCraftTheme {
    // Surfaces: the SD∞ reference design's dark-navy chrome (Studio chrome
    // #12121A, dock #14141E, cards #1A1A28, fields #1A1A24, canvas backdrop
    // #0D0D14) instead of PhotoCraft's neutral greys, so the layer and audio
    // panels match the rest of the app.
    static let chrome = Color(hex: "12121A")
    static let canvas = Color(hex: "0D0D14")
    static let canvasDot = Color(hex: "2A2A3A")
    static let dock = Color(hex: "14141E")
    static let card = Color(hex: "1A1A28")
    static let cardBorder = Color.white.opacity(0.08)
    static let field = Color(hex: "1A1A24")
    static let fieldBorder = Color.white.opacity(0.15)
    static let hover = Color(hex: "22222F")
    static let pressed = Color(hex: "2A2A3A")
    static let separator = Color.white.opacity(0.08)
    // Text and icons (reference greys: white, #9CA3AF, #6B7280)
    static let text = Color.white
    static let textDim = Color(hex: "9CA3AF")
    static let textFaint = Color(hex: "6B7280")
    static let icon = Color(hex: "D4D4D8")
    // Accent: the reference Studio red (#E03030) and states
    static let accent = Color(hex: "E03030")
    static let accentSoft = Color(hex: "E03030").opacity(0.18)
    static let accentText = Color.sdStudioActionText
    static let danger = Color(hex: "DC2626")
    static let warning = Color(hex: "EAB308")
    // SoundCraft mixer states
    static let solo = Color(hex: "DEC434")
    static let mute = Color(hex: "E89428")
    // PhotoCraft Studio radii and spacing
    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 8
    static let radiusLarge: CGFloat = 12
    static let rowGap: CGFloat = 4
    static let itemSpacing: CGFloat = 8
    /// PhotoCraft Studio layer row metrics.
    static let layerRowHeight: CGFloat = 46
    static let layerThumbnail: CGFloat = 34
}

extension View {
    /// PhotoCraft Studio card: card surface, 1 pt border and large radius.
    func studioCraftCard(selected: Bool = false) -> some View {
        self.background(selected ? StudioCraftTheme.hover : StudioCraftTheme.card)
            .overlay(RoundedRectangle(cornerRadius: StudioCraftTheme.radius)
                .stroke(selected ? StudioCraftTheme.fieldBorder : StudioCraftTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
    }
}
