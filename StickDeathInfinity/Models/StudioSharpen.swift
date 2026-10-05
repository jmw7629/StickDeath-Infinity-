import Foundation

/// Contrast enhancement of existing layer color. It never paints new color,
/// expands alpha, mutates its input, or commits a partial/cancelled result.
enum StudioSharpen {
    typealias Pixels = StudioBlur.Pixels
    typealias Point = StudioBlur.Point
    typealias Failure = StudioBlur.Failure

    struct Settings: Codable, Equatable {
        var diameter: Double = 32
        var hardness: Double = 0.5
        var radius: Double = 2
        var amount: Double = 0.5
        var threshold: Double = 0.02
        var opacity: Double = 1

        func validate() throws {
            try footprint.validate()
            guard amount.isFinite, (0...2).contains(amount),
                  threshold.isFinite, (0...1).contains(threshold) else {
                throw Failure.invalidSettings
            }
        }
        var footprint: StudioBlur.Settings {
            .init(diameter: diameter, hardness: hardness, radius: radius, strength: opacity)
        }
    }

    static func validateWork(width: Int, height: Int, path: [Point], settings: Settings,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioBlur.Work {
        try checkCancellation(); try settings.validate()
        return try StudioBlur.validateWork(width: width, height: height, path: path,
            settings: settings.footprint, checkCancellation: checkCancellation)
    }

    static func apply(to input: Pixels, path: [Point], settings: Settings,
                      selection: [UInt8]? = nil,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Pixels {
        try checkCancellation(); try settings.validate()
        guard let mask = try StudioBlur.coverage(input: input, path: path,
            settings: settings.footprint, selection: selection,
            checkCancellation: checkCancellation), settings.amount > 0 else { return input }
        let blurred = try StudioBlur.gaussian(input, radius: settings.radius,
                                              checkCancellation: checkCancellation)
        var output = input.rgba
        for i in mask.indices {
            if i % 16384 == 0 { try checkCancellation() }
            let offset = i * 4
            let alpha = Double(input.rgba[offset + 3])
            let blurredAlpha = Double(blurred[offset + 3])
            guard mask[i] > 0, alpha > 0, blurredAlpha > 0 else { continue }
            let weight = Double(mask[i]) / 255 * settings.opacity
            var differences = SIMD3<Double>(repeating: 0)
            var largestDifference = 0.0
            for channel in 0..<3 {
                let original = Double(input.rgba[offset + channel]) * 255 / alpha
                let softened = min(255, Double(blurred[offset + channel]) * 255 / blurredAlpha)
                differences[channel] = original - softened
                largestDifference = max(largestDifference, abs(differences[channel]))
            }
            // One shared threshold decision protects low-contrast texture
            // without independently switching each color channel on/off.
            guard largestDifference > settings.threshold * 255 else { continue }
            for channel in 0..<3 {
                let original = Double(input.rgba[offset + channel]) * 255 / alpha
                let sharpened = max(0, min(255, original + settings.amount * differences[channel]))
                let mixed = original + (sharpened - original) * weight
                output[offset + channel] = UInt8(min(alpha, max(0, mixed * alpha / 255)).rounded())
            }
        }
        try checkCancellation()
        let result = try Pixels(width: input.width, height: input.height, rgba: output)
        try checkCancellation()
        return result
    }
}
