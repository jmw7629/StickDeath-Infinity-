import Foundation
import SwiftUI

/// Samples the canonical current artwork over the Studio's white canvas. Editor
/// guides, selection outlines and onion skin are not document artwork. No file,
/// document, history, playback, cloud or publication operation occurs here.
@MainActor
enum StudioColorSamplingService {
    static let maximumPixels = 4_194_304
    /// PhotoCraft eyedropper sample sizes (point sample plus N×N averages).
    static let sampleSizes = [1, 3, 5, 11, 31, 51, 101]

    struct Sample: Equatable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let x: Int
        let y: Int
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }

    enum Failure: LocalizedError, Equatable {
        case outsideCanvas, unavailableFrame, limitExceeded, missingRaster, renderFailed
        var errorDescription: String? {
            switch self {
            case .outsideCanvas: return "Tap inside the canvas to sample its artwork."
            case .unavailableFrame: return "That frame is no longer available. The drawing color has not changed."
            case .limitExceeded: return "Color sampling supports canvases up to 4,194,304 pixels. The drawing color has not changed."
            case .missingRaster: return "This frame's original image is unavailable for color sampling. The drawing color has not changed."
            case .renderFailed: return "Studio could not render this color sample. The drawing color has not changed."
            }
        }
    }

    /// Coordinates are in unzoomed document pixels with a top-left origin. A
    /// fractional location selects its containing pixel; outside input is never
    /// clamped onto unrelated artwork. Visible layers are sampled as composited.
    /// `sampleSize` > 1 averages the N×N block centred on that pixel, clipped
    /// to the canvas (PhotoCraft eyedropper). `layerID` restricts sampling to
    /// one visible layer over the white canvas (PhotoCraft "Current Layer").
    static func sample(document: StudioDocument, frameID: String, point: CGPoint,
                       rasterData: Data? = nil, rasterDataByID: [String: Data] = [:],
                       sampleSize: Int = 1, layerID: String? = nil) throws -> Sample {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < CGFloat(document.width), point.y < CGFloat(document.height) else {
            throw Failure.outsideCanvas
        }
        guard sampleSizes.contains(sampleSize) else { throw Failure.renderFailed }
        var document = document
        if let layerID {
            guard document.layers.contains(where: { $0.id == layerID }) else { throw Failure.unavailableFrame }
            for index in document.layers.indices where document.layers[index].id != layerID { document.layers[index].visible = false }
        }
        // Reject oversized/overflowing dimensions before rendering or allocation.
        guard (16...4096).contains(document.width), (16...4096).contains(document.height),
              document.width <= maximumPixels / document.height else { throw Failure.limitExceeded }
        try document.validate()
        guard let frame = document.frames.first(where: { $0.id == frameID }) else { throw Failure.unavailableFrame }
        let sources = try StudioFrameRenderer.resolvedRasterSources(frame: frame, legacyData: rasterData, sources: rasterDataByID)
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        for instance in frame.visibleRasterInstances(in: document.layers) {
            guard let id = frame.rasterAssetID(on: instance.layerID), sources[id] != nil else { throw Failure.missingRaster }
        }
        let images = try StudioFrameRenderer.prepareRasters(frame: frame, layers: document.layers,
            sourceData: sources, maximumDimension: 8192)
        for instance in frame.visibleRasterInstances(in: document.layers) {
            guard let id = frame.rasterAssetID(on: instance.layerID), sources[id] != nil, images[id] != nil else { throw Failure.missingRaster }
        }
        let size = CGSize(width: document.width, height: document.height)
        let smudges = try StudioSmudgeReplay.prepare(frame: frame, layers: document.layers, canvasSize: size,
            rasterData: rasterData, rasterDataByID: sources)
        var failure: Error?
        let canvas = Canvas { context, actual in
            context.fill(Path(CGRect(origin: .zero, size: actual)), with: .color(.white))
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: document.layers,
                canvasSize: size, size: actual, rasterData: rasterData,
                preparedBrushes: brushes, preparedSmudges: smudges, rasterSources: sources, preparedRasters: images)
        }.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage, image.width == document.width, image.height == document.height else {
            throw Failure.renderFailed
        }
        if let failure { throw failure }
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        let half = sampleSize / 2
        let block = CGRect(x: max(0, x - half), y: max(0, y - half),
                           width: min(document.width, x + half + 1) - max(0, x - half),
                           height: min(document.height, y + half + 1) - max(0, y - half))
        let w = Int(block.width), h = Int(block.height)
        guard w > 0, h > 0, let pixels = image.cropping(to: block),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.renderFailed }
        var rgba = [UInt8](repeating: 0, count: 4 * w * h)
        let decoded = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 4 * w, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard decoded else { throw Failure.renderFailed }
        var sum = (r: 0, g: 0, b: 0)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            guard rgba[index + 3] == 255 else { throw Failure.renderFailed }
            sum.r += Int(rgba[index]); sum.g += Int(rgba[index + 1]); sum.b += Int(rgba[index + 2])
        }
        let count = w * h
        func average(_ total: Int) -> UInt8 { UInt8(min(255, (total + count / 2) / count)) }
        return Sample(projectID: document.id, revision: document.revision, frameID: frame.id,
            x: x, y: y, red: average(sum.r), green: average(sum.g), blue: average(sum.b))
    }
}
