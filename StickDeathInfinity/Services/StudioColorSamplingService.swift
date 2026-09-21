import Foundation
import SwiftUI

/// Samples the canonical current artwork over the Studio's white canvas. Editor
/// guides, selection outlines and onion skin are not document artwork. No file,
/// document, history, playback, cloud or publication operation occurs here.
@MainActor
enum StudioColorSamplingService {
    static let maximumPixels = 4_194_304

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
    static func sample(document: StudioDocument, frameID: String, point: CGPoint,
                       rasterData: Data? = nil) throws -> Sample {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < CGFloat(document.width), point.y < CGFloat(document.height) else {
            throw Failure.outsideCanvas
        }
        // Reject oversized/overflowing dimensions before rendering or allocation.
        guard (16...4096).contains(document.width), (16...4096).contains(document.height),
              document.width <= maximumPixels / document.height else { throw Failure.limitExceeded }
        try document.validate()
        guard let frame = document.frames.first(where: { $0.id == frameID }) else { throw Failure.unavailableFrame }
        let visibleRaster = frame.rasterAssetID != nil && document.layers.contains {
            $0.id == frame.rasterLayerID && $0.visible && $0.opacity > 0
        }
        if visibleRaster && rasterData == nil { throw Failure.missingRaster }
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        let raster = try StudioFrameRenderer.prepareRaster(frame: frame, layers: document.layers,
            data: visibleRaster ? rasterData : nil, maximumDimension: 8192)
        if visibleRaster && raster == nil { throw Failure.missingRaster }
        let size = CGSize(width: document.width, height: document.height)
        var failure: Error?
        let canvas = Canvas { context, actual in
            context.fill(Path(CGRect(origin: .zero, size: actual)), with: .color(.white))
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: document.layers,
                canvasSize: size, size: actual, rasterData: visibleRaster ? rasterData : nil,
                preparedBrushes: brushes, preparedRaster: raster)
        }.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage, image.width == document.width, image.height == document.height else {
            throw Failure.renderFailed
        }
        if let failure { throw failure }
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.renderFailed }
        var rgba = [UInt8](repeating: 0, count: 4)
        let decoded = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard decoded, rgba[3] == 255 else { throw Failure.renderFailed }
        return Sample(projectID: document.id, revision: document.revision, frameID: frame.id,
            x: x, y: y, red: rgba[0], green: rgba[1], blue: rgba[2])
    }
}
