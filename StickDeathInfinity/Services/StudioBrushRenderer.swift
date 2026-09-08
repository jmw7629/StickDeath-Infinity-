import SwiftUI
import CoreGraphics

/// A bounded, deterministic geometry stage shared by native Canvas and bitmap
/// rendering. No viewport coordinates, random asset textures or mutable state.
struct StudioBrushRenderer {
    static let maximumInputPoints = 100_000
    static let maximumDabs = 8_192
    static let maximumMarks = 65_536

    struct Mark: Equatable {
        enum Shape: Equatable { case ellipse, rectangle }
        let shape: Shape
        let x: Double, y: Double, width: Double, height: Double, angle: Double
        let opacity: Double, colorMix: Double
    }
    struct Geometry: Equatable {
        let marks: [Mark]
        let opacity: Double
        let gradientEndColor: StudioBrushColor?
        let sampledPointCount: Int
        let seed: UInt64
        let bounds: CGRect
        fileprivate init(marks: [Mark], settings: StudioBrushSettings, count: Int, seed: UInt64) {
            self.marks = marks; opacity = settings.opacity
            gradientEndColor = settings.family == .gradient ? settings.gradientEndColor : nil
            sampledPointCount = count; self.seed = seed
            var footprint = CGRect.null
            for mark in marks {
                let cosine = abs(cos(mark.angle)), sine = abs(sin(mark.angle))
                let width = mark.width * cosine + mark.height * sine
                let height = mark.width * sine + mark.height * cosine
                footprint = footprint.union(CGRect(x: mark.x - width / 2, y: mark.y - height / 2, width: width, height: height))
            }
            bounds = footprint.isNull ? .null : footprint.insetBy(dx: -1, dy: -1)
        }
    }
    private struct Sample {
        var x: Double, y: Double, pressure: Double
        var speed: Double?
        var distance: Double = 0
    }
    private struct Random {
        var state: UInt64
        mutating func unit() -> Double {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            return Double(value >> 11) / 9_007_199_254_740_992
        }
    }
    /// Stable across launches/platforms; unlike Swift Hasher, this can be stored
    /// beside the stroke and reproduced in thumbnails and exported files.
    static func seed(for elementID: String) -> UInt64 {
        elementID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    static func geometry(points: [StrokePoint], settings: StudioBrushSettings, seed: UInt64,
                         checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Geometry {
        try settings.validate(); try checkCancellation()
        guard points.count <= maximumInputPoints else { throw StudioBrushError.workLimit("The stroke exceeds 100,000 input samples.") }
        guard !points.isEmpty else { return Geometry(marks: [], settings: settings, count: 0, seed: seed) }
        var lastTime: Double?
        for (index, point) in points.enumerated() {
            if index % 256 == 0 { try checkCancellation() }
            guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000,
                  point.pressure.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  point.timestamp.map({ $0.isFinite && $0 >= 0 && $0 >= (lastTime ?? 0) }) ?? true else {
                throw StudioBrushError.invalidPoint(index)
            }
            if let time = point.timestamp { lastTime = time }
        }
        let spacingRatio: Double
        switch settings.family {
        case .halftone: spacingRatio = 0.65
        case .hatchRight, .hatchLeft: spacingRatio = 0.45
        case .stipple: spacingRatio = 0.28
        case .grain: spacingRatio = 0.22
        default: spacingRatio = 0.15
        }
        let spacing = max(0.25, settings.size * spacingRatio)
        let factor = 1 / (1 + settings.smoothing * 0.4)
        var filtered: [Sample] = []; filtered.reserveCapacity(points.count + 1)
        var previousX = Double(points[0].x), previousY = Double(points[0].y)
        for (index, point) in points.enumerated() {
            if index % 256 == 0 { try checkCancellation() }
            let x = index == 0 ? Double(point.x) : previousX + (Double(point.x) - previousX) * factor
            let y = index == 0 ? Double(point.y) : previousY + (Double(point.y) - previousY) * factor
            var speed: Double?
            if index > 0, let time = point.timestamp, let before = points[index - 1].timestamp, time > before {
                let dx = Double(point.x - points[index - 1].x), dy = Double(point.y - points[index - 1].y)
                speed = min(1_000_000, hypot(dx, dy) / (time - before))
            }
            filtered.append(Sample(x: x, y: y, pressure: Double(point.pressure ?? 1), speed: speed))
            previousX = x; previousY = y
        }
        // Smoothing never drops the exact final input position.
        if let end = points.last, previousX != Double(end.x) || previousY != Double(end.y) {
            filtered.append(Sample(x: Double(end.x), y: Double(end.y), pressure: Double(end.pressure ?? 1), speed: filtered.last?.speed))
        }
        var dabs = [filtered[0]], totalDistance = 0.0, nextDistance = spacing
        for index in 1..<filtered.count {
            if index % 256 == 0 { try checkCancellation() }
            let a = filtered[index - 1], b = filtered[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard totalDistance + length <= Double(maximumDabs - 1) * spacing else {
                throw StudioBrushError.workLimit("The stroke exceeds the 8,192-dab rendering budget; split it into shorter strokes.")
            }
            // A stationary stylus can change force without advancing along
            // the path. Preserve those pressure marks within the same budget.
            if length == 0 && settings.pressureEnabled && a.pressure != b.pressure {
                guard dabs.count < maximumDabs else { throw StudioBrushError.workLimit("The stroke exceeds the pressure-dab budget.") }
                var pressureDab = b; pressureDab.distance = totalDistance; dabs.append(pressureDab)
            }
            while length > 0 && nextDistance <= totalDistance + length {
                guard dabs.count < maximumDabs else { throw StudioBrushError.workLimit("The stroke exceeds the rendering budget.") }
                if dabs.count % 256 == 0 { try checkCancellation() }
                let t = (nextDistance - totalDistance) / length
                dabs.append(Sample(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                    pressure: a.pressure + (b.pressure - a.pressure) * t, speed: b.speed, distance: nextDistance))
                nextDistance += spacing
            }
            totalDistance += length
        }
        if let end = filtered.last, let last = dabs.last,
           hypot(end.x - last.x, end.y - last.y) > 0.000_001 || (settings.pressureEnabled && end.pressure != last.pressure) {
            guard dabs.count < maximumDabs else { throw StudioBrushError.workLimit("The stroke exceeds the rendering budget.") }
            var endpoint = end; endpoint.distance = totalDistance; dabs.append(endpoint)
        }
        var marks: [Mark] = []; marks.reserveCapacity(min(maximumMarks, dabs.count * 8))
        var random = Random(state: seed)
        func mark(_ shape: Mark.Shape = .ellipse, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                  _ angle: Double = 0, _ opacity: Double = 1, _ mix: Double = 0) throws {
            guard marks.count < maximumMarks else { throw StudioBrushError.workLimit("The stroke exceeds 65,536 native marks.") }
            marks.append(Mark(shape: shape, x: x, y: y, width: width, height: height, angle: angle, opacity: opacity, colorMix: mix))
        }
        for (index, dab) in dabs.enumerated() {
            if index % 128 == 0 { try checkCancellation() }
            let pressure = settings.pressureEnabled ? 0.15 + 0.85 * dab.pressure : 1
            let size = settings.size * pressure
            switch settings.family {
            case .round:
                try mark(.ellipse, dab.x, dab.y, size, size)
            case .stipple:
                for _ in 0..<(3 + Int(settings.texture * 4)) {
                    let angle = random.unit() * .pi * 2, radius = sqrt(random.unit()) * size * 0.5
                    let diameter = size * (0.04 + random.unit() * (0.1 + settings.grain * 0.06))
                    try mark(.ellipse, dab.x + cos(angle) * radius, dab.y + sin(angle) * radius, diameter, diameter)
                }
            case .grain:
                try mark(.ellipse, dab.x, dab.y, size * 0.8, size * 0.8, 0, 0.08 + (1 - settings.texture) * 0.15)
                for _ in 0..<6 {
                    let angle = random.unit() * .pi * 2, radius = sqrt(random.unit()) * size * 0.55
                    let diameter = size * (0.04 + random.unit() * (0.04 + settings.grain * 0.2))
                    try mark(.rectangle, dab.x + cos(angle) * radius, dab.y + sin(angle) * radius,
                             diameter, diameter, random.unit() * .pi, 0.25 + random.unit() * 0.65)
                }
            case .roughPen:
                let jitter = size * settings.texture * 0.15
                let diameter = size * (0.7 + random.unit() * 0.35)
                try mark(.ellipse, dab.x + (random.unit() - 0.5) * jitter,
                         dab.y + (random.unit() - 0.5) * jitter, diameter, diameter * (0.65 + random.unit() * 0.4))
                try mark(.ellipse, dab.x + (random.unit() - 0.5) * size, dab.y + (random.unit() - 0.5) * size,
                         size * 0.08, size * 0.08, 0, 0.6)
            case .calligraphy:
                try mark(.ellipse, dab.x, dab.y, size, size * 0.2, settings.tipAngleDegrees * .pi / 180)
            case .dipPen:
                // Absent/equal timestamps use a documented neutral nib width;
                // sample count is never misrepresented as measured velocity.
                let speedFactor = dab.speed.map { 0.25 + 0.75 / (1 + $0 / (settings.size * 20)) } ?? 0.7
                let width = size * speedFactor
                try mark(.ellipse, dab.x, dab.y, width, width)
            case .halftone:
                try mark(.ellipse, dab.x, dab.y, size * 0.38, size * 0.38)
            case .hatchRight, .hatchLeft:
                let angle = settings.family == .hatchRight ? -Double.pi / 4 : Double.pi / 4
                try mark(.rectangle, dab.x, dab.y, size * 1.15, max(0.1, size * 0.08), angle)
            case .gradient:
                try mark(.ellipse, dab.x, dab.y, size, size, 0, 1,
                         totalDistance > 0 ? dab.distance / totalDistance : 0)
            }
        }
        try checkCancellation()
        return Geometry(marks: marks, settings: settings, count: dabs.count, seed: seed)
    }

    /// Geometry uses document coordinates. Supply a top-left user-space CTM
    /// for an unflipped bitmap context: translate(0, height), then scale(1, -1).
    /// Existing UIKit top-left contexts must not be flipped a second time.
    static func draw(_ geometry: Geometry, color: StudioBrushColor, in context: CGContext) throws {
        let opacity = try paintOpacity(geometry, color: color)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw StudioBrushError.invalidSettings("The native sRGB color space is unavailable.")
        }
        guard !geometry.marks.isEmpty else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: geometry.bounds)
        // The outer layer preserves the caller's opacity/blend state. The
        // inner layer applies brush opacity once, despite overlapping dabs.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColorSpace(colorSpace)
        for mark in geometry.marks {
            let tint = mixed(color, geometry.gradientEndColor, mark.colorMix)
            context.setAlpha(mark.opacity)
            let components: [CGFloat] = [tint.red, tint.green, tint.blue, tint.alpha]
            context.setFillColor(components)
            context.addPath(path(mark)); context.fillPath()
        }
        context.endTransparencyLayer()
        context.endTransparencyLayer()
    }

    /// SwiftUI Canvas already uses top-left coordinates; use the same geometry
    /// without an extra vertical reflection. Its inherited opacity is retained.
    static func draw(_ geometry: Geometry, color: StudioBrushColor, context: inout GraphicsContext) throws {
        let opacity = try paintOpacity(geometry, color: color)
        guard !geometry.marks.isEmpty else { return }
        var group = context; group.opacity *= opacity
        group.clip(to: Path(geometry.bounds))
        group.drawLayer { local in
            for mark in geometry.marks {
                let tint = mixed(color, geometry.gradientEndColor, mark.colorMix)
                var stamp = local; stamp.opacity *= mark.opacity
                stamp.fill(Path(path(mark)), with: .color(Color(.sRGB, red: tint.red, green: tint.green,
                                                              blue: tint.blue, opacity: tint.alpha)))
            }
        }
    }
    private static func path(_ mark: Mark) -> CGPath {
        let rect = CGRect(x: -mark.width / 2, y: -mark.height / 2, width: mark.width, height: mark.height)
        let path = CGMutablePath()
        let transform = CGAffineTransform(translationX: mark.x, y: mark.y).rotated(by: mark.angle)
        if mark.shape == .ellipse { path.addEllipse(in: rect, transform: transform) }
        else { path.addRect(rect, transform: transform) }
        return path
    }
    private static func paintOpacity(_ geometry: Geometry, color: StudioBrushColor) throws -> Double {
        try color.validate()
        if let endpoint = geometry.gradientEndColor, endpoint.alpha != color.alpha {
            throw StudioBrushError.invalidSettings("Gradient endpoint alpha must match the paint alpha. Use brush opacity for transparency.")
        }
        return geometry.opacity * color.alpha
    }
    private static func mixed(_ first: StudioBrushColor, _ second: StudioBrushColor?, _ fraction: Double) -> StudioBrushColor {
        let endpoint = second ?? first
        // Paint alpha applies once to the completed stroke, never once per dab.
        return StudioBrushColor(red: first.red + (endpoint.red - first.red) * fraction,
            green: first.green + (endpoint.green - first.green) * fraction,
            blue: first.blue + (endpoint.blue - first.blue) * fraction, alpha: 1)
    }
}
