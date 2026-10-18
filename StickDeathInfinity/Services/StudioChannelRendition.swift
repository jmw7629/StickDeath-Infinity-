import Foundation

// MARK: - Official-channel rendition mark (#241)
//
// Only the copy prepared for the official SDI channel carries the small
// watercolor SDI mark in its lower-right safe area. The editable project, its
// originals and every personal export stay unmarked. The artwork is the
// owner-approved, rights-cleared transparent logo installed in the app's asset
// catalogue under `markAssetName`; it is not generated or substituted. When it
// is missing, preparation of the channel copy is refused with a truthful message.
// This file is Foundation-only placement and contrast math; the compositing that
// uses it lives in StudioExportService.

enum StudioChannelRendition {
    /// Asset-catalogue name of the owner-supplied transparent watercolor mark.
    static let markAssetName = "SDIChannelWatercolorMark"

    enum Purpose: Equatable {
        case personalExport, channelCopy
        /// Personal exports never carry the channel mark, whatever their plan.
        var carriesChannelMark: Bool { self == .channelCopy }
    }

    enum Orientation: String, Equatable {
        case portrait, landscape, square
        /// Within 5% of square counts as square.
        init(width: Int, height: Int) {
            let w = Double(max(1, width)), h = Double(max(1, height))
            if h > w * 1.05 { self = .portrait } else if w > h * 1.05 { self = .landscape } else { self = .square }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case markUnavailable, markNotTransparent, markInvalid, outputTooSmall
        var errorDescription: String? {
            switch self {
            case .markUnavailable:
                return "The approved SDI watercolor mark is not installed in this build, so the official-channel copy was not prepared. Your project, original and personal exports are unchanged."
            case .markNotTransparent:
                return "The installed SDI channel mark has no transparency, so it cannot be placed over the video. The channel copy was not prepared; nothing else changed."
            case .markInvalid:
                return "The installed SDI channel mark could not be read. The channel copy was not prepared; nothing else changed."
            case .outputTooSmall:
                return "This output is too small to carry a legible SDI channel mark. Choose a larger export size for the channel copy; nothing was prepared."
            }
        }
    }

    /// Pixel rectangle with a top-left origin (row 0 is the top of the picture).
    struct Rect: Equatable {
        let x: Int, y: Int, width: Int, height: Int
        var maxX: Int { x + width }
        var maxY: Int { y + height }
    }

    /// Size and position of the mark for one output size.
    ///
    /// * Width is 12% of the shorter output edge (at most 22% of the output
    ///   width), clamped to 28...240 px; height follows the logo's aspect.
    /// * Landscape and square: right and bottom margins are 4% of the shorter
    ///   edge (at least 8 px).
    /// * Portrait: right margin 5% of the width, bottom margin 12% of the height,
    ///   keeping the mark above the controls vertical-video players overlay there.
    /// * Outputs that cannot hold a 28 px mark inside those margins are refused.
    static let minimumMarkWidth = 28
    static let maximumMarkWidth = 240
    static func placement(outputWidth: Int, outputHeight: Int, markWidth: Int, markHeight: Int) throws -> Rect {
        guard outputWidth > 0, outputHeight > 0 else { throw Failure.outputTooSmall }
        guard markWidth > 0, markHeight > 0 else { throw Failure.markInvalid }
        let shortEdge = Double(min(outputWidth, outputHeight))
        let target = min(shortEdge * 0.12, Double(outputWidth) * 0.22)
        let width = Int(min(Double(maximumMarkWidth), target).rounded())
        guard width >= minimumMarkWidth else { throw Failure.outputTooSmall }
        let height = max(1, Int((Double(width) * Double(markHeight) / Double(markWidth)).rounded()))
        let right: Int, bottom: Int
        switch Orientation(width: outputWidth, height: outputHeight) {
        case .portrait:
            right = max(8, Int((Double(outputWidth) * 0.05).rounded()))
            bottom = max(8, Int((Double(outputHeight) * 0.12).rounded()))
        case .landscape, .square:
            right = max(8, Int((shortEdge * 0.04).rounded())); bottom = right
        }
        let rect = Rect(x: outputWidth - right - width, y: outputHeight - bottom - height, width: width, height: height)
        guard rect.x >= 0, rect.y >= 0, rect.height <= outputHeight / 3 else { throw Failure.outputTooSmall }
        return rect
    }

    /// WCAG relative luminance of an sRGB colour with 0...1 channels.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            let v = min(1, max(0, c))
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    /// WCAG contrast ratio, 1...21.
    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }
    /// Minimum contrast between the mark and the picture under it; below this a
    /// soft translucent backing plate is drawn behind the mark (never recolouring it).
    static let minimumContrast = 3.0
    static func needsBackingPlate(markLuminance: Double, backgroundLuminance: Double) -> Bool {
        contrastRatio(markLuminance, backgroundLuminance) < minimumContrast
    }
    /// Backing plate luminance: dark behind a light mark, light behind a dark one.
    static func plateIsDark(markLuminance: Double) -> Bool { markLuminance >= 0.5 }

    /// Alpha-weighted mean luminance of premultiplied or straight RGBA8 pixels.
    /// Returns nil when the pixels are fully transparent.
    static func meanLuminance(rgba: [UInt8], premultiplied: Bool) -> Double? {
        guard rgba.count % 4 == 0 else { return nil }
        var total = 0.0, weight = 0.0
        var index = 0
        while index < rgba.count {
            let alpha = Double(rgba[index + 3]) / 255
            if alpha > 0 {
                let scale = premultiplied ? 1 / alpha : 1
                let luminance = relativeLuminance(red: Double(rgba[index]) / 255 * scale, green: Double(rgba[index + 1]) / 255 * scale,
                                                  blue: Double(rgba[index + 2]) / 255 * scale)
                total += luminance * alpha; weight += alpha
            }
            index += 4
        }
        return weight > 0 ? total / weight : nil
    }
    /// A usable mark has some transparent and some visible pixels.
    static func hasTransparency(alpha: [UInt8]) -> Bool {
        alpha.contains { $0 < 255 } && alpha.contains { $0 > 0 }
    }
}
