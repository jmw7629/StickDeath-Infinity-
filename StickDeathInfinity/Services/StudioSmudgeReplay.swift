import SwiftUI
import CoreGraphics

/// Replays smudges from editable source artwork at document resolution. The
/// bitmaps are transient render products, never another persisted layer model.
enum StudioSmudgeReplay {
    enum Failure: Error, LocalizedError {
        case unprepared, stale, render
        var errorDescription: String? {
            switch self {
            case .unprepared: return "Smudge pixels have not been prepared. No substitute stroke was rendered."
            case .stale: return "The artwork changed after Smudge rendering. Render it again before continuing."
            case .render: return "The Smudge layer could not be rendered. The original artwork is unchanged."
            }
        }
    }
    struct Prepared {
        fileprivate let frame: AnimationFrame
        fileprivate let layers: [CanvasLayer]
        fileprivate let canvasSize: CGSize
        fileprivate let rasterData: Data?
        fileprivate let liveElement: DrawnElement?
        let images: [String: CGImage]

        fileprivate func matches(frame: AnimationFrame, layers: [CanvasLayer], canvasSize: CGSize,
                                 rasterData: Data?, liveElement: DrawnElement?) -> Bool {
            self.frame == frame && self.layers == layers && self.canvasSize == canvasSize
                && self.rasterData == rasterData && self.liveElement == liveElement
        }

        func validate(frame: AnimationFrame, layers: [CanvasLayer], canvasSize: CGSize,
                      rasterData: Data?, liveElement: DrawnElement?) throws {
            guard matches(frame: frame, layers: layers, canvasSize: canvasSize,
                          rasterData: rasterData, liveElement: liveElement) else { throw Failure.stale }
        }
    }

    /// Shared by canvas, onion skin and thumbnails. This retains at most three
    /// immutable render inputs and 32 MiB of image/raster payload, not one cache
    /// per thumbnail. It is not a bound on total renderer/process memory.
    @MainActor static let viewCache = Cache()

    @MainActor final class Cache {
        private struct Entry { let value: Prepared; let payloadBytes: Int }
        private var entries: [Entry] = [] // Most recently used first.
        private let maximumEntries: Int
        private let maximumPayloadBytes: Int
        private(set) var retainedPayloadBytes = 0
        var entryCount: Int { entries.count }

        init(maximumEntries: Int = 3, maximumPayloadBytes: Int = 32 * 1024 * 1024) {
            self.maximumEntries = max(0, min(3, maximumEntries))
            self.maximumPayloadBytes = max(0, min(32 * 1024 * 1024, maximumPayloadBytes))
        }

        func clear() {
            entries.removeAll(keepingCapacity: false)
            retainedPayloadBytes = 0
        }

        func prepare(frame: AnimationFrame, layers: [CanvasLayer], canvasSize: CGSize,
                     rasterData: Data?, liveElement: DrawnElement? = nil,
                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Prepared {
            try checkCancellation()
            if let index = entries.firstIndex(where: {
                $0.value.matches(frame: frame, layers: layers, canvasSize: canvasSize,
                                 rasterData: rasterData, liveElement: liveElement)
            }) {
                try checkCancellation()
                let hit = entries.remove(at: index)
                entries.insert(hit, at: 0)
                return hit.value
            }
            // Failed/cancelled preparation never enters the cache. Equality of
            // IDs/revisions alone is insufficient: artwork, layer settings,
            // canvas dimensions, imported bytes and live input must all match.
            let value = try StudioSmudgeReplay.prepare(frame: frame, layers: layers,
                canvasSize: canvasSize, rasterData: rasterData, liveElement: liveElement,
                checkCancellation: checkCancellation)
            try checkCancellation()
            guard maximumEntries > 0, !value.images.isEmpty else { return value }
            var cost = rasterData?.count ?? 0
            for image in value.images.values {
                let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
                guard !bytes.overflow else { return value }
                let sum = cost.addingReportingOverflow(bytes.partialValue)
                guard !sum.overflow else { return value }
                cost = sum.partialValue
            }
            // Oversized results still render correctly without being retained.
            guard cost <= maximumPayloadBytes else { return value }
            while !entries.isEmpty && (entries.count >= maximumEntries
                || retainedPayloadBytes > maximumPayloadBytes - cost) {
                retainedPayloadBytes -= entries.removeLast().payloadBytes
            }
            entries.insert(Entry(value: value, payloadBytes: cost), at: 0)
            retainedPayloadBytes += cost
            return value
        }
    }
    @MainActor
    static func prepare(frame: AnimationFrame, layers: [CanvasLayer], canvasSize: CGSize,
                        rasterData: Data?, liveElement: DrawnElement? = nil,
                        checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Prepared {
        try checkCancellation()
        var complete = frame
        if let liveElement { complete.elements.append(liveElement) }
        let effects = complete.elements.filter { $0.smudge != nil }
        var images: [String: CGImage] = [:]
        if !effects.isEmpty {
            guard canvasSize.width.isFinite, canvasSize.height.isFinite,
                  canvasSize.width.rounded() == canvasSize.width, canvasSize.height.rounded() == canvasSize.height,
                  (1...4096).contains(canvasSize.width), (1...4096).contains(canvasSize.height),
                  Set(complete.elements.map(\.id)).count == complete.elements.count,
                  Set(layers.map(\.id)).count == layers.count else { throw Failure.render }
            let width = Int(canvasSize.width), height = Int(canvasSize.height)
            try StudioSmudgeDescriptor.validateFrame(complete, width: width, height: height)
            let raster = try StudioFrameRenderer.prepareRaster(frame: frame, layers: layers, data: rasterData)
            // A caller may render one explicitly scoped layer (bucket fill or
            // color capture). Other frame layers remain editable but excluded.
            for layer in layers where layer.visible && layer.opacity > 0 {
                let ordered = complete.elements.filter { $0.layerID == layer.id }
                guard ordered.contains(where: { $0.smudge != nil }) else { continue }
                var base: CGImage?
                var prefix = frame; prefix.elements = []
                for element in ordered {
                    try checkCancellation()
                    guard let descriptor = element.smudge else { prefix.elements.append(element); continue }
                    let source = try renderPrefix(prefix, layer: layer, canvasSize: canvasSize,
                                                  raster: raster, base: base)
                    let original = try pixels(source)
                    let changed = try StudioSmudge.apply(to: original,
                        path: element.points.map { .init(x: $0.x, y: $0.y) },
                        settings: descriptor.settings(for: element), checkCancellation: checkCancellation)
                    let image = try cgImage(changed)
                    images[element.id] = image; base = image; prefix.elements.removeAll()
                }
            }
        }
        try checkCancellation()
        return Prepared(frame: frame, layers: layers, canvasSize: canvasSize,
                        rasterData: rasterData, liveElement: liveElement, images: images)
    }

    @MainActor
    private static func renderPrefix(_ frame: AnimationFrame, layer: CanvasLayer, canvasSize: CGSize,
                                     raster: StudioRasterImage.Prepared?, base: CGImage?) throws -> CGImage {
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let content = Canvas { context, size in
            failure = StudioFrameRenderer.drawRawLayer(context: &context, frame: frame, layer: layer,
                canvasSize: canvasSize, size: size, preparedBrushes: brushes, preparedRaster: raster, baseImage: base)
        }.frame(width: canvasSize.width, height: canvasSize.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1; renderer.isOpaque = false
        guard let image = renderer.cgImage, image.width == Int(canvasSize.width),
              image.height == Int(canvasSize.height) else { throw Failure.render }
        if let failure { throw failure }
        return image
    }
    static func pixels(_ image: CGImage) throws -> StudioSmudge.Pixels {
        guard image.width > 0, image.height > 0, image.width <= 4096, image.height <= 4096,
              image.width <= StudioSmudge.maximumPixels / image.height else { throw StudioSmudge.Failure.invalidImage }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard decoded else { throw Failure.render }
        return try .init(width: image.width, height: image.height, rgba: bytes)
    }
    static func cgImage(_ pixels: StudioSmudge.Pixels) throws -> CGImage {
        let data = Data(pixels.rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: pixels.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.render }
        return image
    }
}
