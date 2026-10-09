import Foundation

/// Exposure changes on existing premultiplied sRGB pixels. No foreground paint,
/// alpha expansion, document mutation, or proprietary filter implementation.
enum StudioDodgeBurn {
    typealias Pixels = StudioBlur.Pixels
    typealias Point = StudioBlur.Point
    typealias Failure = StudioBlur.Failure
    enum Mode: String, Codable, CaseIterable { case dodge, burn }
    enum TonalRange: String, Codable, CaseIterable { case all, shadows, midtones, highlights }
    struct Settings: Codable, Equatable {
        var mode: Mode = .dodge
        var diameter: Double = 32
        var hardness: Double = 0.5
        /// 0...1 maps to zero through two stops per completed gesture.
        var exposure: Double = 0.25
        var range: TonalRange = .midtones
        var protectTones = true
        var opacity: Double = 1
        func validate() throws {
            try footprint.validate()
            guard exposure.isFinite, (0...1).contains(exposure) else { throw Failure.invalidSettings }
        }
        var footprint: StudioBlur.Settings {
            .init(diameter: diameter, hardness: hardness, radius: 0.5, strength: opacity)
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
        guard let mask = try StudioBlur.coverage(input: input, path: path, settings: settings.footprint,
            selection: selection, checkCancellation: checkCancellation), settings.exposure > 0 else { return input }
        var output = input.rgba
        for i in mask.indices {
            if i % 16384 == 0 { try checkCancellation() }
            let offset = i * 4, alpha = Double(input.rgba[offset + 3])
            guard mask[i] > 0, alpha > 0 else { continue }
            let encoded = SIMD3<Double>(Double(input.rgba[offset]) / alpha,
                Double(input.rgba[offset + 1]) / alpha, Double(input.rgba[offset + 2]) / alpha)
            // Tonal selection uses perceived encoded brightness; exposure uses
            // linear light. White/black RGB cannot leak from transparent pixels.
            let tone = 0.2126 * encoded.x + 0.7152 * encoded.y + 0.0722 * encoded.z
            let rangeWeight: Double
            switch settings.range {
            case .all: rangeWeight = 1
            case .shadows: rangeWeight = 1 - smoothstep(0.2, 0.65, tone)
            case .midtones: rangeWeight = 4 * tone * (1 - tone)
            case .highlights: rangeWeight = smoothstep(0.35, 0.8, tone)
            }
            guard rangeWeight > 0 else { continue }
            let stops = settings.exposure * 2 * rangeWeight
            let gain = pow(2, settings.mode == .dodge ? stops : -stops)
            let rgb = SIMD3<Double>(linear(encoded.x), linear(encoded.y), linear(encoded.z))
            let peak = max(rgb.x, max(rgb.y, rgb.z))
            let protectedGain: Double
            if settings.protectTones {
                // One gain for all channels retains linear RGB proportions.
                // Dodge approaches white without clipping; Burn approaches
                // black gently rather than crushing already dark tones.
                protectedGain = settings.mode == .dodge
                    ? gain / (1 + peak * (gain - 1))
                    : 1 / (1 + peak * (1 / gain - 1))
            } else { protectedGain = gain }
            let weight = Double(mask[i]) / 255 * settings.opacity
            for channel in 0..<3 {
                let changed = min(1, max(0, rgb[channel] * protectedGain))
                let mixed = rgb[channel] + (changed - rgb[channel]) * weight
                output[offset + channel] = UInt8(min(alpha, max(0, encodedSRGB(mixed) * alpha)).rounded())
            }
        }
        try checkCancellation()
        let result = try Pixels(width: input.width, height: input.height, rgba: output)
        try checkCancellation()
        return result
    }
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    private static func encodedSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
    private static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
}
