import Foundation
import CoreGraphics
import ImageIO
import Darwin

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure(message: "Unsafe operation succeeded")
}
@main @MainActor struct BackgroundCutTests {
    static func png() throws -> Data {
        var pixels = [UInt8](repeating: 255, count: 9 * 9 * 4)
        for y in 2...6 { for x in 2...6 where x == 2 || x == 6 || y == 2 || y == 6 {
            let i = (y * 9 + x) * 4
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
        } }
        pixels[0] = 248; pixels[1] = 248; pixels[2] = 248
        let red = (3 * 9 + 1) * 4; pixels[red + 1] = 0; pixels[red + 2] = 0
        let image = CGImage(width: 9, height: 9, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 36,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Fixture encode")
        return data as Data
    }
    static func pixels(_ data: Data) throws -> [UInt8] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var bytes = [UInt8](repeating: 0, count: 9 * 9 * 4)
        bytes.withUnsafeMutableBytes { memory in
            let context = CGContext(data: memory.baseAddress, width: 9, height: 9, bitsPerComponent: 8, bytesPerRow: 36,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 9))
        }
        return bytes
    }
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdi-cut-test-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = try png()
            let exact = try StudioBackgroundCut.remove(from: original, red: 255, green: 255, blue: 255, tolerance: 0)
            let wider = try StudioBackgroundCut.remove(from: original, red: 255, green: 255, blue: 255, tolerance: 3)
            try require(exact.removedPixels == 54 && wider.removedPixels == 55, "Tolerance did not affect edge color matching")
            let before = try pixels(original), after = try pixels(wider.png)
            for i in 0..<81 where before[i * 4] == 0 || before[i * 4 + 1] == 0 {
                try require(Array(after[i * 4..<i * 4 + 4]) == Array(before[i * 4..<i * 4 + 4]), "Foreground pixels/orientation changed")
            }
            try require(after[(4 * 9 + 4) * 4 + 3] == 255 && after[3] == 0, "Enclosed region or edge alpha incorrect")
            let noMatch = try StudioBackgroundCut.remove(from: original, red: 0, green: 255, blue: 0, tolerance: 0)
            try require(noMatch.png == original && noMatch.removedPixels == 0, "No-op rewrote original")
            try rejects { _ = try StudioBackgroundCut.remove(from: original, red: 255, green: 255, blue: 255, tolerance: 101) }
            try rejects { _ = try StudioBackgroundCut.remove(from: Data([1]), red: 0, green: 0, blue: 0, tolerance: 0) }
            var totalChecks = 0
            _ = try StudioBackgroundCut.remove(from: original, red: 255, green: 255, blue: 255, tolerance: 3, checkCancellation: { totalChecks += 1 })
            for boundary in 1...totalChecks {
                var checks = 0
                try rejects { _ = try StudioBackgroundCut.remove(from: original, red: 255, green: 255, blue: 255, tolerance: 3, checkCancellation: {
                    checks += 1; if checks == boundary { throw CancellationError() }
                }) }
            }
            print("PASS real PNG edge flood removal, tolerance, enclosed/colored foreground preservation, no-op and every cancellation checkpoint")
            let url = root.appendingPathComponent("original.png"); try original.write(to: url)
            let imported = try await StudioImageImportService.shared.importImage(from: url, name: "Cut fixture")
            let storage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("documents"))
            let vm = StudioViewModel(storage: storage)
            let created = await vm.createProject(name: "Reversible cut", width: 64, height: 64, fps: 12)
            try require(created, "Create")
            let asset = try vm.attachImportedImage(imported, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
                frameID: vm.document.activeFrameID, layerID: vm.document.activeLayerID)
            vm.duplicateFrame()
            let capture = try vm.prepareImageCut(allFrames: true), snapshot = vm.document
            var commitChecks = 0
            try rejects { _ = try vm.applyImageCut(capture, replacements: [asset: wider.png], checkCancellation: {
                commitChecks += 1; if commitChecks == 3 { throw CancellationError() }
            }) }
            try require(vm.document == snapshot && vm.rasterData(asset) == imported.normalizedPNG, "Cancelled commit mutated project")
            let affected = try vm.applyImageCut(capture, replacements: [asset: wider.png])
            try require(affected == 2 && Set(vm.frames.compactMap { $0.rasterAssetID }).count == 1, "Batch did not update shared image references")
            let changedID = vm.currentFrame.rasterAssetID!
            try require(changedID != asset && vm.originalImageSource(changedID)?.originalData == original, "Original bytes/identity overwritten")
            try require(vm.rasterData(asset) == imported.normalizedPNG && vm.rasterData(changedID) == wider.png, "History renditions lost")
            vm.undo(); try require(vm.frames.allSatisfy { $0.rasterAssetID == asset }, "Batch requires more than one undo")
            vm.redo(); try require(vm.frames.allSatisfy { $0.rasterAssetID == changedID }, "Redo lost cut rendition")
            try rejects { _ = try vm.applyImageCut(capture, replacements: [asset: wider.png]) }
            let projectID = vm.document.id
            await vm.backToProjects()
            let metadata = try storage.loadAnimation(id: projectID)!.metadata
            let reopened = StudioViewModel(storage: storage)
            let opened = await reopened.openProject(metadata)
            try require(opened && reopened.rasterData(changedID) == wider.png && reopened.originalImageSource(changedID)?.originalData == original, "Cold reopen lost original or cut pixels")
            if let layer = reopened.currentFrame.rasterLayerID { reopened.setLayerLockMode(layer, mode: .full) }
            try rejects { _ = try reopened.prepareImageCut(allFrames: false) }
            await reopened.backToProjects()
            print("PASS atomic two-frame cut, immutable original, cancel/stale rejection, one Undo/Redo, actual persistence/cold reopen and locked-layer denial")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
