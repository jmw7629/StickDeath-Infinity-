import Foundation

// Layer model ported from the ArtCraft PhotoCraft editor
// (github.com/storytold/photocraft, MIT OR Apache-2.0; see
// Resources/Licenses/ArtCraft-NOTICE.txt): crates/color/src/blend.rs,
// crates/doc/src/lib.rs (LabelColor) and crates/ui-egui/src/theme.rs.

/// PhotoCraft's layer blend modes, in its menu order, restricted to the 18
/// modes the native SwiftUI/Core Graphics compositor draws directly. Dissolve,
/// Darker/Lighter Color, Vivid/Linear/Pin Light, Hard Mix, Subtract and Divide
/// need PhotoCraft's CPU compositor and are deliberately not offered.
/// Raw values are lowercase so historical case-insensitive lookups still match.
enum StudioLayerBlendMode: String, Codable, CaseIterable, Sendable {
    case normal
    case darken, multiply
    case colorBurn = "color-burn", linearBurn = "linear-burn"
    case lighten, screen
    case colorDodge = "color-dodge", linearDodge = "linear-dodge"
    case overlay
    case softLight = "soft-light", hardLight = "hard-light"
    case difference, exclusion
    case hue, saturation, color, luminosity

    /// The six modes every historical Studio build renders and exports.
    static let historical: Set<StudioLayerBlendMode> = [.normal, .multiply, .screen, .overlay, .darken, .lighten]
    /// First schema able to store the PhotoCraft modes beyond the historical six.
    static let extendedSchemaVersion = 34

    /// Case-insensitive lookup; unknown legacy strings stay unrecognised (nil)
    /// and keep the historical "draw as Normal" behaviour.
    init?(stored: String) { self.init(rawValue: stored.lowercased()) }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .darken: return "Darken"
        case .multiply: return "Multiply"
        case .colorBurn: return "Color Burn"
        case .linearBurn: return "Linear Burn"
        case .lighten: return "Lighten"
        case .screen: return "Screen"
        case .colorDodge: return "Color Dodge"
        case .linearDodge: return "Linear Dodge (Add)"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        case .difference: return "Difference"
        case .exclusion: return "Exclusion"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .color: return "Color"
        case .luminosity: return "Luminosity"
        }
    }

    /// PhotoCraft groups the menu by effect; a divider precedes each group.
    var group: Int {
        switch self {
        case .normal: return 0
        case .darken, .multiply, .colorBurn, .linearBurn: return 1
        case .lighten, .screen, .colorDodge, .linearDodge: return 2
        case .overlay, .softLight, .hardLight: return 3
        case .difference, .exclusion: return 4
        case .hue, .saturation, .color, .luminosity: return 5
        }
    }

    var isExtended: Bool { !Self.historical.contains(self) }

    /// Display title for any stored value, including unknown legacy strings.
    static func title(forStored value: String) -> String {
        Self(stored: value)?.title ?? "Normal"
    }

    /// PhotoCraft's separable CPU reference (crates/color/src/blend.rs) for one
    /// straight-alpha channel in 0...1. Used to verify the native compositor.
    /// Non-separable modes (hue … luminosity) return nil.
    func separable(backdrop cb: Double, source cs: Double) -> Double? {
        switch self {
        case .normal: return cs
        case .darken: return min(cb, cs)
        case .multiply: return cb * cs
        case .colorBurn: return cb >= 1 ? 1 : cs <= 0 ? 0 : 1 - min(1, (1 - cb) / cs)
        case .linearBurn: return max(0, cb + cs - 1)
        case .lighten: return max(cb, cs)
        case .screen: return cb + cs - cb * cs
        case .colorDodge: return cb <= 0 ? 0 : cs >= 1 ? 1 : min(1, cb / (1 - cs))
        case .linearDodge: return min(1, cb + cs)
        case .overlay: return Self.hardLight(cs, cb)
        case .softLight:
            // W3C/Core Graphics soft light. PhotoCraft's Photoshop variant differs
            // only in the upper half; the native compositor implements this one.
            if cs <= 0.5 { return cb - (1 - 2 * cs) * cb * (1 - cb) }
            let d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : cb.squareRoot()
            return cb + (2 * cs - 1) * (d - cb)
        case .hardLight: return Self.hardLight(cb, cs)
        case .difference: return abs(cb - cs)
        case .exclusion: return cb + cs - 2 * cb * cs
        case .hue, .saturation, .color, .luminosity: return nil
        }
    }
    private static func hardLight(_ cb: Double, _ cs: Double) -> Double {
        if cs <= 0.5 { return cb * 2 * cs }
        let s = 2 * cs - 1
        return cb + s - cb * s
    }
}

/// PhotoCraft layer label colours (LabelColor display order), stored as the
/// existing optional `colorLabel` hex string.
enum StudioLayerLabelColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, seafoam, blue, indigo, magenta, fuchsia, violet, gray

    var title: String { rawValue.capitalized }
    /// Swatch colour from PhotoCraft's theme.
    var hex: String {
        switch self {
        case .red: return "#FC5D5B"
        case .orange: return "#F79744"
        case .yellow: return "#DCD64B"
        case .green: return "#85DC6A"
        case .seafoam: return "#1C8488"
        case .blue: return "#78ADF6"
        case .indigo: return "#544BE7"
        case .magenta: return "#CC1A7E"
        case .fuchsia: return "#B014C0"
        case .violet: return "#9176D5"
        case .gray: return "#9C9C9C"
        }
    }
    /// Darker tint PhotoCraft paints behind the layer's visibility cell.
    var cellHex: String {
        switch self {
        case .red: return "#9F2F30"
        case .orange: return "#934F0C"
        case .yellow: return "#99780C"
        case .green: return "#4E712E"
        case .seafoam: return "#0B544F"
        case .blue: return "#415B87"
        case .indigo: return "#36348E"
        case .magenta: return "#981B51"
        case .fuchsia: return "#710F74"
        case .violet: return "#5D3F8E"
        case .gray: return "#575757"
        }
    }
    init?(hex: String?) {
        guard let hex = hex?.uppercased() else { return nil }
        guard let match = Self.allCases.first(where: { $0.hex == hex }) else { return nil }
        self = match
    }
}
