import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Image export of the same canonical document/compositor as the live Studio.
/// PNG has no audio; FPS and frame order are recorded in the adjacent manifest.
/// No Photos, network, publication, entitlement or video-export side effects.
@MainActor
final class StudioExportService {
    enum Format: String, Codable { case pngSequence, spritesheet }
    enum Background: String, Codable { case white, transparent }
    /// Output scale relative to the canvas (#184). The compositor draws vectors
    /// and placed rasters at the output size; nothing is resampled afterwards.
    enum Scale: String, Codable, CaseIterable {
        case half, original, double
        var factor: Double { self == .half ? 0.5 : self == .double ? 2 : 1 }
        var label: String { self == .half ? "50%" : self == .double ? "200%" : "100%" }
    }

    struct FrameRecord: Codable, Equatable {
        let index: Int
        let id: String
        let filename: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        var startTick: Int? = nil
        var durationTicks: Int? = nil
        var sourceFrameIndex: Int? = nil
        /// Present only for separate-layer passes (#184): which layer this image shows.
        var layerID: String? = nil
        var layerName: String? = nil
        var layerIndex: Int? = nil
    }
    /// Metadata only. The panel validates the preserved original's digest
    /// before constructing this value; no original bytes enter the manifest.
    struct ImageCredit: Codable, Equatable {
        let assetID: String
        let author: String
        let sourceURL: String
        let license: String
        let licenseURL: String
        let attribution: String
        let originalSHA256: String
        let sourceArchiveSHA256: String

        init(attribution values: [String: String]) throws {
            try Self.check(values)
            assetID = values["assetID"]!; author = values["author"]!; sourceURL = values["sourceURL"]!
            license = values["license"]!; licenseURL = values["licenseURL"]!; attribution = values["attribution"]!
            originalSHA256 = values["originalSHA256"]!; sourceArchiveSHA256 = values["sourceArchiveSHA256"]!
        }
        func validate() throws {
            try Self.check(["assetID": assetID, "author": author, "sourceURL": sourceURL,
                "license": license, "licenseURL": licenseURL, "attribution": attribution,
                "originalSHA256": originalSHA256, "sourceArchiveSHA256": sourceArchiveSHA256])
        }
        private static func check(_ values: [String: String]) throws {
            let keys: Set<String> = ["assetID", "author", "sourceURL", "license", "licenseURL",
                "attribution", "originalSHA256", "sourceArchiveSHA256"]
            func digest(_ text: String?) -> Bool {
                guard let text else { return false }
                return text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
            guard Set(values.keys) == keys,
                  values.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2400 && $0.count <= 600 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                  values["license"] == "CC0-1.0", values["licenseURL"] == "https://creativecommons.org/publicdomain/zero/1.0/",
                  digest(values["originalSHA256"]), digest(values["sourceArchiveSHA256"]),
                  let source = values["sourceURL"].flatMap(URL.init(string:)), source.scheme == "https", source.host == "kenney.nl",
                  source.user == nil, source.password == nil, source.port == nil, source.query == nil, source.fragment == nil,
                  source.path.hasPrefix("/assets/") else { throw ExportError.invalidImageCredit }
        }
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
        var imageCredits: [ImageCredit]? = nil
        var sheetColumns: Int? = nil
        var cellPadding: Int? = nil
        /// Sanitized project-name base used for the image filenames (nil = legacy names).
        var filenameBase: String? = nil
        /// Output scale relative to the canvas; nil means the original size (#184).
        var scale: Scale? = nil
        /// True when every frame was written once per visible layer (#184).
        var separateLayers: Bool? = nil
        var layerCount: Int? = nil
    }
    struct Output {
        let directory: URL
        let imageURLs: [URL]
        let manifestURL: URL
        let manifest: Manifest
    }

    // Images stream to disk one at a time, so the image cap bounds time, not
    // memory (#182/#184): 1,440 images (frames × layer passes) at up to 1080p.
    // A sheet uses one bitmap plus one frame image and keeps its own pixel cap.
    static let maximumFrames = 1440
    static let maximumFramePixels = 4_194_304
    static let maximumSheetPixels = 16_777_216
    static let maximumTotalPixels = 2_985_984_000
    static let maximumOutputBytes = 256 * 1024 * 1024
    private static var exportInProgress = false

    /// One credit policy for every rendered format. Callers return this metadata
    /// only after every referenced visible raster has successfully rendered.
    static func renderedImageCredits(document: StudioDocument,
                                     creditsByRasterID: [String: ImageCredit]) throws -> [ImageCredit] {
        guard creditsByRasterID.count <= maximumFrames else { throw ExportError.limitExceeded }
        let used = visibleRasterAssetIDs(document: document)
        guard used.count <= maximumFrames else { throw ExportError.limitExceeded }
        var result: [ImageCredit] = []
        for asset in used.sorted() {
            try Task.checkCancellation()
            guard let credit = creditsByRasterID[asset] else { continue }
            try credit.validate()
            if result.contains(where: { $0.assetID == credit.assetID && $0.originalSHA256 == credit.originalSHA256 && $0 != credit }) {
                throw ExportError.invalidImageCredit
            }
            if !result.contains(credit) { result.append(credit) }
        }
        return result.sorted {
            if $0.assetID != $1.assetID { return $0.assetID < $1.assetID }
            if $0.originalSHA256 != $1.originalSHA256 { return $0.originalSHA256 < $1.originalSHA256 }
            return $0.sourceArchiveSHA256 < $1.sourceArchiveSHA256
        }
    }

    static func visibleRasterAssetIDs(document: StudioDocument) -> Set<String> {
        Set(document.frames.flatMap { frame in
            frame.visibleRasterInstances(in: document.layers).compactMap { frame.rasterAssetID(on: $0.layerID) }
        })
    }

    /// Bound unique source decoding across the snapshot, not once per linked copy.
    func validateRasterSources(document: StudioDocument, sources: [String: Data]) throws {
        let references = Self.visibleRasterAssetIDs(document: document)
        guard sources.count <= Self.maximumFrames, references.count <= Self.maximumFrames else { throw ExportError.limitExceeded }
        var bytes = 0, pixels = 0
        for (id, data) in sources {
            try Task.checkCancellation()
            guard !id.isEmpty, id.utf8.count <= 128, data.count <= 64 * 1024 * 1024 - bytes else { throw ExportError.limitExceeded }
            bytes += data.count
        }
        for id in references.sorted() {
            try Task.checkCancellation()
            guard let data = sources[id] else { throw ExportError.missingRaster }
            let count = try validateRaster(data)
            guard count <= 32 * 1024 * 1024 - pixels else { throw ExportError.limitExceeded }
            pixels += count
        }
    }

    /// outputParent must be an existing app-owned cache/temporary directory.
    /// Pass immutable project-managed raster bytes, never a URL from picker state.
    /// Progress counts rendered frames; only the returned Output means success.
    func export(document original: StudioDocument, format: Format, outputParent: URL,
                background: Background = .white,
                sheetColumns: Int? = nil, cellPadding: Int = 0, frameIDs: Set<String>? = nil,
                imageCredits: [String: ImageCredit] = [:], filenameBase: String? = nil,
                scale: Scale = .original, separateLayers: Bool = false,
                watermark: Bool = false,
                rasterData: (String) throws -> Data? = { _ in nil },
                progress: (Int, Int) -> Void = { _, _ in }) async throws -> Output {
        try Task.checkCancellation()
        guard !Self.exportInProgress else { throw ExportError.alreadyExporting }
        Self.exportInProgress = true
        defer { Self.exportInProgress = false }
        if let filenameBase { guard StudioExportFilename.isValid(filenameBase) else { throw ExportError.invalidFilename } }
        // Legacy names stay when no base is supplied; the panel passes the
        // sanitized project name so shared files are recognizable (#185).
        let sheetName = filenameBase.map { $0 + "_spritesheet.png" } ?? "spritesheet.png"
        let frameFormat = filenameBase.map { $0 + "_%06d.png" } ?? "frame_%06d.png"
        let layerFormat = (filenameBase ?? "frame") + "_%06d_L%02d.png"
        try original.validate()
        // Reference layers (imported video frames for tracing) never render (#200).
        var document = original.hidingReferenceLayers
        let originalIndices = Dictionary(uniqueKeysWithValues: original.frames.enumerated().map { ($0.element.id, $0.offset) })
        if let frameIDs {
            guard !frameIDs.isEmpty, frameIDs.isSubset(of: Set(originalIndices.keys)) else { throw ExportError.limitExceeded }
            document.frames = document.frames.filter { frameIDs.contains($0.id) }
            document.activeFrameID = document.frames[0].id
        }
        try validate(document)
        guard (0...32).contains(cellPadding),
              sheetColumns.map({ (1...document.frames.count).contains($0) }) ?? true,
              format == .spritesheet || (sheetColumns == nil && cellPadding == 0) else {
            throw ExportError.limitExceeded
        }
        // One pass per visible layer writes every frame once per layer (#184);
        // the sheet keeps its single composite image.
        let layerPasses: [CanvasLayer?]
        if separateLayers {
            guard format == .pngSequence else { throw ExportError.unsupportedOption }
            let rendered = document.layers.filter { $0.visible && $0.opacity > 0 }
            guard !rendered.isEmpty else { throw ExportError.unsupportedOption }
            layerPasses = rendered
        } else { layerPasses = [nil] }
        let frameWidth = max(1, Int((Double(document.width) * scale.factor).rounded(.down)))
        let frameHeight = max(1, Int((Double(document.height) * scale.factor).rounded(.down)))
        let imageCount = document.frames.count * layerPasses.count
        guard frameWidth <= 8192, frameHeight <= 8192, frameWidth * frameHeight <= Self.maximumFramePixels,
              imageCount <= Self.maximumFrames, frameWidth * frameHeight * imageCount <= Self.maximumTotalPixels else {
            throw ExportError.limitExceeded
        }
        guard imageCredits.count <= Self.maximumFrames else { throw ExportError.limitExceeded }
        var sources: [String: Data] = [:]
        let sourceIDs = Self.visibleRasterAssetIDs(document: document)
        guard sourceIDs.count <= Self.maximumFrames else { throw ExportError.limitExceeded }
        var capturedBytes = 0
        for id in sourceIDs.sorted() {
            try Task.checkCancellation()
            guard let bytes = try rasterData(id) else { throw ExportError.missingRaster }
            guard bytes.count <= 64 * 1024 * 1024 - capturedBytes else { throw ExportError.limitExceeded }
            capturedBytes += bytes.count; sources[id] = bytes
        }
        try validateRasterSources(document: document, sources: sources)
        let columns = format == .spritesheet ? (sheetColumns ?? Int(ceil(sqrt(Double(document.frames.count))))) : 1
        let rows = format == .spritesheet ? (document.frames.count + columns - 1) / columns : 1
        let cellWidth = frameWidth + 2 * cellPadding, cellHeight = frameHeight + 2 * cellPadding
        let width = cellWidth * columns, height = cellHeight * rows
        let outputSize = CGSize(width: frameWidth, height: frameHeight)
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
            var outputBytes = 0, written = 0
            for (index, frame) in document.frames.enumerated() {
                for (passIndex, layer) in layerPasses.enumerated() {
                try Task.checkCancellation()
                let name: String
                if layer != nil { name = String(format: layerFormat, index, passIndex + 1) }
                else { name = format == .pngSequence ? String(format: frameFormat, index) : sheetName }
                let x = format == .spritesheet ? (index % columns) * cellWidth + cellPadding : 0
                let y = format == .spritesheet ? (index / columns) * cellHeight + cellPadding : 0
                // A layer pass renders the same frame with every other layer hidden.
                var passDocument = document
                if let layer {
                    for position in passDocument.layers.indices { passDocument.layers[position].visible = passDocument.layers[position].id == layer.id }
                }
                try autoreleasepool {
                    let rendered = try render(frame, document: passDocument, background: background, raster: nil, rasterDataByID: sources, outputSize: outputSize)
                    // Free-plan mark on each exported frame (never on the project).
                    let image = try watermark ? Self.watermarked(rendered) : rendered
                    if let sheet {
                        sheet.draw(image, in: CGRect(x: x, y: height - y - frameHeight,
                            width: frameWidth, height: frameHeight))
                    } else {
                        outputBytes += try writePNG(image, to: staging.appendingPathComponent(name))
                        guard outputBytes <= Self.maximumOutputBytes else { throw ExportError.limitExceeded }
                    }
                }
                var record = FrameRecord(index: index, id: frame.id, filename: name, x: x, y: y,
                    width: frameWidth, height: frameHeight,
                    startTick: document.schemaVersion >= 21 ? document.startTick(ofFrame: index) : nil,
                    durationTicks: document.schemaVersion >= 21 ? frame.durationTicks : nil,
                    sourceFrameIndex: frameIDs == nil ? nil : originalIndices[frame.id])
                if let layer { record.layerID = layer.id; record.layerName = layer.name; record.layerIndex = passIndex }
                records.append(record)
                if format == .pngSequence { filenames.append(name) }
                written += 1
                progress(written, imageCount)
                // The UI can cancel between frames; completed render resources
                // leave the autorelease pool before the next frame starts.
                await Task.yield()
                }
            }
            try Task.checkCancellation()
            if let sheet {
                try autoreleasepool {
                    guard let image = sheet.makeImage() else { throw ExportError.renderFailed }
                    outputBytes = try writePNG(image, to: staging.appendingPathComponent(sheetName))
                    guard outputBytes <= Self.maximumOutputBytes else { throw ExportError.limitExceeded }
                }
                filenames = [sheetName]
            }
            let renderedCredits = try Self.renderedImageCredits(document: document, creditsByRasterID: imageCredits)
            let customLayout = format == .spritesheet && (sheetColumns != nil || cellPadding != 0)
            let customRendering = scale != .original || separateLayers
            let manifest = Manifest(version: customRendering ? 6 : frameIDs != nil ? 5 : customLayout ? 4 : renderedCredits.isEmpty ? (document.schemaVersion >= 21 ? 2 : 1) : 3, projectID: document.id, documentRevision: document.revision,
                format: format, background: background, fps: document.fps,
                canvasWidth: document.width, canvasHeight: document.height,
                imageWidth: width, imageHeight: height, audioIncluded: false,
                editorGuidesIncluded: false, frames: records, imageCredits: renderedCredits.isEmpty ? nil : renderedCredits,
                sheetColumns: customLayout ? columns : nil, cellPadding: customLayout ? cellPadding : nil,
                filenameBase: filenameBase, scale: scale == .original ? nil : scale,
                separateLayers: separateLayers ? true : nil, layerCount: separateLayers ? layerPasses.count : nil)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestBytes = try encoder.encode(manifest)
            guard manifestBytes.count <= 8 * 1024 * 1024,
                  manifestBytes.count <= Self.maximumOutputBytes - outputBytes else { throw ExportError.limitExceeded }
            try manifestBytes.write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
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

    func render(_ frame: AnimationFrame, document: StudioDocument,
                        background: Background, raster: Data?, thumbnail: Bool = false,
                        rasterDataByID: [String: Data] = [:], maximumDimension: Int? = nil,
                        outputSize: CGSize? = nil) throws -> CGImage {
        let size = CGSize(width: document.width, height: document.height)
        if let maximumDimension, !(1...4096).contains(maximumDimension) { throw ExportError.renderFailed }
        let limit = thumbnail ? 256 : maximumDimension
        let ratio = limit.map { min(1, CGFloat($0) / max(size.width, size.height)) } ?? 1
        var output = CGSize(width: max(1, floor(size.width * ratio)), height: max(1, floor(size.height * ratio)))
        if let outputSize {
            guard outputSize.width >= 1, outputSize.height >= 1, outputSize.width <= 8192, outputSize.height <= 8192,
                  outputSize.width == outputSize.width.rounded(), outputSize.height == outputSize.height.rounded() else { throw ExportError.renderFailed }
            output = outputSize
        }
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        var sources = rasterDataByID
        if let id = frame.rasterAssetID, let raster, sources[id] == nil { sources[id] = raster }
        let images = try StudioFrameRenderer.prepareRasters(frame: frame, layers: document.layers, sourceData: sources)
        let smudges = try StudioSmudgeReplay.prepare(frame: frame, layers: document.layers,
            canvasSize: size, rasterData: raster, rasterDataByID: sources)
        var drawingError: Error?
        let content = Canvas { context, actual in
            if background == .white { context.fill(Path(CGRect(origin: .zero, size: actual)), with: .color(.white)) }
            drawingError = StudioFrameRenderer.draw(context: &context, frame: frame, layers: document.layers,
                canvasSize: size, size: actual, rasterData: raster, preparedBrushes: brushes, preparedSmudges: smudges, rasterSources: sources, preparedRasters: images)
        }.frame(width: output.width, height: output.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = background == .white
        guard let image = renderer.cgImage, image.width == Int(output.width), image.height == Int(output.height) else {
            throw ExportError.renderFailed
        }
        if let drawingError { throw drawingError }
        return image
    }

    func projectThumbnail(document: StudioDocument, raster: Data?, rasterDataByID: [String: Data] = [:]) throws -> Data {
        try document.validate()
        guard let frame = document.frames.first else { throw ExportError.renderFailed }
        let image = try render(frame, document: document, background: .white, raster: raster, thumbnail: true, rasterDataByID: rasterDataByID)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 512 * 1024 else { throw ExportError.encodeFailed }
        return data as Data
    }

    private func writePNG(_ image: CGImage, to url: URL) throws -> Int {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodeFailed }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ExportError.encodeFailed }
        // Reopen the file that was actually written and prove it decodes back to
        // the rendered pixel size (#184). A finalized-but-damaged PNG fails here.
        try Self.verifyPNG(at: url, expectedWidth: image.width, expectedHeight: image.height)
        return size
    }

    /// Decode-back check for one written PNG: exactly one complete PNG image
    /// whose declared and decoded sizes equal the rendered bitmap.
    static func verifyPNG(at url: URL, expectedWidth: Int, expectedHeight: Int) throws {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width == expectedWidth, height == expectedHeight else { throw ExportError.verificationFailed }
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  decoded.width == expectedWidth, decoded.height == expectedHeight,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ExportError.verificationFailed }
        }
    }

    func validate(_ document: StudioDocument) throws {
        try document.validate()
        let pixels = document.width * document.height
        guard document.frames.count <= Self.maximumFrames, pixels <= Self.maximumFramePixels,
              pixels * document.frames.count <= Self.maximumTotalPixels else { throw ExportError.limitExceeded }
        let tools: Set<DrawingTool> = [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle, .text, .fill, .smudge, .blur, .sharpen, .dodge, .burn]
        let blends = Set(StudioLayerBlendMode.allCases.map(\.rawValue))
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
                guard tools.contains(element.tool), element.tool != .smudge || element.smudge != nil, element.tool != .blur || element.blur != nil, element.tool != .sharpen || element.sharpen != nil,
                      (element.tool != .dodge && element.tool != .burn) || element.dodgeBurn != nil else { throw ExportError.unsupportedContent }
                guard element.tool != .fill || element.fillMask != nil else { throw ExportError.unsupportedContent }
                guard validColor(element.color) else { throw ExportError.invalidColor }
                if element.tool == .text {
                    if let text = element.text { try text.validate(element: element) }
                    else { guard let text = element.fillColor, !text.isEmpty, text.utf8.count <= 4096 else { throw ExportError.unsupportedContent } }
                }
            }
        }
    }

    private func validateRaster(_ data: Data) throws -> Int {
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
        return width * height
    }

    enum ExportError: LocalizedError {
        case limitExceeded, unsafeDestination, renderFailed, encodeFailed, missingRaster, invalidRaster, unsupportedContent, invalidColor, alreadyExporting
        case invalidImageCredit, verificationFailed, invalidFilename, unsupportedOption
        case cleanupFailed(URL)
        var errorDescription: String? {
            switch self {
            case .verificationFailed: return "A written PNG did not decode back to the rendered size. No export was published."
            case .invalidFilename: return "The export filename must use ASCII letters, digits, '-' or '_' (at most 40 characters)."
            case .unsupportedOption: return "Separate-layer export needs the PNG sequence format and at least one visible layer. No export was published."
            case .limitExceeded: return "This PNG export exceeds the current safe frame, image or output size limit. Use a smaller project; no partial export was published."
            case .unsafeDestination: return "Choose an existing app-owned export directory without symbolic links."
            case .renderFailed: return "Studio could not render the requested image. No export was published."
            case .encodeFailed: return "The PNG file could not be written. No export was published."
            case .invalidImageCredit: return "An image attribution record is invalid. No export was published."
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

extension StudioDocument {
    /// Export copy with reference layers hidden (#200). Reference layers hold
    /// imported video frames for tracing and are never part of rendered output;
    /// the editable document is unchanged.
    var hidingReferenceLayers: StudioDocument {
        guard layers.contains(where: \.isReference) else { return self }
        var copy = self
        for index in copy.layers.indices where copy.layers[index].isReference { copy.layers[index].visible = false }
        return copy
    }
}

/// Export file naming shared by MP4, GIF, PNG and spritesheet outputs (#185).
/// The project name becomes an ASCII-only base every destination accepts; the
/// manifest keeps the project ID and revision, so the name is never identity.
enum StudioExportFilename {
    static let fallback = "animation"
    static let maximumLength = 40

    /// ASCII letters, digits, '-' and '_' are kept; every other run of
    /// characters (spaces, punctuation, emoji, accents) collapses to one '-'.
    /// Leading/trailing '-' are trimmed, the result is cut to 40 characters and
    /// an empty result falls back to "animation".
    static func base(for projectName: String?) -> String {
        guard let projectName else { return fallback }
        var result = "", separatorPending = false
        for scalar in projectName.unicodeScalars {
            if isAllowed(scalar.value) {
                if separatorPending && !result.isEmpty { result.append("-") }
                separatorPending = false
                result.unicodeScalars.append(scalar)
            } else {
                separatorPending = true
            }
            if result.count >= maximumLength { break }
        }
        if result.count > maximumLength { result = String(result.prefix(maximumLength)) }
        while result.hasSuffix("-") { result.removeLast() }
        while result.hasPrefix("-") { result.removeFirst() }
        return result.isEmpty ? fallback : result
    }

    static func isValid(_ base: String) -> Bool {
        !base.isEmpty && base.count <= maximumLength && !base.hasPrefix("-") && !base.hasSuffix("-")
            && base.unicodeScalars.allSatisfy { isAllowed($0.value) }
    }
    private static func isAllowed(_ value: UInt32) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) || value == 95 || value == 45
    }
}

/// Pre-export resource check (#202): free space on the destination volume must
/// cover twice the estimated output, and a device in the critical thermal
/// state refuses to start rendering. Estimates are documented heuristics, not
/// measurements; an unknown capacity never blocks an export.
enum StudioExportPreflight {
    enum Thermal: Equatable { case nominal, fair, serious, critical, unknown }
    static let requiredMultiple: Int64 = 2
    enum Failure: LocalizedError, Equatable {
        case thermalCritical
        case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
        var errorDescription: String? {
            switch self {
            case .thermalCritical:
                return "This device is too hot to render safely right now. Let it cool down, then export again. Nothing was exported."
            case .insufficientStorage(let required, let available):
                return "Not enough free space for this export: about \(Self.megabytes(required)) MB is needed (twice the estimated output) but \(Self.megabytes(available)) MB is available. Nothing was exported."
            }
        }
        private static func megabytes(_ bytes: Int64) -> Int64 { max(1, (bytes + 1_048_575) / 1_048_576) }
    }

    /// Pure decision used by the device check and by tests.
    static func decide(availableBytes: Int64?, estimatedOutputBytes: Int, thermal: Thermal) throws {
        guard thermal != .critical else { throw Failure.thermalCritical }
        guard let availableBytes else { return }
        let required = Int64(max(0, estimatedOutputBytes)) * requiredMultiple
        guard availableBytes >= required else {
            throw Failure.insufficientStorage(requiredBytes: required, availableBytes: max(0, availableBytes))
        }
    }

    /// Reads the destination volume's important-usage capacity and the process
    /// thermal state, then applies `decide`. Missing values are treated as unknown.
    static func check(estimatedOutputBytes: Int, destination: URL) throws {
        try decide(availableBytes: availableCapacity(destination), estimatedOutputBytes: estimatedOutputBytes, thermal: currentThermal())
    }

    static func availableCapacity(_ destination: URL) -> Int64? {
        #if canImport(Darwin)
        guard destination.isFileURL,
              let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
        #else
        return nil
        #endif
    }
    static func currentThermal() -> Thermal {
        #if canImport(Darwin)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    // Heuristics (documented in docs/STUDIO_EXPORT_PREFLIGHT.md):
    // PNG ≈ 1 byte per rendered pixel per frame; GIF ≈ 0.5 byte per pixel per
    // frame; MP4 ≈ configured video bit rate × duration, doubled when audio is
    // mixed (the video component and final file coexist) plus the float CAF
    // mix (8 bytes per 48 kHz frame) and the AAC track, plus 1 MiB overhead.
    static func estimatedPNGBytes(width: Int, height: Int, frames: Int) -> Int {
        max(1, width) * max(1, height) * max(1, frames) + 65_536
    }
    static func estimatedGIFBytes(width: Int, height: Int, frames: Int) -> Int {
        (max(1, width) * max(1, height) * max(1, frames)) / 2 + 65_536
    }
    static func estimatedMovieBytes(width: Int, height: Int, fps: Int, durationSeconds: Double, includesAudio: Bool) -> Int {
        let bitrate = min(12_000_000, max(2_000_000, max(1, width) * max(1, height) * max(1, fps) * 2))
        let duration = durationSeconds.isFinite ? max(0, durationSeconds) : 0
        let video = Int((Double(bitrate) / 8 * duration).rounded(.up))
        let audio = includesAudio ? Int((48_000 * 8 * duration).rounded(.up)) + Int((24_000.0 * duration).rounded(.up)) : 0
        return (includesAudio ? video * 2 : video) + audio + 1_048_576
    }
}

extension StudioExportService {
    /// Free-plan export mark: a small, semi-transparent "SDI" plate drawn at the
    /// bottom-right of one exported frame. It is drawn on a new bitmap copy, so
    /// the editable project, its originals and the source image never change.
    /// The output keeps the input's pixel size; margins keep it off the edge.
    nonisolated static func watermarked(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.renderFailed
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: full)
        // Small: about 4% of the shorter edge, never below 7 px or above 40 px.
        let shortEdge = CGFloat(min(width, height))
        let fontSize = max(7, min(40, shortEdge * 0.04))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SDI", attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let padding = fontSize * 0.35, margin = max(3, fontSize * 0.5)
        let plate = CGRect(x: CGFloat(width) - margin - textWidth - padding * 2, y: margin,
                           width: textWidth + padding * 2, height: ascent + descent + padding * 2)
        // A tiny canvas cannot hold the mark legibly; it is skipped there
        // rather than covering the artwork.
        guard plate.minX >= 0, plate.maxY <= CGFloat(height) else {
            guard let copy = context.makeImage() else { throw ExportError.renderFailed }
            return copy
        }
        context.saveGState()
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        context.addPath(CGPath(roundedRect: plate, cornerWidth: padding, cornerHeight: padding, transform: nil))
        context.fillPath()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: plate.minX + padding, y: plate.minY + padding + descent)
        CTLineDraw(line, context)
        context.restoreGState()
        guard let marked = context.makeImage() else { throw ExportError.renderFailed }
        return marked
    }
}

// MARK: - Official-channel mark (#241)

extension StudioExportService {
    /// The owner-approved watercolor mark from the app's asset catalogue. Throws
    /// `StudioChannelRendition.Failure.markUnavailable` when the asset is not
    /// installed; nothing is drawn in its place.
    static func installedChannelMark(named name: String = StudioChannelRendition.markAssetName) throws -> CGImage {
        guard StudioChannelRendition.markAssetNames.contains(name) else { throw StudioChannelRendition.Failure.markUnavailable }
        #if canImport(UIKit)
        guard let mark = UIImage(named: name)?.cgImage else { throw StudioChannelRendition.Failure.markUnavailable }
        #elseif canImport(AppKit)
        guard let mark = NSImage(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw StudioChannelRendition.Failure.markUnavailable
        }
        #else
        throw StudioChannelRendition.Failure.markUnavailable
        #endif
        try validateChannelMark(mark)
        return mark
    }

    /// A channel mark must be a readable image with real transparency, so it
    /// sits over the picture instead of covering a rectangle of it.
    nonisolated static func validateChannelMark(_ mark: CGImage) throws {
        guard mark.width > 0, mark.height > 0, mark.width <= 4096, mark.height <= 4096 else { throw StudioChannelRendition.Failure.markInvalid }
        switch mark.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: throw StudioChannelRendition.Failure.markNotTransparent
        default: break
        }
        let pixels = try rgba(mark, width: min(mark.width, 256), height: min(mark.height, 256))
        let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        guard StudioChannelRendition.hasTransparency(alpha: alpha) else { throw StudioChannelRendition.Failure.markNotTransparent }
    }

    /// Draws `image` scaled to `width` × `height` into premultiplied RGBA8 bytes.
    nonisolated private static func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ExportError.renderFailed }
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ExportError.renderFailed }
        return bytes
    }

    /// Composites the channel mark into a new copy of one rendered frame at the
    /// lower-right safe-area placement. The input frame, the editable project
    /// and personal exports are untouched. When the picture under the mark is
    /// too close in luminance, a soft translucent plate is drawn behind it.
    nonisolated static func channelMarked(_ image: CGImage, mark: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        let rect = try StudioChannelRendition.placement(outputWidth: width, outputHeight: height, markWidth: mark.width, markHeight: mark.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportError.renderFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics uses a bottom-left origin; the placement is top-left.
        let target = CGRect(x: rect.x, y: height - rect.maxY, width: rect.width, height: rect.height)
        guard let under = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { throw ExportError.renderFailed }
        let background = StudioChannelRendition.meanLuminance(rgba: try rgba(under, width: rect.width, height: rect.height), premultiplied: true) ?? 1
        guard let markLuminance = StudioChannelRendition.meanLuminance(rgba: try rgba(mark, width: rect.width, height: rect.height), premultiplied: true) else {
            throw StudioChannelRendition.Failure.markNotTransparent
        }
        context.saveGState()
        if StudioChannelRendition.needsBackingPlate(markLuminance: markLuminance, backgroundLuminance: background) {
            let inset = max(2, CGFloat(rect.height) * 0.12)
            let plate = target.insetBy(dx: -inset, dy: -inset)
            let tone: CGFloat = StudioChannelRendition.plateIsDark(markLuminance: markLuminance) ? 0 : 1
            context.setFillColor(CGColor(srgbRed: tone, green: tone, blue: tone, alpha: 0.45))
            context.addPath(CGPath(roundedRect: plate, cornerWidth: inset, cornerHeight: inset, transform: nil))
            context.fillPath()
        }
        context.interpolationQuality = .high
        context.draw(mark, in: target)
        context.restoreGState()
        guard let marked = context.makeImage(), marked.width == width, marked.height == height else { throw ExportError.renderFailed }
        return marked
    }
}
