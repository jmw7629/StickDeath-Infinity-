import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Image export of the same canonical document/compositor as the live Studio.
/// PNG has no audio; FPS and frame order are recorded in the adjacent manifest.
/// No Photos, network, publication, entitlement or video-export side effects.
@MainActor
final class StudioExportService {
    enum Format: String, Codable { case pngSequence, spritesheet }
    enum Background: String, Codable { case white, transparent }

    struct FrameRecord: Codable, Equatable {
        let index: Int
        let id: String
        let filename: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    struct Manifest: Codable {
        let version: Int
        let projectID: UUID
        let documentRevision: Int
        let format: Format
        let background: Background
        let fps: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let imageWidth: Int
        let imageHeight: Int
        let audioIncluded: Bool
        let editorGuidesIncluded: Bool
        let frames: [FrameRecord]
    }
    struct Output {
        let directory: URL
        let imageURLs: [URL]
        let manifestURL: URL
        let manifest: Manifest
    }

    // Bounded first image-export slice. No silent resizing, dropped frames or
    // unbounded frame-image array. A sheet uses one bitmap plus one frame image.
    static let maximumFrames = 240
    static let maximumFramePixels = 4_194_304
    static let maximumSheetPixels = 16_777_216
    static let maximumTotalPixels = 134_217_728
    static let maximumOutputBytes = 256 * 1024 * 1024
    private static var exportInProgress = false

    /// outputParent must be an existing app-owned cache/temporary directory.
    /// Pass immutable project-managed raster bytes, never a URL from picker state.
    /// Progress counts rendered frames; only the returned Output means success.
    func export(document: StudioDocument, format: Format, outputParent: URL,
                background: Background = .white,
                rasterData: (String) throws -> Data? = { _ in nil },
                progress: (Int, Int) -> Void = { _, _ in }) async throws -> Output {
        try Task.checkCancellation()
        guard !Self.exportInProgress else { throw ExportError.alreadyExporting }
        Self.exportInProgress = true
        defer { Self.exportInProgress = false }
        try validate(document)
        let columns = format == .spritesheet ? Int(ceil(sqrt(Double(document.frames.count)))) : 1
        let rows = format == .spritesheet ? (document.frames.count + columns - 1) / columns : 1
        let width = document.width * columns, height = document.height * rows
        if format == .spritesheet {
            guard width <= 8192, height <= 8192, width * height <= Self.maximumSheetPixels else { throw ExportError.limitExceeded }
        }
        let fm = FileManager.default
        guard outputParent.isFileURL else { throw ExportError.unsafeDestination }
        let parent = outputParent.standardizedFileURL
        let attributes = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ExportError.unsafeDestination }
        let identifier = UUID().uuidString
        let staging = parent.appendingPathComponent(".sdi-export-" + identifier + ".partial", isDirectory: true)
        let destination = parent.appendingPathComponent("SDI-" + document.id.uuidString + "-" + identifier, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var sheet: CGContext?
            if format == .spritesheet {
                sheet = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                guard sheet != nil else { throw ExportError.renderFailed }
                if background == .white {
                    sheet!.setFillColor(CGColor(gray: 1, alpha: 1))
                    sheet!.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            var records: [FrameRecord] = []
            var filenames: [String] = []
            var outputBytes = 0
            for (index, frame) in document.frames.enumerated() {
                try Task.checkCancellation()
                let name = format == .pngSequence ? String(format: "frame_%06d.png", index) : "spritesheet.png"
                let x = format == .spritesheet ? (index % columns) * document.width : 0
                let y = format == .spritesheet ? (index / columns) * document.height : 0
                try autoreleasepool {
                    let raster: Data?
                    let rasterVisible = document.layers.contains { $0.id == frame.rasterLayerID && $0.visible && $0.opacity > 0 }
                    if rasterVisible, let asset = frame.rasterAssetID {
                        guard let bytes = try rasterData(asset) else { throw ExportError.missingRaster }
                        try validateRaster(bytes)
                        raster = bytes
                    } else { raster = nil }
                    let image = try render(frame, document: document, background: background, raster: raster)
                    if let sheet {
                        sheet.draw(image, in: CGRect(x: x, y: height - y - document.height,
                            width: document.width, height: document.height))
                    } else {
                        outputBytes += try writePNG(image, to: staging.appendingPathComponent(name))
                        guard outputBytes <= Self.maximumOutputBytes else { throw ExportError.limitExceeded }
                    }
                }
                records.append(FrameRecord(index: index, id: frame.id, filename: name, x: x, y: y,
                    width: document.width, height: document.height))
                if format == .pngSequence { filenames.append(name) }
                progress(index + 1, document.frames.count)
                // The UI can cancel between frames; completed render resources
                // leave the autorelease pool before the next frame starts.
                await Task.yield()
            }
            try Task.checkCancellation()
            if let sheet {
                try autoreleasepool {
                    guard let image = sheet.makeImage() else { throw ExportError.renderFailed }
                    outputBytes = try writePNG(image, to: staging.appendingPathComponent("spritesheet.png"))
                    guard outputBytes <= Self.maximumOutputBytes else { throw ExportError.limitExceeded }
                }
                filenames = ["spritesheet.png"]
            }
            let manifest = Manifest(version: 1, projectID: document.id, documentRevision: document.revision,
                format: format, background: background, fps: document.fps,
                canvasWidth: document.width, canvasHeight: document.height,
                imageWidth: width, imageHeight: height, audioIncluded: false,
                editorGuidesIncluded: false, frames: records)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try Task.checkCancellation()
            // Same-parent rename publishes all files together, without replacing
            // another export or touching the source project. No mutation follows.
            try fm.moveItem(at: staging, to: destination)
            return Output(directory: destination, imageURLs: filenames.map { destination.appendingPathComponent($0) },
                manifestURL: destination.appendingPathComponent("manifest.json"), manifest: manifest)
        } catch {
            do { try fm.removeItem(at: staging) }
            catch { throw ExportError.cleanupFailed(staging) }
            throw error
        }
    }

    private func render(_ frame: AnimationFrame, document: StudioDocument,
                        background: Background, raster: Data?) throws -> CGImage {
        let size = CGSize(width: document.width, height: document.height)
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        var drawingError: Error?
        let content = Canvas { context, actual in
            if background == .white { context.fill(Path(CGRect(origin: .zero, size: actual)), with: .color(.white)) }
            drawingError = StudioFrameRenderer.draw(context: &context, frame: frame, layers: document.layers,
                canvasSize: size, size: actual, rasterData: raster, preparedBrushes: brushes)
        }.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = background == .white
        guard let image = renderer.cgImage, image.width == document.width, image.height == document.height else {
            throw ExportError.renderFailed
        }
        if let drawingError { throw drawingError }
        return image
    }

    private func writePNG(_ image: CGImage, to url: URL) throws -> Int {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ExportError.encodeFailed }
        return size
    }

    private func validate(_ document: StudioDocument) throws {
        try document.validate()
        let pixels = document.width * document.height
        guard document.frames.count <= Self.maximumFrames, pixels <= Self.maximumFramePixels,
              pixels * document.frames.count <= Self.maximumTotalPixels else { throw ExportError.limitExceeded }
        let tools: Set<DrawingTool> = [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle, .text]
        let blends: Set<String> = ["normal", "multiply", "screen", "overlay", "darken", "lighten"]
        func validColor(_ value: String) -> Bool {
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            return hex.utf8.count == 6 && hex.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        }
        let renderedLayers = document.layers.filter { $0.visible && $0.opacity > 0 }
        let renderedLayerIDs = Set(renderedLayers.map(\.id))
        for layer in renderedLayers {
            guard blends.contains(layer.blendMode.lowercased()) else { throw ExportError.unsupportedContent }
            if layer.glowEnabled, let color = layer.glowColor, !validColor(color) { throw ExportError.invalidColor }
        }
        for frame in document.frames {
            for element in frame.elements where element.opacity > 0 && element.layerID.map(renderedLayerIDs.contains) == true {
                guard tools.contains(element.tool) else { throw ExportError.unsupportedContent }
                guard validColor(element.color) else { throw ExportError.invalidColor }
                if element.tool == .text {
                    guard let text = element.fillColor, !text.isEmpty, text.utf8.count <= 4096 else { throw ExportError.unsupportedContent }
                }
            }
        }
    }

    private func validateRaster(_ data: Data) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw ExportError.limitExceeded }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ExportError.invalidRaster }
        guard width <= 8192, height <= 8192, width * height <= Self.maximumSheetPixels else { throw ExportError.limitExceeded }
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
            throw ExportError.invalidRaster
        }
        guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ExportError.invalidRaster
        }
    }

    enum ExportError: LocalizedError {
        case limitExceeded, unsafeDestination, renderFailed, encodeFailed, missingRaster, invalidRaster, unsupportedContent, invalidColor, alreadyExporting
        case cleanupFailed(URL)
        var errorDescription: String? {
            switch self {
            case .limitExceeded: return "This PNG export exceeds the current safe frame, image or output size limit. Use a smaller project; no partial export was published."
            case .unsafeDestination: return "Choose an existing app-owned export directory without symbolic links."
            case .renderFailed: return "Studio could not render the requested image. No export was published."
            case .encodeFailed: return "The PNG file could not be written. No export was published."
            case .missingRaster: return "An original project image is unavailable. No export was published."
            case .invalidRaster: return "An original project image cannot be decoded. No export was published."
            case .unsupportedContent: return "This document contains a tool or blend effect that PNG export cannot faithfully render yet."
            case .invalidColor: return "A drawing or glow color is invalid. No PNG export was published."
            case .alreadyExporting: return "An image export is already running. Wait for it or cancel it before starting another."
            case .cleanupFailed: return "Export failed and its temporary output could not be removed. Temporary export cleanup is required."
            }
        }
    }
}
