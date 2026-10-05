import Foundation
import CoreGraphics
import CoreImage

/// Native Gaussian blur applied through a stroke mask to immutable, isolated
/// layer pixels. This engine owns no document, history, foreground color or UI.
/// Original artwork and canonical effect ordering remain the caller's concern.
enum StudioBlur {
    static let maximumPixels = 4_194_304
    static let maximumPoints = 4_096
    static let maximumStamps = 4_096
    static let maximumTouchedPixels = 16_777_216

    enum Failure: Error, Equatable {
        case invalidImage, invalidSettings, invalidPath, invalidSelection, workLimit, render
    }
    struct Point: Codable, Equatable { var x: Double; var y: Double }
    struct Settings: Codable, Equatable {
        var diameter: Double = 32
        var hardness: Double = 0.5
        var radius: Double = 4
        var strength: Double = 0.5
        func validate() throws {
            guard diameter.isFinite, (1...256).contains(diameter),
                  hardness.isFinite, (0...1).contains(hardness),
                  radius.isFinite, (0.5...32).contains(radius),
                  strength.isFinite, (0...1).contains(strength) else { throw Failure.invalidSettings }
        }
    }
    struct Pixels: Equatable {
        let width: Int
        let height: Int
        /// RGBA8, premultiplied sRGB, row-major top-left coordinates.
        let rgba: [UInt8]
        init(width: Int, height: Int, rgba: [UInt8]) throws {
            guard width > 0, height > 0, width <= 4096, height <= 4096,
                  width <= maximumPixels / height, rgba.count == width * height * 4 else {
                throw Failure.invalidImage
            }
            for i in stride(from: 0, to: rgba.count, by: 4) {
                guard rgba[i] <= rgba[i+3], rgba[i+1] <= rgba[i+3], rgba[i+2] <= rgba[i+3] else {
                    throw Failure.invalidImage
                }
            }
            self.width = width; self.height = height; self.rgba = rgba
        }
    }
    struct Work: Equatable { let stamps: Int; let touchedPixels: Int }
    private struct Stamp {
        let point: Point
        let minX: Int, maxX: Int, minY: Int, maxY: Int
        var count: Int { max(0, maxX-minX+1) * max(0, maxY-minY+1) }
    }

    static func validateWork(width: Int, height: Int, path: [Point], settings: Settings,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Work {
        let stamps = try plan(width: width, height: height, path: path, settings: settings,
                              checkCancellation: checkCancellation)
        return Work(stamps: stamps.count, touchedPixels: stamps.reduce(0) { $0 + $1.count })
    }
    private static func plan(width: Int, height: Int, path: [Point], settings: Settings,
                             checkCancellation: () throws -> Void) throws -> [Stamp] {
        try checkCancellation(); try settings.validate()
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= maximumPixels / height else { throw Failure.invalidImage }
        guard !path.isEmpty, path.count <= maximumPoints,
              path.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (0...Double(width)).contains($0.x) && (0...Double(height)).contains($0.y) }) else {
            throw Failure.invalidPath
        }
        guard settings.strength > 0 else { return [] }
        let radius = settings.diameter / 2, spacing = max(0.5, radius / 4)
        var stamps: [Stamp] = [], touched = 0
        func append(_ point: Point) throws {
            let stamp = Stamp(point: point,
                minX: max(0, Int(floor(point.x-radius))), maxX: min(width-1, Int(ceil(point.x+radius))),
                minY: max(0, Int(floor(point.y-radius))), maxY: min(height-1, Int(ceil(point.y+radius))))
            guard stamps.count < maximumStamps, stamp.count <= maximumTouchedPixels-touched else {
                throw Failure.workLimit
            }
            stamps.append(stamp); touched += stamp.count
        }
        try append(path[0])
        var cursor = path[0], remaining = spacing
        for end in path.dropFirst() {
            try checkCancellation()
            var start = cursor, distance = hypot(end.x-cursor.x, end.y-cursor.y)
            while distance >= remaining {
                let fraction = remaining / distance
                let point = Point(x: start.x+(end.x-start.x)*fraction, y: start.y+(end.y-start.y)*fraction)
                try append(point)
                start = point; distance = hypot(end.x-start.x, end.y-start.y); remaining = spacing
            }
            remaining -= distance; cursor = end
        }
        if stamps.last!.point != path.last! { try append(path.last!) }
        return stamps
    }

    /// A selection is coverage, not paint. Nil means the whole isolated layer.
    /// A thrown error never returns partially edited pixels or mutates input.
    static func apply(to input: Pixels, path: [Point], settings: Settings,
                      selection: [UInt8]? = nil,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Pixels {
        let stamps = try plan(width: input.width, height: input.height, path: path,
            settings: settings, checkCancellation: checkCancellation)
        guard selection == nil || selection!.count == input.width * input.height else { throw Failure.invalidSelection }
        guard !stamps.isEmpty else { return input }
        guard let mask = try coverage(input: input, stamps: stamps, settings: settings,
            selection: selection, checkCancellation: checkCancellation) else { return input }
        let blurred = try gaussian(input, radius: settings.radius, checkCancellation: checkCancellation)
        var result = input.rgba
        // Unstamped pixels have zero coverage. Visit only the clipped union
        // of stamp rectangles; this preserves the exact original blend while
        // avoiding a full-canvas scan for a small brush gesture.
        guard let bounds = footprintBounds(stamps) else { return input }
        for y in bounds.minY...bounds.maxY {
            try checkCancellation()
            for i in (y * input.width + bounds.minX)...(y * input.width + bounds.maxX) {
            guard mask[i] > 0 else { continue }
            let strength = Double(mask[i])/255 * settings.strength
            for c in 0..<4 {
                let offset = i*4+c
                result[offset] = UInt8((Double(input.rgba[offset])*(1-strength)+Double(blurred[offset])*strength).rounded())
            }
            for c in 0..<3 { result[i*4+c] = min(result[i*4+c], result[i*4+3]) }
            }
        }
        try checkCancellation()
        return try Pixels(width: input.width, height: input.height, rgba: result)
    }
    /// Shared bounded footprint, independent of the pixel operation. Strength is
    /// intentionally applied by the operation exactly once, after thresholding.
    static func coverage(input: Pixels, path: [Point], settings: Settings,
                         selection: [UInt8]?, checkCancellation: () throws -> Void) throws -> [UInt8]? {
        let stamps = try plan(width: input.width, height: input.height, path: path,
                              settings: settings, checkCancellation: checkCancellation)
        guard selection == nil || selection!.count == input.width * input.height else { throw Failure.invalidSelection }
        guard !stamps.isEmpty else { return nil }
        return try coverage(input: input, stamps: stamps, settings: settings,
                            selection: selection, checkCancellation: checkCancellation)
    }
    private static func coverage(input: Pixels, stamps: [Stamp], settings: Settings,
                                 selection: [UInt8]?, checkCancellation: () throws -> Void) throws -> [UInt8]? {
        var mask = [UInt8](repeating: 0, count: input.width * input.height)
        let radius = settings.diameter / 2
        for stamp in stamps where stamp.count > 0 {
            for y in stamp.minY...stamp.maxY {
                try checkCancellation()
                for x in stamp.minX...stamp.maxX {
                    let distance = hypot(Double(x)+0.5-stamp.point.x, Double(y)+0.5-stamp.point.y) / radius
                    guard distance < 1 else { continue }
                    let coverage: Double
                    if distance <= settings.hardness { coverage = 1 }
                    else {
                        let falloff = (1-distance) / (1-settings.hardness)
                        coverage = falloff * falloff * (3-2*falloff)
                    }
                    let i = y*input.width+x
                    mask[i] = max(mask[i], UInt8((coverage*255).rounded()))
                }
            }
        }
        var hasCoverage = false
        guard let bounds = footprintBounds(stamps) else { return nil }
        for y in bounds.minY...bounds.maxY {
            try checkCancellation()
            for i in (y * input.width + bounds.minX)...(y * input.width + bounds.maxX) {
                if let selection { mask[i] = UInt8((Int(mask[i])*Int(selection[i])+127)/255) }
                hasCoverage = hasCoverage || mask[i] > 0
            }
        }
        return hasCoverage ? mask : nil
    }
    private static func footprintBounds(_ stamps: [Stamp]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for stamp in stamps where stamp.count > 0 {
            if let previous = bounds {
                bounds = (min(previous.minX, stamp.minX), max(previous.maxX, stamp.maxX),
                          min(previous.minY, stamp.minY), max(previous.maxY, stamp.maxY))
            } else { bounds = (stamp.minX, stamp.maxX, stamp.minY, stamp.maxY) }
        }
        return bounds
    }
    static func gaussian(_ input: Pixels, radius: Double,
                         checkCancellation: () throws -> Void) throws -> [UInt8] {
        try checkCancellation()
        guard radius.isFinite, (0.5...32).contains(radius) else { throw Failure.invalidSettings }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.render }
        let bounds = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        let original = CIImage(bitmapData: Data(input.rgba), bytesPerRow: input.width*4,
            size: bounds.size, format: .RGBA8, colorSpace: space)
        // Clamp only at the canvas border. Transparent artwork edges inside the
        // layer still soften; an opaque canvas edge does not fade to transparency.
        let filtered = original.clampedToExtent().applyingFilter("CIGaussianBlur",
            parameters: [kCIInputRadiusKey: radius]).cropped(to: bounds)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
                                         .useSoftwareRenderer: true, .cacheIntermediates: false])
        var blurred = [UInt8](repeating: 0, count: input.rgba.count)
        blurred.withUnsafeMutableBytes { bytes in
            context.render(filtered, toBitmap: bytes.baseAddress!, rowBytes: input.width*4,
                           bounds: bounds, format: .RGBA8, colorSpace: space)
        }
        // Core Image's bounded synchronous render cannot be interrupted midway.
        // Cancellation before/after prevents any result from being committed.
        try checkCancellation()
        return blurred
    }

}
