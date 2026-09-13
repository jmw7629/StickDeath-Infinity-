import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main @MainActor struct GIFTests {
    typealias Encoder = StudioGIFEncoder
    static func document(_ colors: [String] = ["#FF0000", "#0000FF", "#00FF00"], fps: Int = 24,
                         width: Int = 64, height: Int = 32) throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "Actual GIF", width: width, height: height, fps: fps)
        doc.frames = colors.enumerated().map { i, color in
            AnimationFrame(id: "frame-\(i)", elements: [DrawnElement(id: "stroke-\(i)", tool: .brush,
                points: [.init(x: 0, y: CGFloat(height) / 2), .init(x: CGFloat(width), y: CGFloat(height) / 2)],
                color: color, width: CGFloat(height) * 2, opacity: 1, layerID: doc.activeLayerID)])
        }
        doc.activeFrameID = doc.frames[0].id
        return doc
    }
    static func decode(_ data: Data, index: Int) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw Failure(message: "GIF frame cannot reopen") }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure(message: "GIF pixel decode failed") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, bytes)
    }
    static func pixel(_ data: Data, index: Int, x: Int = 32, y: Int = 16) throws -> [UInt8] {
        let image = try decode(data, index: index), offset = (y * image.width + x) * 4
        return Array(image.bytes[offset..<offset + 4])
    }
    static func same(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 3) throws {
        try require(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }, "Actual GIF RGBA \(actual), expected \(expected)")
    }
    static func rejects(_ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw Failure(message: "Invalid GIF request was accepted")
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-gif-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("actual GIF reopens from disk with ordered RGB frames and exact receipt") {
            var doc = try document(); doc.gridEnabled = true; doc.onionEnabled = true; doc.revision = 9
            let original = doc
            let result = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            let url = folder.appendingPathComponent("actual-animation.gif")
            try result.data.write(to: url, options: .withoutOverwriting)
            let bytes = try Data(contentsOf: url)
            let colors: [[UInt8]] = [[255,0,0,255], [0,0,255,255], [0,255,0,255]]
            for i in 0..<3 {
                let image = try decode(bytes, index: i)
                try require(image.width == 64 && image.height == 32, "GIF changed canvas size")
                try same(pixel(bytes, index: i), colors[i])
            }
            try require(doc == original && result.receipt.revision == 9 && result.receipt.frameIDs == doc.frames.map(\.id), "GIF mutated source or invented provenance")
            try require(result.receipt.encodedBytes == bytes.count && result.receipt.delaysCentiseconds == [4,4,5]
                && !result.receipt.audioIncluded && !result.receipt.editorGuidesIncluded && result.receipt.background == "white", "GIF receipt is not factual")
        }
        await test("all supported rates retain cumulative timing within half a centisecond") {
            for fps in 1...50 {
                let delays = try Encoder.timing(frameCount: 240, fps: fps)
                var total = 0
                for (i, delay) in delays.enumerated() {
                    total += delay
                    try require(delay >= 2 && abs(Double(total) / 100 - Double(i + 1) / Double(fps)) <= 0.005001, "GIF timing drifts at \(fps) FPS")
                }
            }
            let doc = try document(Array(repeating: "#FF0000", count: 12), fps: 12)
            let result = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try require(result.receipt.delaysCentiseconds.reduce(0, +) == 100, "Twelve source frames no longer last one second")
        }
        await test("later blank frame clears prior ink instead of retaining a ghost") {
            var doc = try document(["#FF0000", "#0000FF"]); doc.frames[1].elements = []
            let result = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try same(pixel(result.data, index: 0), [255,0,0,255])
            try same(pixel(result.data, index: 1), [255,255,255,255])
        }
        await test("actual layer visibility opacity blend and lock affect canonical GIF pixels") {
            var doc = try document(["#FF0000"])
            doc.layers[0].opacity = 0.5; doc.layers[0].lockMode = "full"
            let faded = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try same(pixel(faded.data, index: 0), [255,128,128,255], tolerance: 4)
            doc.layers[0].visible = false
            let hidden = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try same(pixel(hidden.data, index: 0), [255,255,255,255])
            doc.layers[0].visible = true; doc.layers[0].opacity = 1
            var blue = CanvasLayer(id: "blue", name: "Blue"); blue.blendMode = "multiply"
            doc.layers.insert(blue, at: 0)
            doc.frames[0].elements.append(DrawnElement(id: "blue-stroke", tool: .brush,
                points: [.init(x: 0, y: 16), .init(x: 64, y: 16)], color: "#0000FF", width: 64,
                opacity: 1, layerID: blue.id))
            let multiplied = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try same(pixel(multiplied.data, index: 0), [0,0,0,255])
            doc.layers[0].blendMode = "normal"
            let normal = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try same(pixel(normal.data, index: 0), [0,0,255,255])
        }
        await test("visible missing or corrupt original raster fails while hidden missing image is ignored") {
            var doc = try document(["#FF0000"])
            doc.frames[0].rasterAssetID = "original"; doc.frames[0].rasterLayerID = doc.activeLayerID
            try await rejects { _ = try await Encoder().encode(.init(document: doc, rasterDataByID: [:])) }
            try await rejects { _ = try await Encoder().encode(.init(document: doc, rasterDataByID: ["original": Data("invalid".utf8)])) }
            doc.layers[0].visible = false
            let result = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try same(pixel(result.data, index: 0), [255,255,255,255])
        }
        await test("invalid rate count and total frame pixel limits fail before rendering") {
            for doc in [try document(["#FF0000"], fps: 60),
                        try document(Array(repeating: "#FF0000", count: 241)),
                        try document(Array(repeating: "#FF0000", count: 17), width: 1080, height: 1920)] {
                var called = false
                try await rejects { _ = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]), progress: { _ in called = true }) }
                try require(!called, "Oversized GIF began rendering")
            }
        }
        await test("unsupported exposed tool fails without dropping its content") {
            var doc = try document(["#FF0000"]); doc.frames[0].elements[0].tool = .blur
            try await rejects { _ = try await Encoder().encode(.init(document: doc, rasterDataByID: [:])) }
        }
        await test("cancellation at render finalize and verification returns no successful bytes") {
            let doc = try document()
            for phase in ["rendering", "finalizing", "verifying"] {
                var reached = false
                let task = Task { @MainActor in
                    try await Encoder().encode(.init(document: doc, rasterDataByID: [:]), progress: { progress in
                        if String(describing: progress.phase) == phase { reached = true; withUnsafeCurrentTask { $0?.cancel() } }
                    })
                }
                do { _ = try await task.value; throw Failure(message: "Cancelled GIF returned successful bytes") }
                catch is CancellationError {}
                try require(reached, "Cancellation stage never ran")
            }
        }
        await test("already cancelled request does not invoke renderer") {
            let doc = try document(); var progress = false
            let task = Task { @MainActor in try await Encoder().encode(.init(document: doc, rasterDataByID: [:]), progress: { _ in progress = true }) }
            task.cancel()
            do { _ = try await task.value; throw Failure(message: "Precancelled request returned GIF") }
            catch is CancellationError {}
            try require(!progress, "Precancelled request began rendering")
        }
        await test("callback rejection releases global encoder for the next real request") {
            let doc = try document()
            try await rejects { _ = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]), progress: { _ in throw Failure(message: "Caller cancelled context") }) }
            let next = try await Encoder().encode(.init(document: doc, rasterDataByID: [:]))
            try require(!next.data.isEmpty, "Rejected request kept global encoding ownership")
        }
        func actualOutput(_ name: String) async throws -> StudioGIFExportService.Output {
            let parent = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            return try await StudioGIFExportService().export(.init(document: document(), rasterDataByID: [:]), outputParent: parent)
        }
        await test("actual GIF and manifest publish atomically and clean idempotently") {
            let output = try await actualOutput("files")
            let urls = try output.checkedURLs()
            try require(urls.map(\.lastPathComponent) == ["animation.gif", "manifest.json"], "Wrong exported file set")
            let receipt = try JSONDecoder().decode(Encoder.Receipt.self, from: Data(contentsOf: urls[1]))
            try require(receipt.encodedBytes == Data(contentsOf: urls[0]).count && receipt.frameIDs.count == 3, "Saved manifest disagrees with encoded file")
            try same(pixel(Data(contentsOf: urls[0]), index: 1), [0,0,255,255])
            try require(!output.directory.lastPathComponent.hasSuffix(".partial"), "Partial directory escaped as completed")
            try output.cleanup(); try output.cleanup()
            try require(output.isCleaned && !FileManager.default.fileExists(atPath: output.directory.path), "Owned file cleanup did not finish")
        }
        await test("unknown nested file blocks cleanup without deleting either known export") {
            let output = try await actualOutput("unknown")
            let extra = output.directory.appendingPathComponent("foreign.txt")
            try Data("preserve".utf8).write(to: extra)
            try await rejects { _ = try output.checkedURLs() }
            try await rejects { try output.cleanup() }
            try require(FileManager.default.fileExists(atPath: output.gifURL.path) && FileManager.default.fileExists(atPath: output.manifestURL.path)
                && Data(contentsOf: extra) == Data("preserve".utf8), "Unknown file or existing export was removed")
            try FileManager.default.removeItem(at: extra); try output.cleanup()
        }
        await test("same bytes on a replacement inode cannot inherit cleanup ownership") {
            let output = try await actualOutput("replacement"), url = output.gifURL
            let saved = output.parent.appendingPathComponent("owned-original.gif"), bytes = try Data(contentsOf: url)
            try FileManager.default.moveItem(at: url, to: saved); try bytes.write(to: url, options: .withoutOverwriting)
            try await rejects { _ = try output.checkedURLs() }; try await rejects { try output.cleanup() }
            try require(Data(contentsOf: url) == bytes && FileManager.default.fileExists(atPath: output.manifestURL.path), "Replacement was adopted or another file deleted")
            try FileManager.default.removeItem(at: url); try FileManager.default.moveItem(at: saved, to: url); try output.cleanup()
        }
        await test("same-inode content changes and hard links block use and cleanup") {
            let output = try await actualOutput("changed"), url = output.gifURL
            let bytes = try Data(contentsOf: url), handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data([0])); try handle.close()
            try await rejects { _ = try output.checkedURLs() }; try await rejects { try output.cleanup() }
            let restore = try FileHandle(forWritingTo: url); try restore.write(contentsOf: bytes); try restore.close()
            let alias = output.parent.appendingPathComponent("alias.gif")
            try FileManager.default.linkItem(at: url, to: alias)
            try await rejects { _ = try output.checkedURLs() }; try await rejects { try output.cleanup() }
            try FileManager.default.removeItem(at: alias); try output.cleanup()
        }
        await test("moved directory identity is refused and original restoration allows cleanup") {
            let output = try await actualOutput("directory"), original = output.directory
            let moved = output.parent.appendingPathComponent("owned-moved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            try await rejects { _ = try output.checkedURLs() }; try await rejects { try output.cleanup() }
            try require(FileManager.default.fileExists(atPath: moved.appendingPathComponent("animation.gif").path), "Moved original was removed")
            try FileManager.default.removeItem(at: original); try FileManager.default.moveItem(at: moved, to: original); try output.cleanup()
        }
        await test("missing owned file permits cleanup of only the remaining known file") {
            let output = try await actualOutput("missing")
            try FileManager.default.removeItem(at: output.gifURL)
            try await rejects { _ = try output.checkedURLs() }
            try output.cleanup(); try require(output.isCleaned, "Partial cleanup could not finish")
        }
        await test("releasing a handle preserves completed consumer files") {
            var output: StudioGIFExportService.Output? = try await actualOutput("released")
            let gif = output!.gifURL, manifest = output!.manifestURL
            weak var weakOutput = output; output = nil
            try require(weakOutput == nil && FileManager.default.fileExists(atPath: gif.path)
                && FileManager.default.fileExists(atPath: manifest.path), "Handle release deleted consumer files or retained itself")
        }
        await test("symlink parent and absent destination produce no completed files") {
            let link = folder.appendingPathComponent("parent-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
            let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            for parent in [link, folder.appendingPathComponent("absent")] {
                try await rejects { _ = try await StudioGIFExportService().export(.init(document: document(), rasterDataByID: [:]), outputParent: parent) }
            }
            try require(FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before, "Invalid destination created files")
        }
        await test("cancelled encoding cannot publish a GIF file set") {
            let parent = folder.appendingPathComponent("cancelled-files")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let task = Task { @MainActor in
                try await StudioGIFExportService().export(.init(document: document(), rasterDataByID: [:]), outputParent: parent) { _ in withUnsafeCurrentTask { $0?.cancel() } }
            }
            do { _ = try await task.value; throw Failure(message: "Cancelled export published files") }
            catch is CancellationError {}
            try require(FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty, "Cancelled export left files")
        }
        await test("large actual GIF verifies every file-write chunk and preserves its original raster") {
            let size = 512
            var rgba = [UInt8](repeating: 255, count: size * size * 4), seed: UInt32 = 42
            for pixel in 0..<(size * size) {
                seed = 1664525 &* seed &+ 1013904223
                rgba[pixel * 4] = UInt8(truncatingIfNeeded: seed >> 24)
                rgba[pixel * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 16)
                rgba[pixel * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 8)
            }
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let original = NSMutableData(), png = CGImageDestinationCreateWithData(original, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(png, image, nil); try require(CGImageDestinationFinalize(png), "Original generated raster could not encode")
            let immutable = original as Data
            var doc = try document(["#FF0000"], width: size, height: size)
            doc.frames[0].elements = []; doc.frames[0].rasterAssetID = "original"; doc.frames[0].rasterLayerID = doc.activeLayerID
            let parent = folder.appendingPathComponent("large")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let output = try await StudioGIFExportService().export(.init(document: doc, rasterDataByID: ["original": immutable]), outputParent: parent)
            let urls = try output.checkedURLs(), actual = try Data(contentsOf: urls[0])
            try require(actual.count > 131_072 && output.receipt.encodedBytes == actual.count, "Large GIF did not exercise multiple writes")
            let decoded = try decode(actual, index: 0)
            try require(decoded.width == size && decoded.height == size && original as Data == immutable, "Large GIF resized or changed original raster")
            try require(output.receipt.version == 1, "Unversioned GIF receipt")
            try output.cleanup()
        }
        print("STUDIO_GIF_TESTS: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
