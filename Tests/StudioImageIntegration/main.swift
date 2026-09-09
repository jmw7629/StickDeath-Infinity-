import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure(message: "Expected explicit rejection")
}

/// Entire production decoder, document, VM, store, renderer and PNG exporter.
/// All media fixtures are generated here; no mirrored image/persistence model.
@main @MainActor struct StudioImageIntegrationTests {
    static let fm = FileManager.default
    static func png(width: Int = 80, height: Int = 40, orientation: Int = 1, noise: Bool = false) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4), seed: UInt32 = 0x83726519
        for pixel in 0..<(width * height) {
            let x = pixel % width, i = pixel * 4
            if noise {
                for channel in 0..<3 { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; bytes[i + channel] = UInt8(truncatingIfNeeded: seed) }
                bytes[i + 3] = 255
            } else {
                bytes[i] = x < width / 2 ? 255 : 0
                bytes[i + 2] = x < width / 2 ? 0 : 128
                bytes[i + 3] = x < width / 2 ? 255 : 128
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try require(CGImageDestinationFinalize(writer), "Fixture PNG encode failed")
        return data as Data
    }
    static func imported(_ bytes: Data, in root: URL, name: String = "Asymmetric still") async throws -> StudioImageImportService.ImportedImage {
        let file = root.appendingPathComponent(UUID().uuidString + ".png")
        try bytes.write(to: file, options: .withoutOverwriting)
        return try await StudioImageImportService().importImage(from: file, name: name, scratchParent: root)
    }
    static func project(_ root: URL) async throws -> (StudioViewModel, DeviceStorageManager) {
        let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(UUID().uuidString))
        let vm = StudioViewModel(storage: store)
        let created = await vm.createProject(name: "Image integration", width: 160, height: 160, fps: 12)
        try require(created, "Actual create/save failed")
        return (vm, store)
    }
    @discardableResult static func attach(_ image: StudioImageImportService.ImportedImage, to vm: StudioViewModel) throws -> String {
        try vm.attachImportedImage(image, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
            frameID: vm.document.activeFrameID, layerID: vm.document.activeLayerID)
    }
    struct Raster {
        let width: Int, height: Int
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    }
    static func pixels(_ image: CGImage) -> Raster {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Raster(width: image.width, height: image.height, bytes: bytes)
    }
    static func pixel(_ actual: [UInt8], _ expected: [UInt8]) throws {
        try require(zip(actual, expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }, "RGBA \(actual) != \(expected)")
    }
    static func render(_ vm: StudioViewModel, transparent: Bool = false, scale: Double = 1) throws -> Raster {
        let doc = vm.document, frame = vm.currentFrame, data = vm.rasterData(frame.rasterAssetID)
        let brush = try StudioFrameRenderer.prepare(frame: frame)
        let raster = try StudioFrameRenderer.prepareRaster(frame: frame, layers: doc.layers, data: data, maximumDimension: 128)
        var failure: Error?
        let content = Canvas { context, size in
            if !transparent { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white)) }
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: doc.layers,
                canvasSize: CGSize(width: doc.width, height: doc.height), size: size,
                rasterData: data, preparedBrushes: brush, preparedRaster: raster)
        }.frame(width: Double(doc.width) * scale, height: Double(doc.height) * scale)
        let image = ImageRenderer(content: content); image.scale = 1
        guard let cg = image.cgImage else { throw Failure(message: "Actual SwiftUI renderer failed") }
        if let failure { throw failure }
        return pixels(cg)
    }
    static func decoded(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Actual exported PNG could not reopen") }
        return pixels(image)
    }
    static func main() async {
        do { try await run() } catch { print("STUDIO_IMAGE_INTEGRATION_TESTS=FAIL \(error)"); exit(1) }
    }
    static func run() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-image-integration-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let original = try png(), image = try await imported(original, in: root)
        let evidence: URL?
        if let path = ProcessInfo.processInfo.environment["SDI_IMAGE_TEST_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            evidence = directory
            print("IMAGE_TEST_ARTIFACTS=\(directory.path)")
        } else { evidence = nil }
        var passed = 0
        func test(_ name: String, _ action: () async throws -> Void) async throws {
            try await action(); passed += 1; print("PASS \(name)")
        }
        try await test("actual still attaches in one history transaction with stable identities and aspect fit") {
            let (vm, _) = try await project(root), before = vm.document
            let id = try attach(image, to: vm)
            try require(vm.document.schemaVersion == 3 && vm.document.revision == before.revision + 1 && vm.layers.count == 2,
                "Image did not become one version3 canonical edit")
            try require(vm.document.activeLayerID == before.activeLayerID && vm.currentFrame.id == before.activeFrameID && vm.frames.count == 1,
                "Image import changed selection or other frame timing")
            try require(vm.currentFrame.rasterAssetID == id && vm.currentFrame.rasterPlacement == .init(x: 0, y: 40, width: 160, height: 80), "Aspect-fit placement is wrong")
            try require(vm.originalImageSource(id)?.originalData == original && vm.rasterData(id) == image.normalizedPNG, "Original/normalized bytes were not retained separately")
            let rendered = try render(vm)
            try pixel(rendered.pixel(30, 15), [255, 255, 255, 255]); try pixel(rendered.pixel(30, 80), [255, 0, 0, 255])
            try pixel(rendered.pixel(130, 80), [127, 127, 255, 255])
            vm.undo(); try require(vm.currentFrame.rasterAssetID == nil && vm.layers == before.layers && !vm.canUndo, "One Undo did not restore the whole prior document")
            try require(vm.originalImageSource(id)?.originalData == original, "Undo destroyed the image needed for Redo")
            vm.redo(); try require(try render(vm).bytes == rendered.bytes && vm.currentFrame.rasterAssetID == id, "Redo changed image identity or pixels")
        }
        try await test("actual snapshot save/reopen and PNG sequence/spritesheet use the same image pixels") {
            let (vm, store) = try await project(root), id = try attach(image, to: vm)
            let live = try render(vm); vm.duplicateFrame(); try require(vm.frames.count == 2, "Duplicate failed")
            let saved = await vm.save(); try require(saved, "Actual image snapshot save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!
            try require(stored.frames.count == 2 && stored.frames.allSatisfy { $0.sourceImage?.originalData == original }, "Store lost original bytes in duplicate")
            let reopened = StudioViewModel(storage: store), opened = await reopened.openProject(stored.metadata)
            try require(opened && reopened.document == vm.document && reopened.originalImageSource(id)?.originalData == original, "Real reopen changed the image document")
            try require(try render(reopened).bytes == live.bytes, "Reopened image pixels differ")
            for format in [StudioExportService.Format.pngSequence, .spritesheet] {
                let output = try await StudioExportService().export(document: reopened.document, format: format, outputParent: root, rasterData: { reopened.rasterData($0) })
                let png = try decoded(output.imageURLs[0]); try require(png.width == (format == .pngSequence ? 160 : 320) && png.height == 160, "Export geometry is incorrect")
                try pixel(png.pixel(30, 15), [255, 255, 255, 255]); try pixel(png.pixel(30, 80), [255, 0, 0, 255])
                if format == .pngSequence { try require(png.bytes == live.bytes, "Live and real PNG rendering diverged") }
                else { try pixel(png.pixel(190, 80), [255, 0, 0, 255]) }
                if let evidence { try fm.copyItem(at: output.imageURLs[0], to: evidence.appendingPathComponent(format.rawValue + ".png")) }
            }
        }
        try await test("layer visibility opacity ordering and alpha affect shared live and actual export pixels") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            let layer = vm.currentFrame.rasterLayerID!
            vm.setLayerOpacity(layer, opacity: 0.5); try pixel(render(vm).pixel(30, 80), [255, 128, 128, 255])
            vm.toggleLayerVisibility(layer); try pixel(render(vm).pixel(30, 80), [255, 255, 255, 255]); vm.toggleLayerVisibility(layer)
            vm.setLayerOpacity(layer, opacity: 1)
            let line = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 0, y: 80), .init(x: 160, y: 80)], color: "#00FF00", width: 20, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(line), "Editable overlay failed"); try pixel(render(vm).pixel(30, 80), [0, 255, 0, 255])
            vm.moveLayerUp(layer); try pixel(render(vm).pixel(30, 80), [255, 0, 0, 255]); vm.undo(); vm.undo()
            let transparent = try await StudioExportService().export(document: vm.document, format: .pngSequence, outputParent: root, background: .transparent, rasterData: { vm.rasterData($0) })
            let output = try decoded(transparent.imageURLs[0]); try pixel(output.pixel(30, 15), [0, 0, 0, 0]); try pixel(output.pixel(130, 80), [0, 0, 128, 128])
            let thumb = try render(vm, scale: 0.25); try pixel(thumb.pixel(7, 3), [255, 255, 255, 255]); try pixel(thumb.pixel(7, 20), [255, 0, 0, 255])
            vm.selectLayer(layer)
            let eraser = DrawnElement(id: UUID().uuidString, tool: .eraser, points: [.init(x: 30, y: 80)], color: "#000000", width: 10, opacity: 1, layerID: layer)
            try require(vm.commitElement(eraser), "Eraser could not edit selected image layer")
            try pixel(render(vm).pixel(30, 80), [255, 255, 255, 255])
            try require(vm.originalImageSource(vm.currentFrame.rasterAssetID!)?.originalData == original, "Editing an image layer modified the original bytes")
        }
        try await test("oriented input keeps exact original metadata and aspect fit after normalization") {
            let bytes = try png(orientation: 6), rotated = try await imported(bytes, in: root)
            let (vm, store) = try await project(root), id = try attach(rotated, to: vm)
            try require(rotated.width == 40 && rotated.height == 80 && vm.currentFrame.rasterPlacement == .init(x: 40, y: 0, width: 80, height: 160), "Image orientation or fit changed")
            let saved = await vm.save(); try require(saved, "Oriented image save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!
            try require(stored.frames[0].sourceImage?.originalData == bytes && vm.originalImageSource(id)?.originalOrientation == 6, "Source orientation/bytes were overwritten")
            let rendered = try render(vm); try pixel(rendered.pixel(10, 80), [255, 255, 255, 255])
        }
        try await test("fractional fit rounding remains centered and preserves asymmetric original pixels") {
            for (width, canvas) in [(147, 160), (133, 270), (133, 1080), (29, 1920)] {
                let bytes = try png(width: width, height: 20), decodedImage = try await imported(bytes, in: root)
                let store = DeviceStorageManager(documentsDirectory: root.appendingPathComponent(UUID().uuidString))
                let vm = StudioViewModel(storage: store)
                let created = await vm.createProject(name: "Fractional image fit", width: canvas, height: canvas, fps: 12)
                try require(created, "Fractional fit fixture could not create its actual project")
                let asset = try attach(decodedImage, to: vm), rect = vm.currentFrame.rasterPlacement!
                try require(rect.x == 0 && rect.width == Double(canvas) && rect.y >= 0 && rect.y + rect.height <= Double(canvas),
                    "Roundoff rejected or displaced a valid fit")
                try require(abs(rect.y * 2 + rect.height - Double(canvas)) < 0.000001,
                    "Fit was not centered after floating-point normalization")
                let result = try render(vm)
                try pixel(result.pixel(canvas / 4, canvas / 2), [255, 0, 0, 255])
                try pixel(result.pixel(canvas * 3 / 4, canvas / 2), [127, 127, 255, 255])
                try pixel(result.pixel(canvas / 4, 1), [255, 255, 255, 255])
                try require(vm.originalImageSource(asset)?.originalData == bytes,
                    "Numerical fit changed the original asymmetric input")
            }
        }
        try await test("frame clipboard retains image beyond deleted original and expired undo history") {
            let (vm, store) = try await project(root), id = try attach(image, to: vm), originalFrame = vm.currentFrame.id
            vm.copyFrame(); vm.addFrame(); vm.deleteFrame(originalFrame)
            for i in 0..<55 { vm.setLayerOpacity(vm.activeLayerID, opacity: i % 2 == 0 ? 0.75 : 1) }
            try require(vm.frames.allSatisfy { $0.rasterAssetID == nil } && vm.originalImageSource(id)?.originalData == original, "Frame clipboard lost its owned source after history trim")
            vm.pasteFrame(); try require(vm.currentFrame.rasterAssetID == id && vm.currentFrame.rasterPlacement != nil, "Real frame paste did not restore retained still")
            let saved = await vm.save(); try require(saved, "Pasted still could not save")
            let stored = try store.loadAnimation(id: vm.document.id)!, reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(stored.metadata); try require(opened && reopened.originalImageSource(id)?.originalData == original, "Clipboard lifetime was not persisted after paste")
        }
        try await test("image bytes prune only after current history and clipboard all release ownership") {
            let (vm, _) = try await project(root), id = try attach(image, to: vm)
            vm.copyFrame(); vm.undo(); vm.copyFrame() // The actual blank frame replaces the clipboard.
            vm.addFrame() // A new branch releases Redo's image ownership.
            try require(vm.originalImageSource(id) == nil && vm.managedImageByteCount == 0, "Released image stayed retained forever")
        }
        try await test("schema3 survives styled brush commit frame duplicate paste and old JSON defaults") {
            let legacy = try StudioDocument.new(name: "Old", width: 160, height: 160, fps: 12)
            let decoded = try JSONDecoder().decode(StudioDocument.self, from: JSONEncoder().encode(legacy))
            try require(decoded.schemaVersion == 1 && decoded.frames[0].rasterPlacement == nil, "Legacy nil placement did not decode")
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            let brush = StudioBrushDescriptor(family: .round, seed: 123)
            let stroke = DrawnElement(id: UUID().uuidString, tool: .brush, points: [.init(x: 20, y: 20), .init(x: 40, y: 30)], color: "#FF0000", width: 8, opacity: 0.5, layerID: vm.activeLayerID, brush: brush)
            try require(vm.commitElement(stroke) && vm.document.schemaVersion == 3, "Brush downgraded the image schema")
            vm.copyFrame(); vm.pasteFrame(); vm.duplicateFrame()
            try require(vm.document.schemaVersion == 3 && vm.frames.allSatisfy { $0.rasterPlacement != nil }, "Copy/paste downgraded or dropped placement")
            var invalid = vm.document; invalid.schemaVersion = 2; try rejects { try invalid.validate() }
            invalid = vm.document; invalid.frames[0].rasterPlacement = .init(x: -.infinity, y: 0, width: 2, height: 2); try rejects { try invalid.validate() }
        }
        try await test("existing raster stale context input drafts and cancellation never attach an image") {
            let (vm, _) = try await project(root), before = vm.document
            for (projectID, revision, frameID, layerID) in [(UUID(), before.revision, before.activeFrameID, before.activeLayerID), (before.id, before.revision + 1, before.activeFrameID, before.activeLayerID), (before.id, before.revision, "missing", before.activeLayerID), (before.id, before.revision, before.activeFrameID, "missing")] {
                try rejects { _ = try vm.attachImportedImage(image, expectedProjectID: projectID, expectedRevision: revision, frameID: frameID, layerID: layerID) }
            }
            try require(vm.beginStrokeInput(id: "active"), "Actual touch capture did not start")
            try rejects { _ = try attach(image, to: vm) }; try require(vm.activeStrokeID == "active", "Import discarded active touch input"); vm.finishStrokeInput(id: "active")
            let draft = DrawnElement(id: "rejected", tool: .brush, points: [.init(x: 10, y: 10)], color: "#FF0000", width: 10, opacity: 1, layerID: vm.activeLayerID)
            vm.retainRejectedBrush(draft, frameID: vm.currentFrame.id, reason: "Test rejected stroke")
            try rejects { _ = try attach(image, to: vm) }; try require(vm.pendingBrushStroke?.element == draft, "Import discarded rejected drawing"); vm.discardRejectedBrush()
            for boundary in [1, 2] {
                var checks = 0
                try rejects { _ = try vm.attachImportedImage(image, expectedProjectID: before.id, expectedRevision: before.revision, frameID: before.activeFrameID, layerID: before.activeLayerID, checkCancellation: { checks += 1; if checks == boundary { throw CancellationError() } }) }
            }
            try require(vm.document == before && !vm.canUndo && vm.managedImageByteCount == 0, "Rejected import changed document/history/assets")
            _ = try attach(image, to: vm); let attached = vm.document
            try rejects { _ = try attach(image, to: vm) }; try require(vm.document == attached, "A second image replaced current raster")
        }
        try await test("final context check rejects synchronous reentrant changes without overwriting them") {
            let (vm, _) = try await project(root), captured = vm.document; var checks = 0
            try rejects { _ = try vm.attachImportedImage(image, expectedProjectID: captured.id, expectedRevision: captured.revision,
                frameID: captured.activeFrameID, layerID: captured.activeLayerID, checkCancellation: { checks += 1; if checks == 2 { vm.addFrame() } }) }
            try require(vm.frames.count == 2 && vm.frames.allSatisfy { $0.rasterAssetID == nil } && vm.managedImageByteCount == 0, "Image overwrote a newer document")
        }
        try await test("invalid original metadata normalized pixels and source collisions fail before history") {
            let (vm, _) = try await project(root), before = vm.document
            let bad = StudioImageImportService.ImportedImage(id: image.id, name: image.name, container: image.container, originalData: image.originalData,
                originalWidth: image.originalWidth + 1, originalHeight: image.originalHeight, originalOrientation: image.originalOrientation,
                width: image.width, height: image.height, normalizedPNG: image.normalizedPNG)
            try rejects { _ = try attach(bad, to: vm) }
            let corrupt = StudioImageImportService.ImportedImage(id: image.id, name: image.name, container: image.container, originalData: image.originalData,
                originalWidth: image.originalWidth, originalHeight: image.originalHeight, originalOrientation: image.originalOrientation,
                width: image.width, height: image.height, normalizedPNG: Data("corrupt".utf8))
            try rejects { _ = try attach(corrupt, to: vm) }
            try require(vm.document == before && vm.managedImageByteCount == 0 && !vm.canUndo, "Invalid image changed production editor")
            _ = try attach(image, to: vm); vm.addFrame(); let current = vm.document
            try rejects { _ = try attach(image, to: vm) }; try require(vm.document == current, "Reused source identity was overwritten")
        }
        try await test("actual store budget rejects repeated image frames transactionally before save") {
            let noise = try await imported(png(width: 1024, height: 1024, noise: true), in: root)
            let (vm, store) = try await project(root); _ = try attach(noise, to: vm)
            var rejected = false
            for _ in 0..<10 {
                let before = vm.document, bytes = vm.managedImageByteCount
                vm.duplicateFrame()
                if vm.frames.count == before.frames.count {
                    try require(vm.document == before && vm.managedImageByteCount == bytes && vm.message != nil, "Budget failure partially edited the project")
                    rejected = true; break
                }
            }
            try require(rejected, "Duplicate ignored the exact 40MiB atomic snapshot payload limit")
            let saved = await vm.save(); try require(saved, "Last accepted exact-budget document cannot actually save")
            let stored = try store.loadAnimation(id: vm.document.id)!
            try store.preflightAnimation(stored)
            print("IMAGE_BUDGET_ACCEPTED_FRAMES=\(stored.frames.count) UNIQUE_IMAGE_BYTES=\(vm.managedImageByteCount)")
            let warm = Date()
            for _ in 0..<240 { _ = try StudioRasterImage.prepare(assetID: vm.currentFrame.rasterAssetID!, data: noise.normalizedPNG, managed: true, maximumDimension: 1024) }
            print("LARGE_RASTER_240_PREPARES_SECONDS=\(Date().timeIntervalSince(warm))")
            let started = Date()
            let stroke = DrawnElement(id: UUID().uuidString, tool: .line, points: [.init(x: 10, y: 10), .init(x: 20, y: 10)], color: "#FF0000", width: 2, opacity: 1, layerID: vm.activeLayerID)
            try require(vm.commitElement(stroke), "Near-budget document rejected a small valid drawing")
            print("NEAR_BUDGET_COMPLETE_COMMIT_PREFLIGHT_SECONDS=\(Date().timeIntervalSince(started))")
        }
        try await test("failed disk save keeps attached image and dirty work available for actual retry") {
            let documents = root.appendingPathComponent(UUID().uuidString), store = DeviceStorageManager(documentsDirectory: documents)
            let vm = StudioViewModel(storage: store)
            let created = await vm.createProject(name: "Save failure", width: 160, height: 160, fps: 12); try require(created, "Create failed")
            let pointer = documents.appendingPathComponent("Animations/\(vm.document.id.uuidString)/.sdi/current.json")
            let pointerBytes = try Data(contentsOf: pointer), backup = pointer.deletingLastPathComponent().appendingPathComponent("test-pointer-backup")
            try fm.moveItem(at: pointer, to: backup)
            let foreign = root.appendingPathComponent("foreign-current"); try Data([12, 13]).write(to: foreign)
            try fm.createSymbolicLink(at: pointer, withDestinationURL: foreign)
            let id = try attach(image, to: vm), edited = vm.document
            let saved = await vm.save()
            try require(!saved && vm.isDirty && vm.document == edited && vm.originalImageSource(id)?.originalData == original,
                "Failed storage publication discarded or falsely saved attached image")
            try require(try Data(contentsOf: foreign) == Data([12, 13]) && Data(contentsOf: backup) == pointerBytes, "Failed save overwrote original or foreign pointer bytes")
            try fm.removeItem(at: pointer); try fm.moveItem(at: backup, to: pointer)
            let retried = await vm.save(); try require(retried && !vm.isDirty, "Preserved image could not be saved after safe repair")
            let stored = try store.loadAnimation(id: vm.document.id)!, reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(stored.metadata)
            try require(opened && reopened.originalImageSource(id)?.originalData == original, "Retry did not persist actual original image")
        }
        try await test("missing managed source fails closed on reopen; conflicting duplicate bytes cannot save") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            vm.duplicateFrame(); let saved = await vm.save(); try require(saved, "Fixture save failed")
            let originalProject = try store.loadAnimation(id: vm.document.id)!
            var conflicting = originalProject; conflicting.frames[1].imageData = Data([3, 4, 5])
            try rejects { try store.preflightAnimation(conflicting) }; try rejects { try store.saveAnimation(conflicting) }
            try require(try store.loadAnimation(id: vm.document.id)!.frames == originalProject.frames, "Conflicting source IDs overwrote selected snapshot")
            var missing = originalProject; missing.frames[0].sourceImage = nil; missing.frames[1].sourceImage = nil
            try store.saveAnimation(missing) // Corrupt fixture through the opaque store API, never through the editor.
            let reopened = StudioViewModel(storage: store), before = reopened.document
            let opened = await reopened.openProject(missing.metadata)
            try require(!opened && !reopened.isEditing && reopened.document == before && reopened.message != nil, "Missing managed source was silently adopted")
            try require(try store.loadAnimation(id: vm.document.id)!.frames == missing.frames, "Failed open rewrote corrupt source evidence")
        }
        try await test("command final cancellation callback cannot overwrite an intervening actual VM edit") {
            let (probe, _) = try await project(root); _ = try attach(image, to: probe)
            @MainActor func request(_ vm: StudioViewModel) -> StudioCommandRequest {
                .init(requestID: UUID(), projectID: vm.document.id, expectedRevision: vm.document.revision,
                    action: .apply([.addFrame(.init(after: .id(vm.document.activeFrameID), result: "new-frame"))]))
            }
            var probeChecks = 0
            _ = try probe.applyStudioCommands(request(probe), checkCancellation: { probeChecks += 1 })
            try require(probeChecks > 1, "Actual command transaction did not reach its final cancellation boundary")
            let (vm, _) = try await project(root); let asset = try attach(image, to: vm)
            let before = vm.document, command = request(vm)
            var checks = 0, intervening: StudioDocument?
            do {
                _ = try vm.applyStudioCommands(command, checkCancellation: {
                    checks += 1
                    if checks == probeChecks { vm.addLayer(); intervening = vm.document }
                })
                throw Failure(message: "Stale staged command overwrote the final callback's edit")
            } catch StudioCommandError.staleRevision { }
            try require(checks == probeChecks && intervening != nil && vm.document == intervening,
                "Command failed without preserving the actual intervening document")
            try require(vm.frames.count == before.frames.count && vm.layers.count == before.layers.count + 1,
                "Stale command published its frame or erased the new layer")
            try require(vm.originalImageSource(asset)?.originalData == original, "Stale command discarded original image bytes")
            vm.undo(); try require(vm.layers == before.layers && vm.frames == before.frames, "Intervening edit history was overwritten")
        }
        try await test("managed original records without placement archive are preserved and refused as legacy") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            let saved = await vm.save(); try require(saved, "Image fixture save failed")
            var missing = try store.loadAnimation(id: vm.document.id)!
            missing.editableDocumentData = nil
            try store.saveAnimation(missing) // Simulate loss of the archive through the opaque storage API.
            let reopened = StudioViewModel(storage: store), before = reopened.document
            let opened = await reopened.openProject(missing.metadata)
            try require(!opened && !reopened.isEditing && reopened.document == before && reopened.message != nil,
                "Managed image without placement metadata was reinterpreted as historical stretch")
            let after = try store.loadAnimation(id: missing.id)!
            try require(after.frames == missing.frames && after.editableDocumentData == nil,
                "Refused open changed the original image evidence")
        }
        try await test("optimized snapshot encoding is real Codable-equivalent and invalidates changed image fragments") {
            let (vm, store) = try await project(root); _ = try attach(image, to: vm)
            vm.duplicateFrame(); let saved = await vm.save(); try require(saved, "Fixture save failed")
            var value = try store.loadAnimation(id: vm.document.id)!
            value.metadata.title = #"Literal "frames":[] stays text"#
            try store.preflightAnimation(value); try store.saveAnimation(value)
            var loaded = try store.loadAnimation(id: vm.document.id)!
            try require(loaded.metadata.title == value.metadata.title && loaded.frames == value.frames && loaded.editableDocumentData == value.editableDocumentData,
                "Actual encoded Revision changed metadata, frames or archive bytes")
            let reference = try JSONDecoder().decode(AnimationProject.self, from: JSONEncoder().encode(value))
            try require(loaded.frames == reference.frames && loaded.editableDocumentData == reference.editableDocumentData,
                "Optimized serializer disagrees with full production Codable values")
            for index in value.frames.indices { value.frames[index].layerData = [.init(id: UUID(), name: "New frame metadata", opacity: 0.6, blendMode: "normal", locked: false, visible: true)] }
            try store.saveAnimation(value); loaded = try store.loadAnimation(id: vm.document.id)!
            try require(loaded.frames == value.frames, "Cached image fragment retained stale frame metadata")
            let cache = DeviceStorageManager.snapshotEncodingCacheFootprint
            try require(cache.entries <= 32 && cache.bytes <= DeviceStorageManager.maximumSnapshotFrameCacheBytes, "Snapshot fragment cache exceeded bounded key/data capacity")
        }
        try await test("managed missing corrupt and mismatched prepared pixels return actual render/export errors") {
            let (vm, _) = try await project(root); _ = try attach(image, to: vm)
            try rejects { _ = try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers, data: nil) }
            try rejects { _ = try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers, data: Data([1, 2])) }
            let originalFiles = try Set(fm.contentsOfDirectory(atPath: root.path))
            do {
                _ = try await StudioExportService().export(document: vm.document, format: .pngSequence, outputParent: root)
                throw Failure(message: "Missing managed image falsely exported")
            } catch is StudioExportService.ExportError { }
            try require(try Set(fm.contentsOfDirectory(atPath: root.path)) == originalFiles, "Failed PNG export leaked partial files")
            let one = try StudioRasterImage.prepare(assetID: "same-id", data: image.normalizedPNG, managed: true)
            let alternate = try await imported(png(width: 40, height: 20), in: root)
            let two = try StudioRasterImage.prepare(assetID: "same-id", data: alternate.normalizedPNG, managed: true)
            try require(one.image.width == 80 && two.image.width == 40, "Raster cache reused same-ID stale pixels")
            vm.toggleLayerVisibility(vm.currentFrame.rasterLayerID!)
            try require(try StudioFrameRenderer.prepareRaster(frame: vm.currentFrame, layers: vm.layers, data: nil) == nil, "Hidden image incorrectly required visible pixels")
        }
        try await test("legacy flattened images and opaque layer/audio bytes remain unchanged on image-era save") {
            let (_, store) = try await project(root), id = UUID(), now = Date()
            let layer = LayerData(id: UUID(), name: "Opaque", opacity: 0.3, blendMode: "legacy", locked: true, visible: false)
            let audio = AudioTrack(id: UUID(), name: "Original", format: "wav", audioData: Data([7, 8, 9]), startTime: 0, duration: 0, legacySourceFilename: "audio_2.wav")
            let metadata = AnimationMetadata(id: id, title: "Historical", fps: 12, canvasWidth: 160, canvasHeight: 160, frameCount: 2, layerCount: 1, createdAt: now, modifiedAt: now, thumbnailData: nil)
            let records = [StoredAnimationFrame(imageData: image.normalizedPNG, layerData: [layer]), StoredAnimationFrame(imageData: nil, layerData: [layer])]
            try store.saveAnimation(AnimationProject(id: id, metadata: metadata, frames: records, audioTracks: [audio]))
            let vm = StudioViewModel(storage: store), opened = await vm.openProject(metadata); try require(opened, "Legacy records became unopenable")
            try require(vm.currentFrame.rasterPlacement == nil, "Legacy raster was silently refit")
            try pixel(render(vm).pixel(30, 15), [255, 0, 0, 255])
            let before = vm.document; try rejects { _ = try attach(image, to: vm) }; try require(vm.document == before, "Legacy raster was replaced")
            let saved = await vm.save(); try require(saved, "Legacy image-era save failed")
            let after = try store.loadAnimation(id: id)!
            try require(after.frames == records && after.audioTracks[0].audioData == audio.audioData, "Legacy opaque records/audio were discarded")
        }
        try await test("image cache remains bounded during many keys and repeated live preparations") {
            let start = Date()
            for i in 0..<150 { _ = try StudioRasterImage.prepare(assetID: "key-\(i)", data: image.normalizedPNG, managed: true, maximumDimension: 128) }
            let footprint = StudioRasterImage.footprint
            try require(footprint.entries <= StudioRasterImage.maximumCacheEntries && footprint.bytes <= StudioRasterImage.maximumCacheBytes, "Raster cache exceeded its key/pixel/encoded-memory budget")
            let warm = Date()
            for _ in 0..<240 { _ = try StudioRasterImage.prepare(assetID: "key-149", data: image.normalizedPNG, managed: true, maximumDimension: 128) }
            print("RASTER_CACHE_150_KEYS_SECONDS=\(warm.timeIntervalSince(start)) WARM_240_PREPARES_SECONDS=\(Date().timeIntervalSince(warm)) BYTES=\(footprint.bytes)")
        }
        print("STUDIO_IMAGE_INTEGRATION_TESTS=PASS \(passed) actual production cases")
    }
}
