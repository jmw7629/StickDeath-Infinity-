import Foundation

/// A deterministic color-drag operation on an isolated layer's premultiplied
/// sRGB pixels. There is no foreground-color input: smudging moves existing
/// color and coverage, including transparency, rather than painting a stroke.
/// The caller owns rendering, document identity, history and persistence.
enum StudioSmudge {
    static let maximumPixels = 4_194_304
    static let maximumPoints = 4_096
    static let maximumStamps = 4_096
    static let maximumTouchedPixels = 16_777_216

    enum Failure: Error, LocalizedError, Equatable {
        case invalidImage, invalidSettings, invalidPath, workLimit
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "Smudge requires a valid premultiplied sRGB layer of at most four million pixels."
            case .invalidSettings: return "Smudge size, strength or opacity is outside its supported range."
            case .invalidPath: return "Smudge input is invalid. The original layer has not changed."
            case .workLimit: return "This smudge exceeds its processing limit. Use a shorter stroke or smaller brush."
            }
        }
    }

    struct Settings: Codable, Equatable {
        var diameter: Double = 24
        /// How far each sample pulls existing color along the drag, from 0...1.
        var strength: Double = 0.5
        /// Blend the final effect once with the original, from 0...1.
        var opacity: Double = 1
        func validate() throws {
            guard diameter.isFinite, (1...256).contains(diameter),
                  strength.isFinite, (0...1).contains(strength),
                  opacity.isFinite, (0...1).contains(opacity) else { throw Failure.invalidSettings }
        }
    }
    struct Point: Codable, Equatable { var x: Double; var y: Double }
    struct Pixels: Equatable {
        let width: Int
        let height: Int
        /// RGBA8, row-major, top-left origin. RGB components never exceed alpha.
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
        private init(validWidth: Int, height: Int, rgba: [UInt8]) {
            self.width = validWidth; self.height = height; self.rgba = rgba
        }
        fileprivate func replacing(_ bytes: [UInt8]) -> Pixels {
            Pixels(validWidth: width, height: height, rgba: bytes)
        }
    }
    private struct Stamp {
        let x: Double, y: Double, dx: Double, dy: Double
        let minX: Int, maxX: Int, minY: Int, maxY: Int
        var count: Int { max(0, maxX-minX+1) * max(0, maxY-minY+1) }
    }

    struct Work: Equatable {
        let stampCount: Int
        let touchedPixels: Int
    }
    /// Canonical command/document validation can reject expensive strokes
    /// without allocating or decoding a source bitmap. Rendering uses this
    /// exact same planner; a second approximation cannot bypass its limits.
    static func validateWork(width: Int, height: Int, path: [Point], settings: Settings,
                             checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Work {
        let stamps = try plan(width: width, height: height, path: path, settings: settings,
            checkCancellation: checkCancellation)
        return Work(stampCount: stamps.count, touchedPixels: stamps.reduce(0) { $0+$1.count })
    }
    private static func plan(width: Int, height: Int, path: [Point], settings: Settings,
                             checkCancellation: () throws -> Void) throws -> [Stamp] {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width <= maximumPixels / height else { throw Failure.invalidImage }
        try checkCancellation(); try settings.validate()
        guard !path.isEmpty, path.count <= maximumPoints,
              path.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (0...Double(width)).contains($0.x) && (0...Double(height)).contains($0.y) }) else {
            throw Failure.invalidPath
        }
        guard settings.opacity > 0, settings.strength > 0, path.count > 1 else { return [] }
        let radius = settings.diameter / 2
        // Uniform arc-length stamps make results independent of touch sampling
        // density on a straight drag. Bends retain their actual path geometry.
        let spacing = max(0.5, radius / 4)
        var stamps: [Stamp] = []; var touched = 0
        var last = path[0]; var cursor = path[0]; var remaining = spacing
        func append(_ point: Point) throws {
            let dx = point.x-last.x, dy = point.y-last.y
            guard hypot(dx,dy) > 0.000000001 else { return }
            let stamp = Stamp(x: point.x, y: point.y, dx: dx, dy: dy,
                minX: max(0, Int(floor(point.x-radius))), maxX: min(width-1, Int(ceil(point.x+radius))),
                minY: max(0, Int(floor(point.y-radius))), maxY: min(height-1, Int(ceil(point.y+radius))))
            guard stamps.count < maximumStamps, stamp.count <= maximumTouchedPixels-touched else { throw Failure.workLimit }
            touched += stamp.count; stamps.append(stamp); last = point
        }
        for end in path.dropFirst() {
            try checkCancellation()
            var start = cursor
            var distance = hypot(end.x-start.x,end.y-start.y)
            while distance >= remaining {
                let fraction = remaining / distance
                let point = Point(x: start.x+(end.x-start.x)*fraction, y: start.y+(end.y-start.y)*fraction)
                try append(point)
                start = point; distance = hypot(end.x-start.x,end.y-start.y); remaining = spacing
            }
            remaining -= distance; cursor = end
        }
        try append(path[path.count-1])
        return stamps
    }

    /// Validates the entire workload before allocating output. A thrown error
    /// never exposes partial pixels or mutates the immutable input.
    static func apply(to input: Pixels, path: [Point], settings: Settings,
                      checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Pixels {
        let stamps = try plan(width: input.width, height: input.height, path: path,
            settings: settings, checkCancellation: checkCancellation)
        guard !stamps.isEmpty else { return input }
        let radius = settings.diameter / 2
        var output = input.rgba
        // A stamp reads only the preceding image. A bounded patch avoids both
        // directional in-place feedback and one full-canvas copy per stamp.
        var patch = [UInt8](repeating: 0, count: (Int(ceil(settings.diameter))+3) * (Int(ceil(settings.diameter))+3) * 4)
        func sample(_ x: Double, _ y: Double, _ channel: Int) -> Double {
            // Pixel centers are at n+0.5. Outside the layer is transparent;
            // clamping to the edge would replicate opaque border pixels.
            let px = x-0.5, py = y-0.5, ix = Int(floor(px)), iy = Int(floor(py))
            let fx = px-Double(ix), fy = py-Double(iy)
            func value(_ xx: Int, _ yy: Int) -> Double {
                guard xx >= 0, xx < input.width, yy >= 0, yy < input.height else { return 0 }
                return Double(output[(yy*input.width+xx)*4+channel])
            }
            return value(ix,iy)*(1-fx)*(1-fy) + value(ix+1,iy)*fx*(1-fy)
                + value(ix,iy+1)*(1-fx)*fy + value(ix+1,iy+1)*fx*fy
        }
        for stamp in stamps where stamp.count > 0 {
            try checkCancellation()
            let rowWidth = stamp.maxX-stamp.minX+1
            for y in stamp.minY...stamp.maxY {
                try checkCancellation()
                for x in stamp.minX...stamp.maxX {
                    let p = ((y-stamp.minY)*rowWidth+x-stamp.minX)*4
                    let original = (y*input.width+x)*4
                    let distance = hypot(Double(x)+0.5-stamp.x,Double(y)+0.5-stamp.y)/radius
                    if distance >= 1 {
                        for c in 0..<4 { patch[p+c] = output[original+c] }
                    } else {
                        let falloff = (1-distance*distance)*(1-distance*distance)
                        let pull = settings.strength*falloff
                        for c in 0..<4 {
                            patch[p+c] = UInt8(min(255,max(0,sample(Double(x)+0.5-stamp.dx*pull,
                                Double(y)+0.5-stamp.dy*pull,c).rounded())))
                        }
                    }
                }
            }
            for y in stamp.minY...stamp.maxY {
                let from = (y-stamp.minY)*rowWidth*4, to = (y*input.width+stamp.minX)*4
                output.replaceSubrange(to..<(to+rowWidth*4),with:patch[from..<(from+rowWidth*4)])
            }
        }
        // Opacity is applied once per gesture, including self-crossings.
        if settings.opacity < 1 {
            for i in output.indices {
                if i % 16384 == 0 { try checkCancellation() }
                output[i] = UInt8((Double(input.rgba[i])*(1-settings.opacity)+Double(output[i])*settings.opacity).rounded())
            }
        }
        try checkCancellation()
        return input.replacing(output)
    }
}
