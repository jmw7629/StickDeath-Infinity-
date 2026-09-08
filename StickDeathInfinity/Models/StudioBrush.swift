import Foundation

/// The ten entries in the supplied Studio brush library. These are native
/// rendering settings; integration into DrawnElement/history is a separate step.
enum StudioBrushFamily: String, Codable, CaseIterable {
    case round, stipple, grain, roughPen, calligraphy, dipPen
    case halftone, hatchRight, hatchLeft, gradient
}

struct StudioBrushColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    func validate() throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw StudioBrushError.invalidSettings("Brush color components must be finite values from zero to one.")
        }
    }
}

struct StudioBrushSettings: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var family: StudioBrushFamily = .round
    /// Diameter in document pixels, independent of zoom/export resolution.
    var size: Double = 3
    var opacity: Double = 1
    /// Matches the existing Studio slider's zero-through-ten range.
    var smoothing: Double = 3
    var pressureEnabled = true
    var tipAngleDegrees: Double = 45
    /// Density/base-coat/edge variation for stipple, grain and rough pen.
    var texture: Double = 0.5
    /// Particle scale for stipple and grain; other families ignore it.
    var grain: Double = 0.3
    /// Gradient requires an explicit endpoint; no invented rainbow colors.
    /// Both endpoint alphas must match the caller's paint alpha. Variable-alpha
    /// gradients are rejected by the renderer until separately implemented.
    var gradientEndColor: StudioBrushColor?

    init(family: StudioBrushFamily = .round, size: Double = 3, opacity: Double = 1,
         smoothing: Double = 3, pressureEnabled: Bool = true, tipAngleDegrees: Double = 45,
         texture: Double = 0.5, grain: Double = 0.3, gradientEndColor: StudioBrushColor? = nil) {
        self.family = family; self.size = size; self.opacity = opacity; self.smoothing = smoothing
        self.pressureEnabled = pressureEnabled; self.tipAngleDegrees = tipAngleDegrees
        self.texture = texture; self.grain = grain; self.gradientEndColor = gradientEndColor
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw StudioBrushError.invalidSettings("Unsupported brush settings version.") }
        guard size.isFinite, (0.25...512).contains(size), opacity.isFinite, (0...1).contains(opacity),
              smoothing.isFinite, (0...10).contains(smoothing), tipAngleDegrees.isFinite,
              (0..<180).contains(tipAngleDegrees), texture.isFinite, (0...1).contains(texture),
              grain.isFinite, (0...1).contains(grain) else {
            throw StudioBrushError.invalidSettings("Brush settings are outside the supported finite ranges.")
        }
        try gradientEndColor?.validate()
        if family == .gradient && gradientEndColor == nil {
            throw StudioBrushError.invalidSettings("Choose an end color before using the gradient brush.")
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, family, size, opacity, smoothing, pressureEnabled, tipAngleDegrees, texture, grain, gradientEndColor
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        family = try c.decodeIfPresent(StudioBrushFamily.self, forKey: .family) ?? .round
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 3
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 3
        pressureEnabled = try c.decodeIfPresent(Bool.self, forKey: .pressureEnabled) ?? true
        tipAngleDegrees = try c.decodeIfPresent(Double.self, forKey: .tipAngleDegrees) ?? 45
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0.5
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0.3
        gradientEndColor = try c.decodeIfPresent(StudioBrushColor.self, forKey: .gradientEndColor)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(family, forKey: .family)
        try c.encode(size, forKey: .size); try c.encode(opacity, forKey: .opacity)
        try c.encode(smoothing, forKey: .smoothing); try c.encode(pressureEnabled, forKey: .pressureEnabled)
        try c.encode(tipAngleDegrees, forKey: .tipAngleDegrees); try c.encode(texture, forKey: .texture)
        try c.encode(grain, forKey: .grain); try c.encodeIfPresent(gradientEndColor, forKey: .gradientEndColor)
    }
}

enum StudioBrushError: Error, LocalizedError, Equatable {
    case invalidSettings(String)
    case invalidPoint(Int)
    case workLimit(String)
    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message), .workLimit(let message): return message
        case .invalidPoint(let index): return "Brush sample \(index) has invalid coordinates, pressure or timing."
        }
    }
}
