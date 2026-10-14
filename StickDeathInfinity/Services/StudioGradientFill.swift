import Foundation

/// Gradient tool pixel stage (#149). Paints a linear or radial gradient into a
/// premultiplied RGBA layer bitmap, limited by an optional coverage mask (a
/// fill region, wand selection or feathered selection). Pure and bounded: no
/// file, document or history mutation. The caller captures the active layer,
/// rechecks ownership and commits the result as one undoable edit.
enum StudioGradientFill {
    static let maximumPixels = 4_194_304
    static let maximumStops = 16
    /// Colour lookup resolution; 4,096 steps exceed 8-bit output precision.
    static let lookupSize = 4_096

    enum Shape: String, Codable, CaseIterable, Sendable { case linear, radial }
    /// `sRGB` mixes encoded values (classic look). `linearLight` mixes physical
    /// light, which avoids the dark band between saturated complements.
    enum Interpolation: String, Codable, CaseIterable, Sendable { case sRGB, linearLight }

    struct Color: Codable, Equatable, Sendable {
        var red: Double, green: Double, blue: Double, alpha: Double = 1
        var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    }
    struct Stop: Codable, Equatable, Sendable {
        var location: Double
        var color: Color
    }
    struct Point: Codable, Equatable, Sendable { var x: Double, y: Double }

    struct Settings: Codable, Equatable, Sendable {
        var shape: Shape = .linear
        /// Document pixel coordinates, top-left origin. For radial, `start` is
        /// the centre and the distance to `end` is the radius.
        var start: Point
        var end: Point
        var stops: [Stop]
        var opacity: Double = 1
        var interpolation: Interpolation = .sRGB
        /// 4x4 ordered dither before 8-bit rounding to break up banding.
        var dither = true
        /// Layer alpha lock: paint only onto existing pixels and keep their alpha.
        var preserveTransparency = false
    }
    struct Result: Equatable, Sendable {
        let changedPixels: Int
        /// Inclusive-exclusive pixel bounds of every changed pixel, if any.
        let minX: Int, minY: Int, maxX: Int, maxY: Int
    }
    enum Failure: LocalizedError, Equatable {
        case invalidImage, invalidSettings, degenerate, emptyCoverage
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Gradient needs a complete layer image within the supported canvas pixel limit."
            case .invalidSettings: return "These gradient settings are outside the supported range. Nothing has changed."
            case .degenerate: return "Drag a longer gradient line; its start and end are at the same point."
            case .emptyCoverage: return "The gradient has no selected or paintable pixels here. Nothing has changed."
            }
        }
    }

    static func validate(_ settings: Settings) throws {
        let coordinates = [settings.start.x, settings.start.y, settings.end.x, settings.end.y]
        guard coordinates.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              settings.opacity.isFinite, (0...1).contains(settings.opacity),
              (2...maximumStops).contains(settings.stops.count) else { throw Failure.invalidSettings }
        var previous = -Double.infinity
        for stop in settings.stops {
            guard stop.location.isFinite, (0...1).contains(stop.location), stop.location >= previous,
                  stop.color.isValid else { throw Failure.invalidSettings }
            previous = stop.location
        }
        let dx = settings.end.x - settings.start.x, dy = settings.end.y - settings.start.y
        guard dx * dx + dy * dy >= 1 else { throw Failure.degenerate }
    }

    /// Straight (unpremultiplied) colour at gradient position `t` in 0...1.
    static func color(at t: Double, settings: Settings) -> Color {
        let stops = settings.stops
        let position = min(1, max(0, t))
        if position <= stops[0].location { return stops[0].color }
        if position >= stops[stops.count - 1].location { return stops[stops.count - 1].color }
        var upper = 1
        while upper < stops.count - 1 && stops[upper].location < position { upper += 1 }
        let a = stops[upper - 1], b = stops[upper]
        let span = b.location - a.location
        let f = span > 0 ? (position - a.location) / span : 1
        func mix(_ x: Double, _ y: Double) -> Double {
            switch settings.interpolation {
            case .sRGB: return x + (y - x) * f
            case .linearLight: return encode(decode(x) + (decode(y) - decode(x)) * f)
            }
        }
        return Color(red: mix(a.color.red, b.color.red), green: mix(a.color.green, b.color.green),
                     blue: mix(a.color.blue, b.color.blue), alpha: a.color.alpha + (b.color.alpha - a.color.alpha) * f)
    }
    static func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// Gradient position for the centre of pixel (x, y).
    static func position(x: Int, y: Int, settings: Settings) -> Double {
        let px = Double(x) + 0.5 - settings.start.x, py = Double(y) + 0.5 - settings.start.y
        let dx = settings.end.x - settings.start.x, dy = settings.end.y - settings.start.y
        switch settings.shape {
        case .linear: return (px * dx + py * dy) / (dx * dx + dy * dy)
        case .radial: return hypot(px, py) / hypot(dx, dy)
        }
    }

    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 - 0.5 }

    /// Composites the gradient source-over (or source-atop with
    /// `preserveTransparency`) into `pixels`, premultiplied RGBA8 rows with a
    /// top-left origin. `coverage` holds one 0...255 weight per pixel; nil
    /// paints the whole layer. On any error `pixels` is left unchanged.
    @discardableResult
    static func apply(to pixels: inout [UInt8], width: Int, height: Int, coverage: [UInt8]? = nil,
                      settings: Settings,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Result {
        try checkCancellation()
        guard width > 0, height > 0, width <= 4096, height <= 4096, width <= maximumPixels / height,
              pixels.count == width * height * 4 else { throw Failure.invalidImage }
        if let coverage, coverage.count != width * height { throw Failure.invalidImage }
        try validate(settings)
        // Premultiplied 0...255 lookup, computed once per call.
        var lookup = [Double](repeating: 0, count: lookupSize * 4)
        for index in 0..<lookupSize {
            let c = color(at: Double(index) / Double(lookupSize - 1), settings: settings)
            let a = c.alpha * settings.opacity
            lookup[index * 4] = c.red * a * 255; lookup[index * 4 + 1] = c.green * a * 255
            lookup[index * 4 + 2] = c.blue * a * 255; lookup[index * 4 + 3] = a
        }
        var output = pixels
        var changed = 0, minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            try checkCancellation()
            for x in 0..<width {
                let index = y * width + x
                let weight = coverage.map { Double($0[index]) / 255 } ?? 1
                if weight == 0 { continue }
                let o = index * 4
                let dstA = Double(pixels[o + 3]) / 255
                if settings.preserveTransparency && dstA == 0 { continue }
                let t = min(1, max(0, position(x: x, y: y, settings: settings)))
                let l = Int((t * Double(lookupSize - 1)).rounded()) * 4
                let srcA = lookup[l + 3] * weight
                if srcA == 0 { continue }
                let noise = settings.dither ? bayer[(y & 3) * 4 + (x & 3)] : 0
                let outA: Double = settings.preserveTransparency ? dstA : srcA + dstA * (1 - srcA)
                let alphaByte = UInt8(min(255, max(0, (outA * 255).rounded())))
                func blend(_ channel: Int) -> UInt8 {
                    let src = lookup[l + channel] * weight
                    let dst = Double(pixels[o + channel])
                    // Source-atop keeps the destination's coverage: the new
                    // colour lands only where the layer already has paint.
                    let value = settings.preserveTransparency ? src * dstA + dst * (1 - srcA) : src + dst * (1 - srcA)
                    // Premultiplied channels can never exceed alpha.
                    return UInt8(min(Double(alphaByte), max(0, (value + noise).rounded())))
                }
                let red = blend(0), green = blend(1), blue = blend(2)
                if red != pixels[o] || green != pixels[o + 1] || blue != pixels[o + 2] || alphaByte != pixels[o + 3] {
                    output[o] = red; output[o + 1] = green; output[o + 2] = blue; output[o + 3] = alphaByte
                    changed += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x + 1); maxY = max(maxY, y + 1)
                }
            }
        }
        try checkCancellation()
        guard changed > 0 else { throw Failure.emptyCoverage }
        pixels = output
        return Result(changedPixels: changed, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}
