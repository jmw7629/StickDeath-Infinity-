import SwiftUI

/// Studio chrome tokens from the ArtCraft PhotoCraft "Studio (Dark)" theme
/// (github.com/storytold/photocraft crates/ui-egui/src/theme.rs, MIT OR
/// Apache-2.0; see Resources/Licenses/ArtCraft-NOTICE.txt). PhotoCraft's violet
/// accent is replaced by StickDeath red so the brand identity is unchanged.
enum StudioCraftTheme {
    // Surfaces
    static let chrome = Color(hex: "141415")
    static let canvas = Color(hex: "0E0E0F")
    static let canvasDot = Color(hex: "2E2E32")
    static let dock = Color(hex: "111112")
    static let card = Color(hex: "1A1A1C")
    static let cardBorder = Color(hex: "28282C")
    static let field = Color(hex: "232326")
    static let fieldBorder = Color(hex: "343439")
    static let hover = Color(hex: "2C2C30")
    static let pressed = Color(hex: "38383E")
    static let separator = Color(hex: "26262A")
    // Text and icons
    static let text = Color(hex: "ECECF0")
    static let textDim = Color(hex: "96969E")
    static let textFaint = Color(hex: "606068")
    static let icon = Color(hex: "C4C4CC")
    // Accent (StickDeath red in place of PhotoCraft violet) and states
    static let accent = Color.sdRed
    static let accentSoft = Color.sdRed.opacity(0.18)
    static let accentText = Color.sdStudioActionText
    static let danger = Color(hex: "F06060")
    static let warning = Color(hex: "F0BE5A")
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
