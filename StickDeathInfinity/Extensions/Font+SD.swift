// ═══════════════════════════════════════════════════════════════════
// Font+SD — Typography system
// Matches: React CSS — Special Elite for headings, system for body
// Font: "Special Elite" (Google Fonts). SpecialElite-Regular.ttf is bundled
// with the native application; no other custom face is bundled or referenced.
//
// Dynamic Type contract (#264, docs/ACCESSIBILITY_DYNAMIC_TYPE.md):
//   * `.specialElite(size, relativeTo:)` already scales with the user's text
//     size through `Font.custom(_:size:relativeTo:)`.
//   * System fonts written as `.font(.system(size: N))` do NOT scale. New and
//     migrated views use `.sdScaledSystemFont(N, …)` below, which scales N
//     relative to a text style through `@ScaledMetric`, so the measured
//     layouts keep their proportions while honouring accessibility sizes.
//   * Dense Studio chrome (toolbar, layer rows, timeline) may cap growth with
//     `.sdStudioDynamicTypeRange()` so the canvas never collapses; the cap is
//     `.accessibility2`, never below the standard sizes.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

extension Font {
    /// Special Elite — the signature SD∞ typewriter font
    static func specialElite(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("SpecialElite-Regular", size: size, relativeTo: style)
    }
}

/// Applies a system font whose point size follows Dynamic Type.
///
/// `@ScaledMetric` scales `size` with the environment's content size category
/// relative to `style`, exactly as `Font.custom(_:size:relativeTo:)` does for
/// the bundled typewriter face, so a 16 pt label becomes about 21 pt at the
/// first accessibility size instead of staying fixed.
struct SDScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

/// Scales one layout metric (icon box, row height, minimum target) with
/// Dynamic Type so fixed-size frames grow with their text instead of clipping.
struct SDScaledFrame: ViewModifier {
    @ScaledMetric private var width: CGFloat
    @ScaledMetric private var height: CGFloat
    private let alignment: Alignment

    init(width: CGFloat, height: CGFloat, alignment: Alignment, relativeTo style: Font.TextStyle) {
        _width = ScaledMetric(wrappedValue: width, relativeTo: style)
        _height = ScaledMetric(wrappedValue: height, relativeTo: style)
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        content.frame(width: width, height: height, alignment: alignment)
    }
}

extension View {
    /// Dynamic Type–aware replacement for `.font(.system(size:weight:design:))`.
    func sdScaledSystemFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                            relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(SDScaledSystemFont(size: size, weight: weight, design: design, relativeTo: style))
    }

    /// A fixed frame that scales with Dynamic Type (icon boxes, thumbnails).
    func sdScaledFrame(width: CGFloat, height: CGFloat, alignment: Alignment = .center,
                       relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(SDScaledFrame(width: width, height: height, alignment: alignment, relativeTo: style))
    }

    /// Apple's minimum touch target. Use on icon-only controls whose glyph is
    /// smaller than 44 pt; `contentShape` keeps the whole area tappable.
    func sdMinimumTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }

    /// Dense Studio chrome follows Dynamic Type up to the second accessibility
    /// size, so the canvas and the single floating toolbar keep their room.
    /// Never applied to reading surfaces such as Spatter, help or settings.
    func sdStudioDynamicTypeRange() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
