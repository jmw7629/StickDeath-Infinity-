import Foundation
import CoreGraphics

/// Read-only capture for a future atomic smudge edit. Raw layer pixels use the
/// actual Studio compositor; layer opacity, glow and blending are applied by
/// the compositor after the edited pixels, not baked into them a second time.
@MainActor
enum StudioSmudgeCapture {
    struct Capture {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let pixels: StudioSmudge.Pixels

        func isCurrent(_ document: StudioDocument, selection: Set<String>) -> Bool {
            document.id == projectID && document.revision == revision &&
            document.activeFrameID == frameID && document.activeLayerID == layerID &&
            document.width == pixels.width && document.height == pixels.height && selection.isEmpty &&
            document.layers.contains { $0.id == layerID && $0.visible && $0.opacity > 0 &&
                !$0.isFullyLocked && $0.lockMode == "free" }
        }
    }
    static func capture(document: StudioDocument, selection: Set<String>, raster: Data?) throws -> Capture {
        try Task.checkCancellation(); try document.validate()
        guard selection.isEmpty else {
            throw StudioDocumentError.unavailable("Smudging within a selection is not available yet. Deselect artwork first; nothing changed.")
        }
        guard let layer = document.layers.first(where: { $0.id == document.activeLayerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
            throw StudioDocumentError.locked
        }
        guard document.width <= StudioSmudge.maximumPixels / document.height,
              let frame = document.frames.first(where: { $0.id == document.activeFrameID }) else {
            throw StudioSmudge.Failure.invalidImage
        }
        if frame.rasterLayerID == layer.id, frame.rasterAssetID != nil, raster == nil {
            throw StudioRasterImage.Failure.missing
        }
        var isolated = document
        isolated.layers = document.layers.map { value in
            var copy = value; copy.visible = copy.id == layer.id
            if copy.visible { copy.opacity = 1; copy.blendMode = "normal"; copy.glowEnabled = false }
            return copy
        }
        let rendered = try StudioExportService().render(frame, document: isolated, background: .transparent, raster: raster)
        try Task.checkCancellation()
        var bytes = [UInt8](repeating: 0, count: rendered.width*rendered.height*4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: rendered.width, height: rendered.height,
                bitsPerComponent: 8, bytesPerRow: rendered.width*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(rendered, in: CGRect(x: 0,y: 0,width: rendered.width,height: rendered.height))
            return true
        }
        guard decoded else { throw StudioSmudge.Failure.invalidImage }
        try Task.checkCancellation()
        return Capture(projectID: document.id, revision: document.revision,
            frameID: document.activeFrameID, layerID: document.activeLayerID,
            pixels: try .init(width: rendered.width,height: rendered.height,rgba: bytes))
    }
}
