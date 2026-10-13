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
/// Holds a real post-acquisition checkpoint without relying on scheduler timing.
private final class BatchBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func check() throws {
        lock.lock(); checks += 1; let current = checks; lock.unlock()
        // Initial cancellation, one metadata preflight, then acquired lease.
        if current == 3 {
            entered.signal()
            guard resume.wait(timeout: .now() + 10) == .success else {
                throw Failure(message: "Background Cut barrier timed out")
            }
        }
        try Task.checkCancellation()
    }
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
            let barrier = BatchBarrier()
            let held = Task.detached {
                try await StudioBackgroundCut.removeBatch(from: ["source": original], red: 255, green: 255,
                    blue: 255, tolerance: 3, checkCancellation: { try barrier.check() })
            }
            let entered = await Task.detached { barrier.entered.wait(timeout: .now() + 10) == .success }.value
            try require(entered, "Background Cut did not enter actual leased work")
            held.cancel()
            do {
                _ = try await StudioBackgroundCut.removeBatch(from: ["other": original], red: 255,
                    green: 255, blue: 255, tolerance: 3)
                throw Failure(message: "Cancelled decoder released its memory lease before returning")
            } catch StudioBackgroundCut.Failure.busy { }
            barrier.resume.signal()
            do { _ = try await held.value; throw Failure(message: "Cancelled batch published pixels") }
            catch is CancellationError { }
            let nextBatch = try await StudioBackgroundCut.removeBatch(from: ["a": original, "b": original],
                red: 255, green: 255, blue: 255, tolerance: 3)
            try require(nextBatch.count == 2 && nextBatch.values.allSatisfy {
                $0.png == wider.png && $0.removedPixels == wider.removedPixels
            }, "Batch lease was not released or real PNG output changed")
            do {
                _ = try await StudioBackgroundCut.removeBatch(from: Dictionary(uniqueKeysWithValues: (0..<17).map { ("\($0)", original) }),
                    red: 255, green: 255, blue: 255, tolerance: 3)
                throw Failure(message: "Oversized batch admitted")
            } catch StudioBackgroundCut.Failure.limit { }
            do {
                _ = try await StudioBackgroundCut.removeBatch(from: ["a": original], red: 255, green: 255,
                    blue: 255, tolerance: 3, checkCancellation: { throw CancellationError() })
                throw Failure(message: "Precancelled batch admitted")
            } catch is CancellationError { }
            let afterFailure = try await StudioBackgroundCut.removeBatch(from: ["a": original], red: 255,
                green: 255, blue: 255, tolerance: 3)
            try require(afterFailure["a"]?.png == wider.png, "Failure leaked batch ownership")
            print("PASS actual single-owner Background Cut rejects overlap until cancelled worker returns, releases ownership and retains exact PNG output")
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
            let linkedStorage = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("linked-documents"))
            let linked = StudioViewModel(storage: linkedStorage)
            let linkedCreated = await linked.createProject(name: "Linked frame cut", width: 64, height: 64, fps: 12)
            try require(linkedCreated, "Linked create")
            let linkedAsset = try linked.attachImportedImage(imported, expectedProjectID: linked.document.id,
                expectedRevision: linked.document.revision, frameID: linked.document.activeFrameID, layerID: linked.document.activeLayerID)
            let primaryLayer = linked.currentFrame.rasterLayerID!
            linked.duplicateLayer(primaryLayer)
            let aliasLayer = linked.document.activeLayerID
            try require(aliasLayer != primaryLayer && linked.currentFrame.rasterLayerInstances.count == 2, "Actual duplicate did not create linked image layer")
            linked.selectedTool = .move
            await linked.flush()
            try require(linked.copyImage(), "Copy selected linked instance")
            let firstFrameID = linked.document.activeFrameID
            linked.duplicateFrame()
            await linked.flush()
            let targetFrameID = linked.document.activeFrameID
            try require(targetFrameID != firstFrameID, "Actual frame duplicate failed")

            // All affected copies must be editable, even when their sibling is selected.
            for restriction in ["hidden", "full", "position", "alpha", "transparent"] {
                switch restriction {
                case "hidden": linked.toggleLayerVisibility(primaryLayer)
                case "transparent": linked.setLayerOpacity(primaryLayer, opacity: 0)
                case "full": linked.setLayerLockMode(primaryLayer, mode: .full)
                case "position": linked.setLayerLockMode(primaryLayer, mode: .position)
                default: linked.setLayerLockMode(primaryLayer, mode: .alpha)
                }
                await linked.flush()
                let denied = linked.document, deniedUndo = linked.canUndo, deniedRedo = linked.canRedo
                try rejects { _ = try linked.prepareImageCut(allFrames: false) }
                try require(linked.document == denied && linked.canUndo == deniedUndo && linked.canRedo == deniedRedo &&
                    linked.rasterData(linkedAsset) == imported.normalizedPNG, "Linked Cut denial changed source/history")
                linked.undo(); await linked.flush()
            }

            // A reentrant layer change at the final checkpoint must survive the rejected cut.
            let lateCapture = try linked.prepareImageCut(allFrames: false)
            var checkpoints = 0, lateDocument: StudioDocument?
            try rejects { _ = try linked.applyImageCut(lateCapture, replacements: [linkedAsset: wider.png], checkCancellation: {
                checkpoints += 1
                if checkpoints == 3 { linked.selectLayer(primaryLayer); lateDocument = linked.document }
            }) }
            try require(lateDocument != nil && linked.document == lateDocument &&
                linked.frames.allSatisfy { $0.rasterAssetID == linkedAsset }, "Late layer switch was overwritten or cut partially committed")
            linked.selectLayer(aliasLayer); await linked.flush()
            let linkedCapture = try linked.prepareImageCut(allFrames: false), beforeLinkedCut = linked.document
            let linkedAffected = try linked.applyImageCut(linkedCapture, replacements: [linkedAsset: wider.png])
            let linkedCutID = linked.currentFrame.rasterAssetID!
            try require(linkedAffected == 1 && linkedCutID != linkedAsset && linked.currentFrame.rasterLayerInstances.count == 2,
                "Current-frame Cut did not update both linked copies as one frame")
            try require(linked.currentFrame.rasterLayerInstances == beforeLinkedCut.frames.first(where: { $0.id == targetFrameID })!.rasterLayerInstances,
                "Cut changed independent linked geometry")
            try require(linked.frames.first(where: { $0.id == firstFrameID })?.rasterAssetID == linkedAsset &&
                linked.rasterData(linkedCutID) == wider.png && linked.rasterData(linkedAsset) == imported.normalizedPNG &&
                linked.originalImageSource(linkedCutID)?.originalData == original, "Cut altered another frame or original bytes")
            linked.undo()
            try require(linked.frames.allSatisfy { $0.rasterAssetID == linkedAsset && $0.rasterLayerInstances.count == 2 }, "Linked Cut requires more than one Undo")
            linked.redo()
            try require(linked.currentFrame.rasterAssetID == linkedCutID, "Linked Cut Redo lost rendition")
            linked.addFrame(); await linked.flush()
            try require(linked.pasteImage(), "Retained pre-Cut linked clipboard could not paste to blank frame")
            try require(linked.currentFrame.rasterAssetID == linkedAsset && linked.currentFrame.rasterLayerInstances.count == 1 &&
                linked.rasterData(linked.currentFrame.rasterAssetID) == imported.normalizedPNG, "Image clipboard copied siblings or switched to new Cut source")
            let pastedFrameID = linked.document.activeFrameID, linkedProjectID = linked.document.id
            await linked.backToProjects()
            let linkedMetadata = try linkedStorage.loadAnimation(id: linkedProjectID)!.metadata
            let coldLinked = StudioViewModel(storage: linkedStorage)
            let linkedOpened = await coldLinked.openProject(linkedMetadata)
            try require(linkedOpened && coldLinked.frames.first(where: { $0.id == targetFrameID })?.rasterLayerInstances.count == 2 &&
                coldLinked.frames.first(where: { $0.id == targetFrameID })?.rasterAssetID == linkedCutID &&
                coldLinked.frames.first(where: { $0.id == pastedFrameID })?.rasterLayerInstances.count == 1 &&
                coldLinked.frames.first(where: { $0.id == pastedFrameID })?.rasterAssetID == linkedAsset &&
                coldLinked.rasterData(linkedAsset) == imported.normalizedPNG && coldLinked.rasterData(linkedCutID) == wider.png &&
                coldLinked.originalImageSource(linkedCutID)?.originalData == original, "Cold linked Cut reopen lost references/clipboard rendition/original")
            await coldLinked.backToProjects()
            print("PASS real linked frame Cut, sibling permission denial, late layer switch, old clipboard isolation, Undo/Redo and cold persisted renditions")
            let independentStore = DeviceStorageManager(documentsDirectory: root.appendingPathComponent("independent-documents"))
            let independent = StudioViewModel(storage: independentStore)
            let independentCreated = await independent.createProject(name: "Independent source cut", width: 64, height: 64, fps: 12)
            try require(independentCreated, "Independent create")
            let firstID = try independent.attachImportedImage(imported, expectedProjectID: independent.document.id,
                expectedRevision: independent.document.revision, frameID: independent.document.activeFrameID, layerID: independent.document.activeLayerID)
            let firstLayer = independent.currentFrame.rasterLayerID!
            let secondURL = root.appendingPathComponent("second.png"); try exact.png.write(to: secondURL)
            let secondImport = try await StudioImageImportService.shared.importImage(from: secondURL, name: "Independent edge")
            let secondID = try independent.attachImportedImage(secondImport, expectedProjectID: independent.document.id,
                expectedRevision: independent.document.revision, frameID: independent.document.activeFrameID, layerID: independent.document.activeLayerID)
            let secondLayer = independent.currentFrame.rasterLayerInstances.first { independent.currentFrame.rasterAssetID(on: $0.layerID) == secondID }!.layerID
            try require(independent.rasterData(firstID) != independent.rasterData(secondID), "Independent fixture does not contain distinct encoded sources")
            // A drawing layer is ambiguous when two different sources exist.
            try rejects { _ = try independent.prepareImageCut(allFrames: false) }
            independent.selectLayer(secondLayer); independent.duplicateLayer(secondLayer)
            let secondAlias = independent.activeLayerID
            independent.selectedTool = .move; await independent.flush()
            try require(independent.copyImage(), "Independent old-source clipboard")
            independent.setLayerLockMode(secondLayer, mode: .full); await independent.flush()
            try rejects { _ = try independent.prepareImageCut(allFrames: false) }
            independent.undo(); await independent.flush()
            independent.selectLayer(secondAlias)
            // An unrelated locked primary is not a target and must remain intact.
            independent.setLayerLockMode(firstLayer, mode: .full); await independent.flush()
            independent.selectLayer(secondAlias); await independent.flush()
            let independentCapture = try independent.prepareImageCut(allFrames: false)
            try require(Set(independentCapture.assetsByFrame.values) == [secondID], "Selected secondary source was not captured")
            let secondCut = try StudioBackgroundCut.remove(from: secondImport.normalizedPNG, red: 255, green: 255, blue: 255, tolerance: 3)
            try require(secondCut.removedPixels > 0, "Second source has no remaining edge background")
            let beforeIndependent = independent.document, independentUndo = independent.canUndo, independentRedo = independent.canRedo
            let originalFirstProjection = independent.currentFrame.projectedRasterFrame(on: firstLayer)
            for boundary in 1...3 {
                var count = 0
                try rejects { _ = try independent.applyImageCut(independentCapture, replacements: [secondID: secondCut.png], checkCancellation: {
                    count += 1; if count == boundary { throw CancellationError() }
                }) }
                try require(independent.document == beforeIndependent && independent.canUndo == independentUndo && independent.canRedo == independentRedo &&
                    independent.rasterData(secondID) == secondImport.normalizedPNG, "Cancelled independent Cut partially published")
            }
            try rejects { _ = try independent.applyImageCut(independentCapture, replacements: [firstID: wider.png]) }
            var lateCount = 0
            try rejects { _ = try independent.applyImageCut(independentCapture, replacements: [secondID: secondCut.png], checkCancellation: {
                lateCount += 1
                if lateCount == 3 { independent.selectLayer(firstLayer) }
            }) }
            try require(independent.activeLayerID == firstLayer && independent.currentFrame.rasterAssetID(on: secondLayer) == secondID,
                        "Late selection was overwritten or independent source partially changed")
            independent.selectLayer(secondAlias); await independent.flush()
            let freshIndependent = try independent.prepareImageCut(allFrames: false)
            let affectedIndependent = try independent.applyImageCut(freshIndependent, replacements: [secondID: secondCut.png])
            let newSecond = independent.currentFrame.rasterAssetID(on: secondLayer)!
            try require(affectedIndependent == 1 && newSecond != secondID && independent.currentFrame.rasterAssetID(on: secondAlias) == newSecond,
                        "Selected secondary and its linked alias did not change atomically")
            try require(independent.currentFrame.projectedRasterFrame(on: firstLayer) == originalFirstProjection &&
                independent.rasterData(firstID) == imported.normalizedPNG && independent.rasterData(secondID) == secondImport.normalizedPNG &&
                independent.rasterData(newSecond) == secondCut.png && independent.originalImageSource(newSecond)?.originalData == secondImport.originalData &&
                independent.originalImageSource(newSecond)?.catalogueAttribution == independent.originalImageSource(secondID)?.catalogueAttribution,
                        "Independent Cut changed unrelated primary, original bytes, alpha rendition or provenance")
            independent.undo()
            try require(independent.currentFrame.rasterAssetID(on: secondLayer) == secondID && independent.currentFrame.rasterAssetID == firstID,
                        "Independent Cut needs more than one Undo")
            independent.redo()
            try require(independent.currentFrame.rasterAssetID(on: secondLayer) == newSecond, "Independent Cut Redo lost source")
            print("PASS selected independent source Cut preserves locked sibling and old clipboard, linked permissions, all cancellation checkpoints, stale selection and one Undo Redo")

            // The same layer selects the primary across duplicated frames; only
            // that source changes, even with independent secondary renditions.
            independent.setLayerLockMode(firstLayer, mode: .free); independent.selectLayer(firstLayer)
            independent.duplicateFrame(); await independent.flush()
            let allIndependent = try independent.prepareImageCut(allFrames: true)
            try require(allIndependent.assetsByFrame.count == 2 && Set(allIndependent.assetsByFrame.values) == [firstID], "All-frame source selection changed scope")
            let allAffected = try independent.applyImageCut(allIndependent, replacements: [firstID: wider.png])
            let newFirst = independent.currentFrame.rasterAssetID!
            try require(allAffected == 2 && newFirst != firstID && independent.frames.allSatisfy {
                $0.rasterAssetID == newFirst && $0.rasterAssetID(on: secondLayer) == newSecond && $0.rasterAssetID(on: secondAlias) == newSecond
            }, "Primary Cut retargeted unrelated secondary sources")
            independent.undo(); try require(independent.frames.allSatisfy { $0.rasterAssetID == firstID && $0.rasterAssetID(on: secondLayer) == newSecond }, "All-frame independent Cut Undo")
            independent.redo()
            independent.addFrame(); await independent.flush()
            try require(independent.pasteImage(), "Pre-Cut independent clipboard missing")
            try require(independent.currentFrame.rasterAssetID == secondID && independent.rasterData(secondID) == secondImport.normalizedPNG,
                        "Independent clipboard silently switched to cut rendition")
            let independentProjectID = independent.document.id
            await independent.backToProjects()
            let independentMetadata = try independentStore.loadAnimation(id: independentProjectID)!.metadata
            let coldIndependent = StudioViewModel(storage: independentStore)
            let independentOpened = await coldIndependent.openProject(independentMetadata)
            try require(independentOpened && coldIndependent.frames.filter { $0.rasterAssetID == newFirst && $0.rasterAssetID(on: secondLayer) == newSecond }.count == 2 &&
                coldIndependent.rasterData(newFirst) == wider.png && coldIndependent.rasterData(newSecond) == secondCut.png &&
                coldIndependent.rasterData(secondID) == secondImport.normalizedPNG && coldIndependent.originalImageSource(newSecond)?.originalData == secondImport.originalData,
                        "Cold reopen lost independent Cut renditions or original source ownership")
            await coldIndependent.backToProjects()
            print("PASS two-source two-frame selected-primary Cut preserves secondary aliases, old image clipboard and actual cold original/normalized bytes")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}
