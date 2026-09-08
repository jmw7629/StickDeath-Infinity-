import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Only the platform image container is adapted. The entire production exporter
// and StudioFrameRenderer compile unchanged; there is no test renderer/exporter.
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}

@main @MainActor struct StudioExportTests {
    static let fm = FileManager.default
    static let service = StudioExportService()

    static func document(colors: [String] = ["#FF0000", "#0000FF", "#00FF00"], width: Int = 64, height: Int = 32) throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "PNG fixture", width: width, height: height, fps: 24)
        doc.frames = colors.enumerated().map { index, color in
            AnimationFrame(id: "frame-\(index)", elements: [DrawnElement(id: "stroke-\(index)", tool: .brush,
                points: [StrokePoint(x: 0, y: CGFloat(height) / 2), StrokePoint(x: CGFloat(width), y: CGFloat(height) / 2)],
                color: color, width: 48, opacity: 1, layerID: doc.activeLayerID)])
        }
        doc.activeFrameID = doc.frames[0].id
        return doc
    }

    struct Raster {
        let width: Int; let height: Int; let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    }
    static func decode(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Output is not a decodable PNG") }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let valid = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try require(valid, "PNG pixel decode failed")
        return Raster(width: image.width, height: image.height, bytes: bytes)
    }
    static func pixel(_ actual: [UInt8], _ expected: [UInt8]) throws {
        try require(zip(actual, expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }, "RGBA \(actual), expected \(expected)")
    }
    static func png(color: CGColor) throws -> Data {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(destination), "Generated fixture could not encode")
        return data as Data
    }
    static func asymmetricPNG() throws -> Data {
        var bytes: [UInt8] = []
        for y in 0..<16 {
            for x in 0..<16 {
                bytes += y < 8 ? (x < 8 ? [255, 0, 0, 255] : [0, 0, 255, 255])
                    : (x < 8 ? [255, 255, 0, 255] : [0, 255, 0, 255])
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Asymmetric fixture could not encode")
        return data as Data
    }
    static func rejects(_ action: () async throws -> Void) async throws {
        do { try await action() } catch { return }
        throw Failure(message: "Expected export to fail")
    }
    static func parent(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-image-export-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0, failed = 0
        func test(_ name: String, _ operation: () async throws -> Void) async {
            do { try await operation(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("real PNG sequence dimensions frame order timing and immutable document") {
            let folder = try parent(root, "sequence"); var doc = try document()
            doc.gridEnabled = true; doc.onionEnabled = true; doc.revision = 7
            let original = doc; var progress: [Int] = []
            let output = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                progress: { done, total in if total == 3 { progress.append(done) } })
            try require(output.imageURLs.map(\.lastPathComponent) == ["frame_000000.png", "frame_000001.png", "frame_000002.png"], "Frame filenames not ordered")
            let expected: [[UInt8]] = [[255, 0, 0, 255], [0, 0, 255, 255], [0, 255, 0, 255]]
            for (index, url) in output.imageURLs.enumerated() {
                let raster = try decode(url)
                try require(raster.width == 64 && raster.height == 32, "Canvas was resized")
                try pixel(raster.pixel(32, 16), expected[index]); try pixel(raster.pixel(2, 2), expected[index])
            }
            let manifest = try JSONDecoder().decode(StudioExportService.Manifest.self, from: Data(contentsOf: output.manifestURL))
            try require(manifest.projectID == doc.id && manifest.documentRevision == 7 && manifest.fps == 24 && manifest.frames.map(\.id) == doc.frames.map(\.id), "Timing/identity/order metadata lost")
            try require(!manifest.audioIncluded && !manifest.editorGuidesIncluded && progress == [1, 2, 3] && doc == original, "Export changed document or claimed unsupported media")
        }
        await test("spritesheet real decoded row-major cells and manifest rectangles") {
            let folder = try parent(root, "sheet"); let doc = try document()
            let output = try await service.export(document: doc, format: .spritesheet, outputParent: folder)
            try require(output.imageURLs.count == 1, "Unexpected sheet count")
            let image = try decode(output.imageURLs[0])
            try require(image.width == 128 && image.height == 64, "Sheet layout has wrong dimensions")
            try pixel(image.pixel(32, 16), [255, 0, 0, 255]); try pixel(image.pixel(96, 16), [0, 0, 255, 255])
            try pixel(image.pixel(32, 48), [0, 255, 0, 255]); try pixel(image.pixel(96, 48), [255, 255, 255, 255])
            try require(output.manifest.frames.map(\.x) == [0, 64, 0] && output.manifest.frames.map(\.y) == [0, 0, 32], "Sheet rect metadata does not match row-major order")
        }
        await test("transparent alpha and white background produce different actual PNG pixels") {
            let folder = try parent(root, "background"); var doc = try document(colors: ["#FF0000"])
            doc.frames[0].elements.removeAll()
            let clear = try await service.export(document: doc, format: .pngSequence, outputParent: folder, background: .transparent)
            let white = try await service.export(document: doc, format: .pngSequence, outputParent: folder)
            try pixel(decode(clear.imageURLs[0]).pixel(10, 10), [0, 0, 0, 0])
            try pixel(decode(white.imageURLs[0]).pixel(10, 10), [255, 255, 255, 255])
            try require(clear.directory != white.directory, "A previous export was overwritten")
        }
        await test("canonical layers visibility opacity order and layer-local eraser reach exported pixels") {
            let folder = try parent(root, "layers"); var doc = try document(colors: ["#FF0000"], height: 64)
            let red = doc.activeLayerID; var blue = CanvasLayer(id: "blue", name: "Blue")
            doc.layers.insert(blue, at: 0)
            let overlay = DrawnElement(id: "blue-stroke", tool: .brush, points: [StrokePoint(x: 0, y: 32), StrokePoint(x: 64, y: 32)], color: "#0000FF", width: 20, opacity: 1, layerID: blue.id)
            doc.frames[0].elements.append(overlay)
            var output = try await service.export(document: doc, format: .pngSequence, outputParent: folder)
            try pixel(decode(output.imageURLs[0]).pixel(32, 32), [0, 0, 255, 255])
            blue.opacity = 0.5; doc.layers[0] = blue
            output = try await service.export(document: doc, format: .pngSequence, outputParent: folder)
            try pixel(decode(output.imageURLs[0]).pixel(32, 32), [128, 0, 128, 255])
            doc.layers[0].visible = false
            output = try await service.export(document: doc, format: .pngSequence, outputParent: folder)
            try pixel(decode(output.imageURLs[0]).pixel(32, 32), [255, 0, 0, 255])
            doc.layers[0].visible = true; doc.layers[0].opacity = 1
            doc.frames[0].elements.append(DrawnElement(id: "erase", tool: .eraser, points: [StrokePoint(x: 0, y: 32), StrokePoint(x: 64, y: 32)], color: "#FFFFFF", width: 4, opacity: 1, layerID: blue.id))
            output = try await service.export(document: doc, format: .pngSequence, outputParent: folder)
            try pixel(decode(output.imageURLs[0]).pixel(32, 32), [255, 0, 0, 255])
            try require(doc.layers[1].id == red, "Layer identity changed")
        }
        await test("project-managed raster bytes are decoded and composed without changing original") {
            let folder = try parent(root, "raster"); var doc = try document(colors: ["#FF0000"])
            let original = try png(color: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 1, 0, 1])!)
            doc.frames[0].elements.removeAll(); doc.frames[0].rasterAssetID = "original"; doc.frames[0].rasterLayerID = doc.activeLayerID
            let output = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                rasterData: { id in try require(id == "original", "Wrong asset lookup"); return original })
            try pixel(decode(output.imageURLs[0]).pixel(32, 16), [0, 255, 0, 255])
            try require(original == png(color: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 1, 0, 1])!), "Original raster bytes changed")
        }
        await test("asymmetric raster orientation is preserved within sequence and spritesheet cells") {
            let folder = try parent(root, "orientation"); var doc = try document()
            let original = try asymmetricPNG()
            try original.write(to: folder.appendingPathComponent("original.png"))
            doc.frames[0].elements.removeAll(); doc.frames[0].rasterAssetID = "corners"; doc.frames[0].rasterLayerID = doc.activeLayerID
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let output = try await service.export(document: doc, format: format, outputParent: folder, rasterData: { _ in original })
                let image = try decode(output.imageURLs[0])
                try pixel(image.pixel(16, 8), [255, 0, 0, 255]); try pixel(image.pixel(48, 8), [0, 0, 255, 255])
                try pixel(image.pixel(16, 24), [255, 255, 0, 255]); try pixel(image.pixel(48, 24), [0, 255, 0, 255])
                if format == .spritesheet {
                    try pixel(image.pixel(96, 16), [0, 0, 255, 255]); try pixel(image.pixel(32, 48), [0, 255, 0, 255])
                }
            }
            try require(try Data(contentsOf: folder.appendingPathComponent("original.png")) == original, "Original asymmetric asset changed")
        }
        await test("hidden and zero-opacity layers omit unavailable raster and unsupported operations") {
            let folder = try parent(root, "hidden-content"); var doc = try document(colors: ["#FF0000"])
            var hidden = CanvasLayer(id: "hidden", name: "Hidden original", visible: false)
            hidden.blendMode = "unsupported"
            doc.layers.append(hidden); doc.frames[0].rasterAssetID = "missing"; doc.frames[0].rasterLayerID = hidden.id
            doc.frames[0].elements.append(DrawnElement(id: "hidden-fill", tool: .fill, points: [], color: "unavailable", width: 1, opacity: 1, layerID: hidden.id))
            for opacity in [1.0, 0.0] {
                doc.layers[1].visible = opacity == 0; doc.layers[1].opacity = opacity
                let output = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                    rasterData: { _ in throw Failure(message: "Invisible raster was requested") })
                try pixel(decode(output.imageURLs[0]).pixel(32, 16), [255, 0, 0, 255])
            }
            doc.layers[1].visible = true; doc.layers[1].opacity = 1; doc.layers[1].blendMode = "normal"
            doc.frames[0].elements.removeLast()
            try await rejects { _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder) }
            try require(try fm.contentsOfDirectory(atPath: folder.path).count == 2, "Visible missing raster published or left partial output")
        }
        await test("missing or corrupt raster removes all partial files and preserves prior exports") {
            let folder = try parent(root, "failed-asset"); var doc = try document(colors: ["#FF0000", "#0000FF"])
            doc.frames[1].rasterAssetID = "missing"; doc.frames[1].rasterLayerID = doc.activeLayerID
            let sentinel = folder.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
            var sawPartialFrame = false
            try await rejects {
                _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder, progress: { done, _ in
                    if done == 1 {
                        sawPartialFrame = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).contains { fm.fileExists(atPath: $0.appendingPathComponent("frame_000000.png").path) }) == true
                    }
                })
            }
            try require(sawPartialFrame && fm.contentsOfDirectory(atPath: folder.path) == ["keep.txt"], "Partial output remained or earlier file was removed")
            try await rejects { _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder, rasterData: { _ in Data("corrupt".utf8) }) }
            try require(try Data(contentsOf: sentinel) == Data("keep".utf8), "Earlier file changed")
        }
        await test("Task cancellation after a real written frame removes owned partial output") {
            let folder = try parent(root, "cancel"); let doc = try document(); var progress: [Int] = []
            let task = Task { @MainActor in
                try await service.export(document: doc, format: .pngSequence, outputParent: folder, progress: { done, _ in
                    progress.append(done)
                    if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            }
            do { _ = try await task.value; throw Failure(message: "Cancelled task returned success") }
            catch is CancellationError { }
            try require(progress == [1] && fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Cancelled export left partial output or kept rendering")
        }
        await test("already cancelled export produces no files") {
            let folder = try parent(root, "pre-cancel"); let doc = try document()
            let task = Task { @MainActor in try await service.export(document: doc, format: .spritesheet, outputParent: folder) }
            task.cancel()
            do { _ = try await task.value; throw Failure(message: "Cancelled task returned success") }
            catch is CancellationError { }
            try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Pre-cancelled task created files")
        }
        await test("unsupported tools and blend modes fail instead of silently dropping effects") {
            let folder = try parent(root, "unsupported"); var doc = try document(colors: ["#FF0000"])
            doc.frames[0].elements[0].tool = .fill
            try await rejects { _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder) }
            doc.frames[0].elements[0].tool = .brush; doc.layers[0].blendMode = "unsupported"
            try await rejects { _ = try await service.export(document: doc, format: .spritesheet, outputParent: folder) }
            doc.layers[0].blendMode = "normal"; doc.frames[0].elements[0].color = "not-hex"
            try await rejects { _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder) }
            try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Rejected content created output")
        }
        await test("frame pixel sheet and count limits fail without silent resizing") {
            let folder = try parent(root, "bounds")
            let large = try document(colors: ["#FF0000"], width: 4096, height: 4096)
            try await rejects { _ = try await service.export(document: large, format: .pngSequence, outputParent: folder) }
            let sheet = try document(colors: Array(repeating: "#FF0000", count: 5), width: 2048, height: 2048)
            try await rejects { _ = try await service.export(document: sheet, format: .spritesheet, outputParent: folder) }
            let many = try document(colors: Array(repeating: "#FF0000", count: 241), width: 16, height: 16)
            try await rejects { _ = try await service.export(document: many, format: .pngSequence, outputParent: folder) }
            try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Oversized request created output")
        }
        await test("destination symlink rejected and project title never becomes a path") {
            let folder = try parent(root, "safe-path"); let link = root.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: folder)
            var doc = try document(colors: ["#FF0000"]); doc.name = "../../untrusted title"
            try await rejects { _ = try await service.export(document: doc, format: .pngSequence, outputParent: link) }
            try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Followed output directory symlink")
            let output = try await service.export(document: doc, format: .pngSequence, outputParent: folder)
            try require(output.directory.deletingLastPathComponent() == folder && output.directory.lastPathComponent.hasPrefix("SDI-"), "Title escaped output directory")
        }
        print("STUDIO_EXPORT_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        print("GENERATED_EXPORT_FIXTURES=\(root.path)")
        if failed > 0 { exit(1) }
    }
}
