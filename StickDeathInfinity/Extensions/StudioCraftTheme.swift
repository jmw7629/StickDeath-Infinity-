import SwiftUI

/// Studio chrome tokens. Layout metrics follow the ArtCraft PhotoCraft
/// "Studio (Dark)" theme (github.com/storytold/photocraft
/// crates/ui-egui/src/theme.rs, MIT OR Apache-2.0; see
/// Resources/Licenses/ArtCraft-NOTICE.txt). Ink, paper and punchy red extend
/// the SDI desktop into native panels without changing the editor workspace,
/// its single snapping toolbar or contextual settings behavior.
enum StudioCraftTheme {
    // Charcoal surfaces keep existing white text legible. Strong edges and
    // square corners echo the desktop's 1990s window chrome.
    static let chrome = Color(hex: "202021")
    static let canvas = Color(hex: "0D0D14")
    static let canvasDot = Color(hex: "2A2A3A")
    static let dock = Color(hex: "252526")
    static let card = Color(hex: "2D2C2B")
    static let cardBorder = Color(hex: "BDB9B3").opacity(0.55)
    static let field = Color(hex: "171718")
    static let fieldBorder = Color(hex: "BDB9B3").opacity(0.7)
    static let hover = Color(hex: "41403C")
    static let pressed = Color(hex: "393833")
    static let separator = Color(hex: "BDB9B3").opacity(0.35)
    // Text and icons (reference greys: white, #9CA3AF, #6B7280)
    static let text = Color(hex: "EFEAE0")
    static let textDim = Color(hex: "C8C3BA")
    static let textFaint = Color(hex: "A5A098")
    static let icon = Color(hex: "EFEAE0")
    // Filled controls retain white text; use the lighter red for text actions.
    static let accent = Color(hex: "B91F30")
    static let accentSoft = Color(hex: "FF6971").opacity(0.18)
    static let accentText = Color(hex: "FF9097")
    static let danger = Color(hex: "DC2626")
    static let warning = Color(hex: "EAB308")
    // SoundCraft mixer states
    static let solo = Color(hex: "DEC434")
    static let mute = Color(hex: "E89428")
    // PhotoCraft Studio radii and spacing
    static let radiusSmall: CGFloat = 1
    static let radius: CGFloat = 2
    static let radiusLarge: CGFloat = 3
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
