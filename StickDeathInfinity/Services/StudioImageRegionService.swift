import Foundation
import CoreGraphics
import ImageIO

/// Image-source pixels only. No frame flattening or document mutation.
enum StudioImageRegionService {
    enum Mode: String, CaseIterable, Sendable { case newSelection = "New", add = "Add", subtract = "Subtract" }
    struct Result: Sendable {
        let width: Int, height: Int, selectedPixels: Int
        let membership: Data
        let selectedMask: StudioImageRegionMask
        var remainderMask: StudioImageRegionMask
        let fragmentPNG: Data
        let remainderPNG: Data
    }
    enum Failure: LocalizedError {
        case unavailable, outside, transparent, invalid, empty
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Wand currently selects pixels of one managed image on its active, visible, unlocked layer. Use a normal, fully opaque layer without glow or drawing effects."
            case .outside: return "Tap inside the selected image's visible crop."
            case .transparent: return "This image pixel is transparent. Tap visible image content."
            case .invalid: return "Wand supports complete images up to 4 megapixels and bounded color regions. Nothing changed."
            case .empty: return "No image pixels are selected."
            }
        }
    }
    /// Exact inverse of StudioFrameRenderer.drawRawLayer's image transform.
    static func sourcePoint(_ point: CGPoint, instance: StudioRasterLayerInstance,
                            width: Int, height: Int) throws -> CGPoint {
        let instance = instance.regionMask?.sampledInstance(instance) ?? instance
        guard let p = instance.placement, point.x.isFinite, point.y.isFinite,
              p.width > 0, p.height > 0 else { throw Failure.invalid }
        let radians = -(instance.rotationDegrees ?? 0) * .pi / 180
        let dx = Double(point.x) - p.x - p.width / 2, dy = Double(point.y) - p.y - p.height / 2
        var x = dx * cos(radians) - dy * sin(radians)
        var y = dx * sin(radians) + dy * cos(radians)
        if instance.reflection?.horizontal == true { x = -x }
        if instance.reflection?.vertical == true { y = -y }
        let turns = instance.quarterTurns ?? 0
        let quarter = -Double(turns) * .pi / 2
        let qx = x * cos(quarter) - y * sin(quarter), qy = x * sin(quarter) + y * cos(quarter)
        let w = turns % 2 == 0 ? p.width : p.height, h = turns % 2 == 0 ? p.height : p.width
        let u = qx / w + 0.5, v = qy / h + 0.5
        guard u >= 0, v >= 0, u < 1, v < 1 else { throw Failure.outside }
        let crop = instance.crop ?? .full
        try crop.validate()
        return CGPoint(x: (crop.x + u * crop.width) * Double(width), y: (crop.y + v * crop.height) * Double(height))
    }
    static func select(png: Data, instance: StudioRasterLayerInstance, point: CGPoint,
                       tolerance: Int, contiguous: Bool, mode: Mode, previous: Data?,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Result? {
        try checkCancellation()
        guard png.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width <= StudioFillRegion.maximumPixels / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.invalid }
        if let mask = instance.regionMask {
            try mask.validate()
            guard mask.width == width, mask.height == height else { throw Failure.invalid }
        }
        let count = width * height
        var original = [UInt8](repeating: 0, count: count * 4)
        let decoded = original.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy); context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard decoded else { throw Failure.invalid }
        let seed = try sourcePoint(point, instance: instance, width: width, height: height)
        let sx = Int(floor(seed.x)), sy = Int(floor(seed.y))
        guard sx >= 0, sy >= 0, sx < width, sy < height else { throw Failure.outside }
        guard instance.regionMask?.contains(x: sx, y: sy) ?? true else { throw Failure.outside }
        guard original[(sy * width + sx) * 4 + 3] > 0 else { throw Failure.transparent }
        var straight = original, coverage = [UInt8](repeating: 0, count: count)
        let crop = (instance.regionMask != nil ? instance.regionMask!.sourceClip : instance.crop) ?? .full
        for y in 0..<height {
            try checkCancellation()
            for x in 0..<width {
                let pixel = y * width + x, i = pixel * 4, a = Int(original[i + 3])
                if a > 0 {
                    for c in 0..<3 { straight[i + c] = UInt8(min(255, (Int(original[i + c]) * 255 + a / 2) / a)) }
                    if (instance.regionMask?.contains(x: x, y: y) ?? true) && Double(x + 1) > crop.x * Double(width) && Double(x) < (crop.x + crop.width) * Double(width) &&
                       Double(y + 1) > crop.y * Double(height) && Double(y) < (crop.y + crop.height) * Double(height) { coverage[pixel] = 255 }
                } else { straight[i] = 0; straight[i + 1] = 0; straight[i + 2] = 0 }
            }
        }
        let mask = try StudioFillRegion.compute(rgba: Data(straight), width: width, height: height, x: sx, y: sy,
            settings: .init(tolerance: tolerance, contiguous: contiguous, expand: 0, gapClose: 0, antiAlias: false),
            selectionCoverage: Data(coverage), checkCancellation: checkCancellation)
        var selected = [UInt8](repeating: 0, count: count)
        if mode != .newSelection, let previous {
            guard previous.count == count else { throw Failure.invalid }
            selected = [UInt8](previous)
        }
        for span in mask.spans {
            try checkCancellation()
            for x in span.start..<span.end { selected[span.row * width + x] = mode == .subtract ? 0 : 1 }
        }
        var fragment = original, remainder = original, selectedCount = 0, spans = 0
        for y in 0..<height {
            try checkCancellation()
            var run = false
            for x in 0..<width {
                let pixel = y * width + x, i = pixel * 4
                guard selected[pixel] <= 1 else { throw Failure.invalid }
                if coverage[pixel] == 0 { selected[pixel] = 0 }
                let chosen = selected[pixel] == 1
                if chosen { selectedCount += 1; if !run { spans += 1 }; remainder[i] = 0; remainder[i+1] = 0; remainder[i+2] = 0; remainder[i+3] = 0 }
                else { fragment[i] = 0; fragment[i+1] = 0; fragment[i+2] = 0; fragment[i+3] = 0 }
                run = chosen
            }
        }
        guard spans <= StudioFillRegion.maximumSpans else { throw StudioFillRegion.Failure.spanLimit }
        guard selectedCount > 0 else { return nil }
        var selectedMask = try makeMask(width: width, height: height, checkCancellation: checkCancellation) { x, y in selected[y * width + x] == 1 }
        var remainderMask: StudioImageRegionMask
        if instance.regionMask == nil {
            // Exactly the same path and binary boundary, with inverse coverage.
            remainderMask = .init(width: width, height: height, spans: selectedMask.spans, inverted: !selectedMask.inverted)
        } else {
            remainderMask = try makeMask(width: width, height: height, checkCancellation: checkCancellation) { x, y in
                (instance.regionMask?.contains(x: x, y: y) ?? true) && selected[y * width + x] == 0
            }
        }
        let sampled = instance.regionMask?.sampledInstance(instance) ?? instance
        guard let geometry = StudioImageRegionMask.Geometry(sampled), let reference = StudioImageRegionMask.Geometry(instance) else { throw Failure.invalid }
        let sourceClip = instance.regionMask != nil ? instance.regionMask!.sourceClip : instance.crop
        selectedMask.sourceClip = sourceClip
        selectedMask.samplingGeometry = geometry
        selectedMask.placementGeometry = try geometry.compact(for:selectedMask)
        remainderMask.sourceClip = sourceClip
        remainderMask.samplingGeometry = geometry; remainderMask.placementGeometry = reference
        try selectedMask.validate(); try remainderMask.validate()
        let fragmentPNG = try encode(fragment, width: width, height: height)
        try checkCancellation()
        let remainderPNG = try encode(remainder, width: width, height: height)
        try checkCancellation()
        return Result(width: width, height: height, selectedPixels: selectedCount, membership: Data(selected), selectedMask: selectedMask, remainderMask: remainderMask,
                      fragmentPNG: fragmentPNG, remainderPNG: remainderPNG)
    }
    /// Tight placement with a padding margin, still sampling the complete
    /// original CGImage through its equivalent crop transform. No new image is cropped.
    static func fragmentInstance(_ result: Result, original: StudioRasterLayerInstance,
                                 checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioRasterLayerInstance {
        try checkCancellation()
        guard let geometry = result.selectedMask.placementGeometry else { throw Failure.invalid }
        var value = geometry.applying(to:original); value.assetID = nil; value.regionMask = result.selectedMask
        return value
    }
    private static func makeMask(width: Int, height: Int, checkCancellation: () throws -> Void,
                                 contains: (Int, Int) -> Bool) throws -> StudioImageRegionMask {
        var spans: [StudioImageRegionMask.Span] = []
        for y in 0..<height {
            try checkCancellation()
            var start: Int?
            for x in 0...width {
                let included = x < width && contains(x, y)
                if included && start == nil { start = x }
                if !included, let first = start {
                    guard spans.count < StudioImageRegionMask.maximumSpans else { throw Failure.invalid }
                    spans.append(.init(row: y, start: first, end: x)); start = nil
                }
            }
        }
        let mask = StudioImageRegionMask(width: width, height: height, spans: spans)
        try mask.validate(); return mask
    }
    private static func encode(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure.invalid }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 16 * 1024 * 1024 else { throw Failure.invalid }
        return data as Data
    }
}
