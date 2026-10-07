import Foundation
import SwiftUI

/// Captures real document artwork on the main actor; the bounded region
/// computation can then run off the UI thread without touching the editor.
enum StudioFillService {
    struct Capture: Sendable {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let width: Int
        let height: Int
        let x: Int
        let y: Int
        let selectedElementIDs: Set<String>
        let selectionCoverage: Data?
        let rgba: Data
        let color: String
        let opacity: Double
        let settings: StudioFillRegion.Settings
    }
    enum Failure: LocalizedError {
        case unavailable, selection, limit, missingRaster, render
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Fill needs an available frame and visible unlocked layer. Nothing has changed."
            case .selection: return "Selected coverage needs visible independent drawings. Layers containing erasers, alpha-preserving paint or pixel effects cannot be used yet. Nothing has changed."
            case .limit: return "Fill supports canvases up to 4,194,304 pixels. Nothing has changed."
            case .missingRaster: return "The original image needed for fill is unavailable. Nothing has changed."
            case .render: return "Studio could not read the artwork for fill. Nothing has changed."
            }
        }
    }

    @MainActor
    static func capture(document: StudioDocument, frameID: String, layerID: String,
                        point: CGPoint, color: String, opacity: Double,
                        settings: StudioFillRegion.Settings, sampleAllLayers: Bool,
                        rasterData: Data? = nil, rasterDataByID: [String: Data] = [:], selectedElementIDs: Set<String> = [], selectedImageLayerID: String? = nil) throws -> Capture {
        try Task.checkCancellation()
        guard (16...4096).contains(document.width), (16...4096).contains(document.height),
              document.width <= StudioFillRegion.maximumPixels / document.height else { throw Failure.limit }
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < CGFloat(document.width), point.y < CGFloat(document.height) else {
            throw StudioFillRegion.Failure.outsideCanvas
        }
        guard opacity.isFinite, (0...1).contains(opacity),
              (0...128).contains(settings.tolerance), (-5...5).contains(settings.expand),
              (0...5).contains(settings.gapClose) else { throw StudioFillRegion.Failure.invalidSettings }
        try StudioShapeDescriptor(fillColor: color).validate(tool: .rectangle)
        try document.validate()
        guard let frame = document.frames.first(where: { $0.id == frameID }),
              let target = document.layers.first(where: { $0.id == layerID }), target.visible,
              !target.isFullyLocked, ["free", "position"].contains(target.lockMode) else { throw Failure.unavailable }
        guard selectedImageLayerID == nil || selectedImageLayerID == layerID else { throw Failure.selection }
        let layers = sampleAllLayers ? document.layers : [target]
        let sources = try StudioFrameRenderer.resolvedRasterSources(frame: frame, legacyData: rasterData, sources: rasterDataByID)
        let coverage = try selectionCoverage(document: document, frame: frame, selectedIDs: selectedElementIDs, imageLayerID: selectedImageLayerID, sources: sources)
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        for instance in frame.visibleRasterInstances(in: layers) {
            guard let id = frame.rasterAssetID(on: instance.layerID), sources[id] != nil else { throw Failure.missingRaster }
        }
        let images = try StudioFrameRenderer.prepareRasters(frame: frame, layers: layers,
            sourceData: sources, maximumDimension: 8192)
        for instance in frame.visibleRasterInstances(in: layers) {
            guard let id = frame.rasterAssetID(on: instance.layerID), sources[id] != nil, images[id] != nil else { throw Failure.missingRaster }
        }
        let size = CGSize(width: document.width, height: document.height)
        let smudges = try StudioSmudgeReplay.prepare(frame: frame, layers: layers, canvasSize: size,
            rasterData: rasterData, rasterDataByID: sources)
        var failure: Error?
        let canvas = Canvas { context, actual in
            // The current layer keeps its transparent pixels distinct from
            // white paint. All-layer mode matches the visible white canvas.
            if sampleAllLayers {
                context.fill(Path(CGRect(origin: .zero, size: actual)), with: .color(.white))
            }
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: layers,
                canvasSize: size, size: actual, rasterData: rasterData,
                preparedBrushes: brushes, preparedSmudges: smudges, rasterSources: sources, preparedRasters: images)
        }.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1; renderer.isOpaque = sampleAllLayers
        guard let rendered = renderer.cgImage, rendered.width == document.width,
              rendered.height == document.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.render }
        if let failure { throw failure }
        var bytes = [UInt8](repeating: 0, count: document.width * document.height * 4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: document.width, height: document.height,
                bitsPerComponent: 8, bytesPerRow: document.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(rendered, in: CGRect(origin: .zero, size: size))
            return true
        }
        guard decoded else { throw Failure.render }
        // Tolerance uses straight RGBA rather than darkening partial-alpha
        // colors. Fully transparent pixels have canonical zero RGB channels.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let alpha = Int(bytes[i + 3])
            for c in 0..<3 {
                bytes[i + c] = alpha == 0 ? 0 : UInt8(min(255, (Int(bytes[i + c]) * 255 + alpha / 2) / alpha))
            }
        }
        try Task.checkCancellation()
        return Capture(projectID: document.id, revision: document.revision, frameID: frame.id,
            layerID: layerID, width: document.width, height: document.height,
            x: Int(point.x), y: Int(point.y), selectedElementIDs: selectedElementIDs,
            selectionCoverage: coverage, rgba: Data(bytes), color: color,
            opacity: opacity, settings: settings)
    }

    /// Source-body alpha only: layer opacity/glow/blending belong to the final
    /// paint layer, not to selection clipping. No raster or bounding-box proxy.
    @MainActor
    private static func selectionCoverage(document: StudioDocument, frame: AnimationFrame,
                                          selectedIDs: Set<String>, imageLayerID: String? = nil, sources: [String: Data] = [:]) throws -> Data? {
        guard !selectedIDs.isEmpty || imageLayerID != nil else { return nil }
        guard imageLayerID == nil || selectedIDs.isEmpty else { throw Failure.selection }
        guard selectedIDs.count <= 1024 else { throw Failure.selection }
        let elements = frame.elements.filter { selectedIDs.contains($0.id) }
        guard elements.count == selectedIDs.count else { throw Failure.selection }
        let owners = imageLayerID.map { Set([$0]) } ?? Set(elements.compactMap(\.layerID))
        var layers = document.layers.filter { owners.contains($0.id) }
        guard layers.count == owners.count, elements.allSatisfy({ element in
            [.pencil, .pen, .brush, .marker, .crayon, .line, .rectangle, .circle, .text, .fill].contains(element.tool)
                && element.layerID != nil
        }), layers.allSatisfy({ $0.visible && $0.opacity > 0 }) else { throw Failure.selection }
        // Replaying an isolated selection without these ordered operations would
        // fabricate source coverage that the user cannot currently see.
        guard !frame.elements.contains(where: { element in
            owners.contains(element.layerID ?? "") && (element.tool == .eraser || element.eraser != nil
                || element.hasPixelEffect || element.preservesLayerAlpha == true)
        }) else { throw Failure.selection }
        for index in layers.indices {
            layers[index].opacity = 1; layers[index].blendMode = "normal"; layers[index].glowEnabled = false
        }
        try Task.checkCancellation()
        var isolated = AnimationFrame(id: frame.id, elements: elements)
        if let imageLayerID {
            guard let instance = frame.rasterInstance(on: imageLayerID), instance.placement != nil,
                  let sourceID = frame.rasterAssetID(on: imageLayerID), sources[sourceID] != nil,
                  let projected = frame.projectedRasterFrame(on: imageLayerID) else { throw Failure.missingRaster }
            isolated = projected; isolated.elements = []
        }
        let images = try StudioFrameRenderer.prepareRasters(frame: isolated, layers: layers, sourceData: sources, maximumDimension: 8192)
        let prepared = try StudioFrameRenderer.prepare(frame: isolated)
        let size = CGSize(width: document.width, height: document.height)
        var failure: Error?
        let renderer = ImageRenderer(content: Canvas { context, actual in
            failure = StudioFrameRenderer.draw(context: &context, frame: isolated, layers: layers,
                canvasSize: size, size: actual, preparedBrushes: prepared, rasterSources: sources, preparedRasters: images)
        }.frame(width: size.width, height: size.height))
        renderer.scale = 1; renderer.isOpaque = false
        guard let image = renderer.cgImage, image.width == document.width, image.height == document.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.render }
        if let failure { throw failure }
        var rgba = [UInt8](repeating: 0, count: document.width * document.height * 4)
        let decoded = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: document.width, height: document.height,
                bitsPerComponent: 8, bytesPerRow: document.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy); context.draw(image, in: CGRect(origin: .zero, size: size)); return true
        }
        guard decoded else { throw Failure.render }
        var alpha = Data(count: document.width * document.height)
        for index in 0..<alpha.count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            alpha[index] = rgba[index * 4 + 3]
        }
        try Task.checkCancellation()
        return alpha
    }

    /// Does not commit. The caller must recheck captured editor ownership after
    /// background computation, then use the same canonical editor transaction.
    static func element(from capture: Capture, id: String = UUID().uuidString) throws -> DrawnElement {
        let region = try StudioFillRegion.compute(rgba: capture.rgba, width: capture.width,
            height: capture.height, x: capture.x, y: capture.y, settings: capture.settings, selectionCoverage: capture.selectionCoverage)
        guard region.spans.count <= StudioFillMask.maximumSpans else { throw StudioFillMask.Failure.invalid }
        let mask = StudioFillMask(width: region.width, height: region.height,
            spans: region.spans.map { .init(row: $0.row, start: $0.start, end: $0.end, alpha: $0.alpha) })
        try mask.validate()
        let left = mask.spans.map(\.start).min()!, right = mask.spans.map(\.end).max()!
        let top = mask.spans.first!.row, bottom = mask.spans.last!.row + 1
        try Task.checkCancellation()
        return DrawnElement(id: id, tool: .fill,
            points: [.init(x: CGFloat(left), y: CGFloat(top)), .init(x: CGFloat(right), y: CGFloat(bottom))],
            color: capture.color, width: 1, opacity: capture.opacity, layerID: capture.layerID, fillMask: mask)
    }
}
