import Foundation
import CoreGraphics

/// Read-only active-layer capture for an atomic editable Blur operation.
/// Layer appearance is applied after pixel processing, never baked in twice.
@MainActor
enum StudioBlurCapture {
    struct Capture {
        let projectID: UUID
        let revision: Int
        let frameID: String
        let layerID: String
        let pixels: StudioBlur.Pixels

        func isCurrent(_ document: StudioDocument, selection: Set<String>) -> Bool {
            document.id == projectID && document.revision == revision &&
            document.activeFrameID == frameID && document.activeLayerID == layerID &&
            document.width == pixels.width && document.height == pixels.height && selection.isEmpty &&
            document.layers.contains { $0.id == layerID && $0.visible && $0.opacity > 0 &&
                !$0.isFullyLocked && $0.lockMode == "free" }
        }
    }

    static func capture(document: StudioDocument, selection: Set<String>, raster: Data?) throws -> Capture {
        try Task.checkCancellation()
        try document.validate()
        // The pixel engine accepts coverage masks, but editable selection-mask
        // persistence is not connected yet. Never silently affect unselected art.
        guard selection.isEmpty else {
            throw StudioDocumentError.unavailable("Blurring within a selection is not available yet. Deselect artwork first; nothing changed.")
        }
        guard let layer = document.layers.first(where: { $0.id == document.activeLayerID }),
              layer.visible, layer.opacity > 0, !layer.isFullyLocked, layer.lockMode == "free" else {
            throw StudioDocumentError.locked
        }
        guard document.width <= StudioBlur.maximumPixels / document.height,
              let frame = document.frames.first(where: { $0.id == document.activeFrameID }) else {
            throw StudioBlur.Failure.invalidImage
        }
        if frame.rasterInstance(on: layer.id) != nil, raster == nil {
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
        var bytes = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
        let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: rendered.width, height: rendered.height,
                    bitsPerComponent: 8, bytesPerRow: rendered.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
            return true
        }
        guard decoded else { throw StudioBlur.Failure.invalidImage }
        try Task.checkCancellation()
        return Capture(projectID: document.id, revision: document.revision,
            frameID: document.activeFrameID, layerID: document.activeLayerID,
            pixels: try .init(width: rendered.width, height: rendered.height, rgba: bytes))
    }
}
