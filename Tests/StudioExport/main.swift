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
        await test("held cels retain timing in PNG sequence and spritesheet manifests") {
            var doc = try document(); doc.schemaVersion = 21
            doc.frames[0].holdTicks = 3; doc.frames[1].holdTicks = 6
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let output = try await service.export(document: doc, format: format, outputParent: parent(root, "holds-" + format.rawValue))
                let manifest = try JSONDecoder().decode(StudioExportService.Manifest.self, from: Data(contentsOf: output.manifestURL))
                try require(manifest.version == 2 && manifest.frames.map(\.startTick) == [0, 3, 9]
                    && manifest.frames.map(\.durationTicks) == [3, 6, 1], "Image export lost canonical exposures")
                _ = try decode(output.imageURLs[0])
            }
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
        await test("normalized crop exports only the chosen source quadrant before rotation and flips") {
            let folder = try parent(root, "crop-quadrants"), original = try asymmetricPNG()
            var doc = try document(colors: ["#FF0000"], width: 64, height: 64)
            doc.schemaVersion = 22; doc.frames[0].elements = []
            doc.frames[0].rasterAssetID = "crop"; doc.frames[0].rasterLayerID = doc.activeLayerID
            doc.frames[0].rasterPlacement = .init(x: 16, y: 16, width: 32, height: 32)
            do {
                _ = try StudioFrameRenderer.prepareRaster(frame: doc.frames[0], layers: doc.layers, data: original, maximumDimension: Int.max)
                throw Failure(message: "Unbounded crop resolution accepted")
            } catch StudioRasterImage.Failure.limit { }
            for (x,y,expected) in [(0.0,0.0,[255,0,0,255]), (0.5,0.0,[0,0,255,255]),
                                   (0.0,0.5,[255,255,0,255]), (0.5,0.5,[0,255,0,255])] as [(Double,Double,[UInt8])] {
                doc.frames[0].rasterCrop = .init(x: x, y: y, width: 0.5, height: 0.5)
                for turns in [nil,1,2,3] as [Int?] {
                    doc.frames[0].rasterQuarterTurns = turns
                    doc.frames[0].rasterReflection = .init(horizontal: true, vertical: false)
                    let output = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                        background: .transparent, rasterData: { _ in original })
                    let image = try decode(output.imageURLs[0])
                    try pixel(image.pixel(32,32),expected); try pixel(image.pixel(20,20),expected)
                    try pixel(image.pixel(8,8),[0,0,0,0])
                }
            }
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
        await test("missing or corrupt raster fails preflight without output and preserves prior exports") {
            let folder = try parent(root, "failed-asset"); var doc = try document(colors: ["#FF0000", "#0000FF"])
            doc.frames[1].rasterAssetID = "missing"; doc.frames[1].rasterLayerID = doc.activeLayerID
            let sentinel = folder.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
            var progress: [Int] = []
            do {
                _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                    progress: { done, _ in progress.append(done) })
                throw Failure(message: "Missing raster returned an export")
            } catch StudioExportService.ExportError.missingRaster { }
            try require(progress.isEmpty && fm.contentsOfDirectory(atPath: folder.path) == ["keep.txt"] &&
                        Data(contentsOf: sentinel) == Data("keep".utf8),
                        "Missing-source preflight rendered output or changed a prior export")
            do {
                _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                    rasterData: { _ in Data("corrupt".utf8) }, progress: { done, _ in progress.append(done) })
                throw Failure(message: "Corrupt raster returned an export")
            } catch StudioExportService.ExportError.invalidRaster { }
            try require(progress.isEmpty && fm.contentsOfDirectory(atPath: folder.path) == ["keep.txt"] &&
                        Data(contentsOf: sentinel) == Data("keep".utf8),
                        "Corrupt-source preflight rendered output or changed a prior export")
        }
        await test("real PNG write failure after one written frame removes only owned partial output") {
            let folder = try parent(root, "failed-write"), doc = try document(colors: ["#FF0000", "#0000FF"])
            let sentinel = folder.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
            var progress: [Int] = [], injected = false, firstFrame: URL?, setupError: String?
            do {
                _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                    progress: { done, _ in
                        progress.append(done)
                        guard done == 1 else { return }
                        do {
                            let staging = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                                .filter { $0.lastPathComponent.hasPrefix(".sdi-export-") && $0.pathExtension == "partial" }
                            guard staging.count == 1 else { throw Failure(message: "Expected one owned staging directory") }
                            let written = staging[0].appendingPathComponent("frame_000000.png")
                            try pixel(decode(written).pixel(32, 16), [255, 0, 0, 255])
                            firstFrame = written
                            // Obstruct only this test export's next output path.
                            // The nonempty directory cannot be replaced by a PNG file.
                            let blocker = staging[0].appendingPathComponent("frame_000001.png", isDirectory: true)
                            try fm.createDirectory(at: blocker, withIntermediateDirectories: false)
                            try Data("owned fixture".utf8).write(to: blocker.appendingPathComponent("blocker.txt"))
                            injected = true
                        } catch { setupError = String(describing: error) }
                    })
                throw Failure(message: "Obstructed PNG write returned success")
            } catch StudioExportService.ExportError.encodeFailed { }
            try require(setupError == nil && injected && firstFrame != nil && progress == [1],
                        "Write-failure fixture did not observe one real PNG: \(setupError ?? "none")")
            try require(fm.contentsOfDirectory(atPath: folder.path) == ["keep.txt"] &&
                        !fm.fileExists(atPath: firstFrame!.path) && Data(contentsOf: sentinel) == Data("keep".utf8),
                        "Write failure left owned partial files or damaged an earlier export")
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
        // Read actual licensed production artwork, verify catalogue hashes and
        // rights, then use the real decoder, VM attachment and snapshot store.
        let imageCatalogueURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("StickDeathInfinity/Resources/StudioImages")
        let imageCatalogue = try StudioImageCatalogue(directory: imageCatalogueURL)
        guard let creditedItem = imageCatalogue.images.first(where: { $0.id == "kenney.scribble-platformer.item_pencil" }) else {
            throw Failure(message: "Actual bundled licensed Pencil image missing")
        }
        let licensedOriginal = try imageCatalogue.checkedPNG(creditedItem)
        let licensedRights = try imageCatalogue.attribution(for: creditedItem)
        let licensedCredit = try StudioExportService.ImageCredit(attribution: licensedRights)
        func creditedProject(_ name: String, includeRights: Bool = true) async throws -> (StudioViewModel, String, URL) {
            let folder = try parent(root, name)
            let file = folder.appendingPathComponent("verified-original.png")
            try licensedOriginal.write(to: file, options: .withoutOverwriting)
            var imported = try await StudioImageImportService().importImage(from: file, name: creditedItem.title, scratchParent: folder)
            if includeRights { imported.catalogueAttribution = licensedRights }
            let documents = folder.appendingPathComponent("Documents")
            let store = DeviceStorageManager(documentsDirectory: documents)
            let editor = StudioViewModel(storage: store)
            let created = await editor.createProject(name: name, width: 160, height: 160, fps: 12)
            try require(created, "Real credited project creation failed")
            let asset = try editor.attachImportedImage(imported, expectedProjectID: editor.document.id,
                expectedRevision: editor.document.revision, frameID: editor.document.activeFrameID, layerID: editor.document.activeLayerID)
            editor.duplicateFrame()
            try require(editor.document.frames.count == 2 && editor.document.frames.allSatisfy { $0.rasterAssetID == asset },
                "Real duplicate did not preserve shared managed asset")
            let saved = await editor.save()
            try require(saved, "Actual credited project save failed")
            let coldStore = DeviceStorageManager(documentsDirectory: documents)
            guard let snapshot = try coldStore.loadAnimation(id: editor.document.id) else { throw Failure(message: "Saved credited project missing") }
            let reopened = StudioViewModel(storage: coldStore)
            let opened = await reopened.openProject(snapshot.metadata)
            try require(opened, "Actual cold reopen failed")
            let source = reopened.originalImageSource(asset)
            try require(source?.originalData == licensedOriginal && source?.catalogueAttribution == (includeRights ? licensedRights : nil),
                "Real persistence lost original image bytes or rights")
            try source?.validate()
            return (reopened, asset, folder)
        }
        func sourceCredits(_ editor: StudioViewModel, asset: String) throws -> [String: StudioExportService.ImageCredit] {
            guard let source = editor.originalImageSource(asset), let attribution = source.catalogueAttribution else { return [:] }
            try source.validate()
            return [asset: try StudioExportService.ImageCredit(attribution: attribution)]
        }
        await test("real licensed import save cold reopen exports exact deduplicated credits in both image formats") {
            let (editor, asset, folder) = try await creditedProject("licensed-credit-roundtrip")
            let originalLayer = editor.currentFrame.rasterLayerID!
            editor.duplicateLayer(originalLayer); editor.toggleLayerVisibility(originalLayer)
            try require(editor.frames.allSatisfy { $0.rasterLayerInstances.count == 2 }, "Actual linked copies missing")
            let credits = try sourceCredits(editor, asset: asset)
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let output = try await service.export(document: editor.document, format: format, outputParent: folder,
                    background: .transparent, imageCredits: credits, rasterData: { editor.rasterData($0) })
                let manifestBytes = try Data(contentsOf: output.manifestURL)
                let decoded = try JSONDecoder().decode(StudioExportService.Manifest.self, from: manifestBytes)
                try require(decoded.version == 3 && decoded.imageCredits == [licensedCredit],
                    "Manifest must preserve all eight actual rights fields once despite duplicate frames")
                try require(decoded.frames.count == 2 && decoded.frames.map(\.id) == editor.document.frames.map(\.id),
                    "Credits changed real frame identities")
                let object = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
                let serializedCredits = object["imageCredits"] as? [[String: String]]
                try require(serializedCredits == [licensedRights], "Serialized sidecar rights differ from verified source metadata")
                let raster = try decode(output.imageURLs[0])
                let alpha = stride(from: 3, to: raster.bytes.count, by: 4).map { raster.bytes[$0] }
                try require(alpha.contains(0) && alpha.contains(where: { $0 > 0 }), "Actual licensed image pixels missing")
                try require(!String(decoding: manifestBytes, as: UTF8.self).contains("originalData"), "Manifest exposed embedded original bytes")
            }
        }
        await test("hidden and zero-opacity licensed images neither render nor appear in exported credits") {
            let (editor, asset, folder) = try await creditedProject("licensed-credit-visibility")
            guard let layer = editor.document.frames[0].rasterLayerID else { throw Failure(message: "Imported image layer missing") }
            let credits = try sourceCredits(editor, asset: asset)
            for mode in ["hidden", "transparent"] {
                if mode == "hidden" { editor.toggleLayerVisibility(layer) }
                else { editor.toggleLayerVisibility(layer); editor.setLayerOpacity(layer, opacity: 0) }
                for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                    let output = try await service.export(document: editor.document, format: format, outputParent: folder,
                        background: .transparent, imageCredits: credits,
                        rasterData: { _ in throw Failure(message: "Invisible licensed raster was requested") })
                    let manifest = try JSONDecoder().decode(StudioExportService.Manifest.self, from: Data(contentsOf: output.manifestURL))
                    try require(manifest.imageCredits == nil && manifest.version != 3, "Invisible asset received a rendered credit")
                    let raster = try decode(output.imageURLs[0])
                    try require(stride(from: 3, to: raster.bytes.count, by: 4).allSatisfy { raster.bytes[$0] == 0 },
                        "Invisible licensed image still rendered")
                }
            }
        }
        await test("personal Files import does not invent catalogue rights or claim manifest v3") {
            let (editor, asset, folder) = try await creditedProject("personal-no-credit", includeRights: false)
            try require(try sourceCredits(editor, asset: asset).isEmpty, "Personal source acquired invented rights")
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let output = try await service.export(document: editor.document, format: format, outputParent: folder,
                    imageCredits: try sourceCredits(editor, asset: asset), rasterData: { editor.rasterData($0) })
                let decoded = try JSONDecoder().decode(StudioExportService.Manifest.self, from: Data(contentsOf: output.manifestURL))
                try require(decoded.imageCredits == nil && decoded.version != 3, "Personal import assigned fabricated catalogue credits")
                _ = try decode(output.imageURLs[0])
            }
        }
        await test("invalid and oversized image credit metadata fail without published or partial exports") {
            let folder = try parent(root, "bad-image-credits")
            var doc = try document(colors: ["#FF0000"])
            doc.frames[0].elements.removeAll(); doc.frames[0].rasterAssetID = "licensed"; doc.frames[0].rasterLayerID = doc.activeLayerID
            for (key, invalid) in [("author", String(repeating: "a", count: 601)), ("license", "unverified"),
                                   ("sourceURL", "http://kenney.nl/assets/example"), ("originalSHA256", "wrong"),
                                   ("attribution", "hidden\ncontrol"), ("author", "a" + String(repeating: "\u{0301}", count: 1200))] {
                var bad = licensedRights; bad[key] = invalid
                try await rejects { _ = try StudioExportService.ImageCredit(attribution: bad) }
                // Decodable must not bypass export-time validation of an actual
                // rendered credit, even when init(attribution:) was not called.
                let forged = try JSONDecoder().decode(StudioExportService.ImageCredit.self, from: JSONSerialization.data(withJSONObject: bad))
                try await rejects {
                    _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                        imageCredits: ["licensed": forged], rasterData: { _ in licensedOriginal })
                }
                try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Invalid credit left partial/published output")
            }
            var extra = licensedRights; extra["privateUserEmail"] = "private@example.invalid"
            try await rejects { _ = try StudioExportService.ImageCredit(attribution: extra) }
            var missing = licensedRights; missing.removeValue(forKey: "author")
            try await rejects { _ = try StudioExportService.ImageCredit(attribution: missing) }
            var conflicting = licensedRights; conflicting["author"] = "Different claimed author"
            let conflictingCredit = try StudioExportService.ImageCredit(attribution: conflicting)
            let duplicate = AnimationFrame(id: "other-credit-frame", elements: [], rasterAssetID: "other-licensed", rasterLayerID: doc.activeLayerID)
            doc.frames.append(duplicate)
            try await rejects {
                _ = try await service.export(document: doc, format: .pngSequence, outputParent: folder,
                    imageCredits: ["licensed": licensedCredit, "other-licensed": conflictingCredit], rasterData: { _ in licensedOriginal })
            }
            try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Conflicting rights published or left partial output")
            let oversized = Dictionary(uniqueKeysWithValues: (0...StudioExportService.maximumFrames).map { ("asset-\($0)", licensedCredit) })
            try await rejects {
                _ = try await service.export(document: doc, format: .spritesheet, outputParent: folder,
                    imageCredits: oversized, rasterData: { _ in licensedOriginal })
            }
            try require(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "Oversized credits created output")
        }
        await test("legacy manifest versions decode with absent image credits") {
            let folder = try parent(root, "legacy-credit-decoding")
            let output = try await service.export(document: document(), format: .pngSequence, outputParent: folder)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: output.manifestURL)) as! [String: Any]
            object.removeValue(forKey: "imageCredits")
            for version in [1, 2] {
                object["version"] = version
                if version == 1 {
                    object["frames"] = (object["frames"] as! [[String: Any]]).map { frame in
                        var older = frame; older.removeValue(forKey: "startTick"); older.removeValue(forKey: "durationTicks"); return older
                    }
                }
                let decoded = try JSONDecoder().decode(StudioExportService.Manifest.self, from: JSONSerialization.data(withJSONObject: object))
                try require(decoded.version == version && decoded.imageCredits == nil && decoded.frames.count == 3,
                    "Optional credits broke historical manifest decoding")
            }
        }
        print("STUDIO_EXPORT_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        print("GENERATED_EXPORT_FIXTURES=\(root.path)")
        if failed > 0 { exit(1) }
    }
}
