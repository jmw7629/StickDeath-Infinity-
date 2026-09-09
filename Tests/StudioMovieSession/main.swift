import AppKit
import Combine
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Only the platform image container is adapted. Both complete production
// exporters and the shared StudioFrameRenderer compile unchanged on macOS.
typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }

private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main @MainActor struct StudioMovieSessionTests {
    typealias Service = StudioMovieExportService
    static let fm = FileManager.default
    struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8] // RGBA, top row first.
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    }
    struct Decoded {
        let frames: [Raster]
        let pts: [CMTime]
        let durations: [CMTime]
        let duration: CMTime
    }
    static func document(colors: [String] = ["#FF0000", "#0000FF", "#00FF00"], width: Int = 64, height: Int = 32, fps: Int = 24) throws -> StudioDocument {
        var doc = try StudioDocument.new(name: "Actual movie fixture", width: width, height: height, fps: fps)
        doc.frames = colors.enumerated().map { index, color in
            AnimationFrame(id: "frame-\(index)", elements: [DrawnElement(id: "stroke-\(index)", tool: .brush,
                points: [StrokePoint(x: 0, y: CGFloat(height) / 2), StrokePoint(x: CGFloat(width), y: CGFloat(height) / 2)],
                color: color, width: CGFloat(height) * 2, opacity: 1, layerID: doc.activeLayerID)])
        }
        doc.activeFrameID = doc.frames[0].id
        return doc
    }
    static func snapshot(_ document: StudioDocument, rasters: [String: Data] = [:], audio: [AudioTrack] = []) -> Service.Snapshot {
        Service.Snapshot(document: document, retainedAudioTracks: audio, rasterDataByID: rasters)
    }
    static func parent(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    static func contents(_ url: URL) throws -> [URL] { try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
    static func rejected(_ body: () async throws -> Void, matching: (Error) -> Bool = { _ in true }) async throws {
        do { try await body() } catch { try require(matching(error), "Wrong explicit error: \(error)"); return }
        throw Failure(message: "Expected explicit export rejection")
    }
    static func decode(_ url: URL) async throws -> Decoded {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "Expected one video stream")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(audio.isEmpty, "Unexpected audio stream")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try require(reader.startReading(), "Actual AVAssetReader did not start")
        var frames: [Raster] = [], pts: [CMTime] = [], durations: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Encoded frame did not decode") }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "Decoded buffer has no bytes") }
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            var rgba = [UInt8](); rgba.reserveCapacity(width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let start = y * row + x * 4
                rgba += [bytes[start + 2], bytes[start + 1], bytes[start], 255]
            } }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            frames.append(Raster(width: width, height: height, bytes: rgba))
            pts.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        try require(reader.status == .completed, "Actual movie decode was incomplete")
        // Apple decompression may return an invalid duration. Read real encoded
        // timing separately; do not infer a passing duration from the fixture.
        let timingReader = try AVAssetReader(asset: asset)
        let timing = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        timingReader.add(timing); try require(timingReader.startReading(), "Encoded timing reader did not start")
        while let sample = timing.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { durations.append(CMSampleBufferGetDuration(sample)) }
        }
        try require(timingReader.status == .completed && durations.count == frames.count, "Encoded timing does not match decoded picture count")
        return Decoded(frames: frames, pts: pts, durations: durations, duration: try await asset.load(.duration))
    }
    static func png(_ image: CGImage, type: UTType = .png, count: Int = 1) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, count, nil) else { throw Failure(message: "Fixture image writer unavailable") }
        for _ in 0..<count { CGImageDestinationAddImage(destination, image, nil) }
        try require(CGImageDestinationFinalize(destination), "Fixture PNG could not finalize")
        return data as Data
    }
    static func fixtureImage() throws -> CGImage {
        var bytes = [UInt8]()
        for y in 0..<32 { for x in 0..<64 {
            bytes += y < 16 ? (x < 32 ? [255, 0, 0, 255] : [0, 0, 255, 255]) : (x < 32 ? [255, 255, 0, 255] : [0, 255, 0, 255])
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func readPNG(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Actual reference PNG unavailable") }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure(message: "PNG decode context failed") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Raster(width: image.width, height: image.height, bytes: bytes)
    }
    static func pixel(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 12) throws {
        try require(zip(actual, expected).allSatisfy { abs(Int($0.0) - Int($0.1)) <= tolerance }, "Movie RGBA \(actual), expected \(expected)")
    }
    static func matchesPNG(_ movie: Raster, _ png: Raster) throws {
        try require(movie.width == png.width && movie.height == png.height, "Movie rescaled/cropped the PNG compositor")
        var error = 0, large = 0, colored = 0
        for index in stride(from: 0, to: png.bytes.count, by: 4) {
            let difference = (0..<3).map { abs(Int(movie.bytes[index + $0]) - Int(png.bytes[index + $0])) }
            error += difference.reduce(0, +)
            if difference.max()! > 48 { large += 1 }
            if movie.bytes[index] < 230 || movie.bytes[index + 1] < 230 || movie.bytes[index + 2] < 230 { colored += 1 }
        }
        let pixels = png.width * png.height
        try require(Double(error) / Double(pixels * 3) < 13 && Double(large) / Double(pixels) < 0.12, "Encoded pixels diverge from actual PNG rendering (MAE \(Double(error) / Double(pixels * 3)), large \(large))")
        try require(colored > 12, "Movie fixture became blank")
    }
    final class WeakBox<T: AnyObject> { weak var value: T?; init(_ value: T?) { self.value = value } }
    typealias Session = StudioMovieExportSession
    static let visible = Session.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    static func editor(_ folder: URL, name: String = "Movie session", width: Int = 64, height: Int = 32) async throws -> StudioViewModel {
        let vm = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: folder.appendingPathComponent("documents")))
        let created = await vm.createProject(name: name, width: width, height: height, fps: 24)
        try require(created, "Actual production VM could not create its project")
        return vm
    }
    static func drawRed(_ vm: StudioViewModel) throws {
        try require(vm.commitElement(DrawnElement(id: UUID().uuidString, tool: .brush,
            points: [.init(x: 0, y: 16), .init(x: 64, y: 16)], color: "#FF0000", width: 64,
            opacity: 1, layerID: vm.activeLayerID)), "Actual red drawing command failed")
    }
    static func idle(_ session: Session) async throws {
        let deadline = Date().addingTimeInterval(15)
        while session.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try require(!session.isRunning, "Session exceeded bounded completion wait")
    }
    static func ready(_ folder: URL) async throws -> (StudioViewModel, Session, URL) {
        let vm = try await editor(folder); try drawRed(vm)
        let outputParent = try parent(folder, "output")
        let session = Session(outputParent: outputParent)
        try require(session.start(from: vm, background: .white, scope: visible), "Export did not start")
        try await idle(session)
        try require(session.output != nil && session.errorMessage == nil, "Real MP4 did not become ready: \(session.errorMessage ?? "nil")")
        return (vm, session, outputParent)
    }
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-movie-session-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("actual VM snapshot exports decoded red pixels while later edits stay independent") {
            let folder = try parent(root, "snapshot"); let vm = try await editor(folder); try drawRed(vm)
            let before = vm.document; let outputParent = try parent(folder, "output")
            let session = Session(outputParent: outputParent); var rendered: [Int] = []
            let listener = session.$completedFrames.dropFirst().removeDuplicates().sink { if $0 > 0 { rendered.append($0) } }
            try require(session.start(from: vm, background: .white, scope: visible), "Actual snapshot export refused")
            vm.addLayer()
            try require(vm.commitElement(DrawnElement(id: UUID().uuidString, tool: .brush,
                points: [.init(x: 0, y: 16), .init(x: 64, y: 16)], color: "#0000FF", width: 64,
                opacity: 1, layerID: vm.activeLayerID)), "Later blue drawing failed")
            try await idle(session); listener.cancel()
            guard let output = session.output else { throw Failure(message: session.errorMessage ?? "No actual output") }
            let movie = try await decode(output.movieURL); try pixel(movie.frames[0].pixel(32, 16), [255,0,0,255])
            try require(output.manifest.documentRevision == before.revision && vm.document.revision > before.revision,
                        "Snapshot silently followed later edits")
            try require(session.source?.projectID == before.id && session.source?.revision == before.revision && rendered == [1], "Progress or captured identity is invented")
            try require(session.notice?.contains("MP4 ready on this device") == true && session.errorMessage == nil, "Actual ready receipt missing")
            session.close(); try require(contents(outputParent).isEmpty, "Closed ready export leaked owned files")
        }
        await test("managed original raster survives production import save reopen and session MP4 capture") {
            let folder = try parent(root, "managed-raster"); let source = folder.appendingPathComponent("original.png")
            let original = try png(fixtureImage()); try original.write(to: source, options: .withoutOverwriting)
            let imported = try await StudioImageImportService().importImage(from: source, scratchParent: folder)
            let store = DeviceStorageManager(documentsDirectory: folder.appendingPathComponent("documents")); let vm = StudioViewModel(storage: store)
            let created = await vm.createProject(name: "Real image", width: 160, height: 160, fps: 7); try require(created, "Actual project creation failed")
            let id = try vm.attachImportedImage(imported, expectedProjectID: vm.document.id, expectedRevision: vm.document.revision,
                frameID: vm.currentFrame.id, layerID: vm.activeLayerID)
            vm.duplicateFrame(); let saved = await vm.save(); try require(saved, "Actual managed image save failed")
            let stored = try store.loadAnimation(id: vm.document.id)!; let reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(stored.metadata); try require(opened, "Actual managed image reopen failed")
            let outputParent = try parent(folder, "output"); let session = Session(outputParent: outputParent)
            try require(session.start(from: reopened, background: .white, scope: visible), "Managed image export did not start")
            try await idle(session); guard let output = session.output else { throw Failure(message: session.errorMessage ?? "No managed output") }
            let result = try await decode(output.movieURL); try require(result.frames.count == 2, "Managed raster frame order lost")
            for frame in result.frames {
                try pixel(frame.pixel(20,20), [255,255,255,255]); try pixel(frame.pixel(40,60), [255,0,0,255])
                try pixel(frame.pixel(120,60), [0,0,255,255]); try pixel(frame.pixel(40,100), [255,255,0,255]); try pixel(frame.pixel(120,100), [0,255,0,255])
            }
            try require(reopened.originalImageSource(id)?.originalData == original && Data(contentsOf: source) == original, "Session changed original bytes")
            session.close()
        }
        await test("active and rejected drawings are surfaced instead of silently omitted") {
            let folder = try parent(root, "pending-input"); let vm = try await editor(folder); let outputParent = try parent(folder, "output")
            let session = Session(outputParent: outputParent); try require(vm.beginStrokeInput(id: "input"), "Real input guard did not start")
            try require(!session.start(from: vm, background: .white, scope: visible), "Ongoing drawing silently omitted")
            vm.finishStrokeInput(id: "input")
            vm.retainRejectedBrush(DrawnElement(id: "pending", tool: .brush, points: [.init(x: 2,y: 2)], color: "#FF0000", width: 2, opacity: 1, layerID: vm.activeLayerID), frameID: vm.currentFrame.id, reason: "Actual pending draft")
            try require(!session.start(from: vm, background: .white, scope: visible) && vm.pendingBrushStroke != nil && contents(outputParent).isEmpty, "Rejected draft was dropped")
        }
        await test("unavailable scope and released VM never produce files or a false ready receipt") {
            let folder = try parent(root, "scope-weak"); var vm: StudioViewModel? = try await editor(folder); let weakVM = WeakBox(vm)
            let outputParent = try parent(folder, "output"); let session = Session(outputParent: outputParent)
            try require(!session.start(from: vm!, background: .white, scope: .init(isStudioVisible: false, isForeground: true, accountID: nil)), "Invisible Studio exported")
            try require(session.start(from: vm!, background: .white, scope: visible), "Visible export failed to start")
            vm = nil; try require(weakVM.value == nil, "Export task retained the actual editor")
            try await idle(session); try require(session.output == nil && contents(outputParent).isEmpty && session.notice == "MP4 export cancelled.", "Released editor yielded export success")
        }
        await test("foreground or account loss cancels pending work without new sharing") {
            for loseAccount in [false,true] {
                let folder = try parent(root, "context-\(loseAccount)"); let vm = try await editor(folder); let outputParent = try parent(folder, "output")
                let session = Session(outputParent: outputParent); try require(session.start(from: vm, background: .white, scope: visible), "Context test did not start")
                session.refreshScope(.init(isStudioVisible: true, isForeground: loseAccount, accountID: loseAccount ? "another-account" : nil))
                try await idle(session)
                try require(session.output == nil && contents(outputParent).isEmpty && session.beginSharing(scope: visible) == nil, "Lost context made a shareable output")
            }
        }
        await test("scope and close changes during prior-output cleanup cannot start another export") {
            for closes in [false,true] {
                let folder = try parent(root, "cleanup-scope-\(closes)"); let (vm,session,outputParent) = try await ready(folder)
                var observed = 0; var reentrantStart = false
                let listener = session.$output.dropFirst().sink { output in
                    if output == nil {
                        observed += 1
                        reentrantStart = session.start(from: vm, background: .white, scope: visible)
                        if closes { session.close() }
                        else { session.refreshScope(.init(isStudioVisible: true, isForeground: false, accountID: nil)) }
                    }
                }
                try require(!session.start(from: vm, background: .white, scope: visible), "Cleanup scope change was overwritten")
                listener.cancel()
                try require(observed == 1 && !reentrantStart && !session.isRunning && session.output == nil && contents(outputParent).isEmpty,
                            "Cleanup reentered or stale scope started an export")
                try require(session.errorMessage?.contains("Studio changed") == true, "Changed snapshot scope was not surfaced")
                session.close()
            }
        }
        await test("real progress cancellation and close remove partial files before becoming idle") {
            for close in [false,true] {
                let folder = try parent(root, "cancel-\(close)"); let vm = try await editor(folder); try drawRed(vm); vm.addFrame()
                let outputParent = try parent(folder, "output"); let session = Session(outputParent: outputParent)
                let listener = session.$completedFrames.dropFirst().sink { if $0 == 1 { if close { session.close() } else { session.cancel() } } }
                try require(session.start(from: vm, background: .white, scope: visible), "Cancel test did not start")
                try await idle(session); listener.cancel()
                try require(session.completedFrames == 1 && session.output == nil && contents(outputParent).isEmpty, "Actual progress cancellation leaked files")
                try require(session.errorMessage == nil && session.notice == "MP4 export cancelled.", "Cancellation became invented success/error")
            }
        }
        await test("transparent and canonical audio projects report real unsupported errors before output") {
            for audio in [false,true] {
                let folder = try parent(root, "unsupported-\(audio)"); let vm = try await editor(folder)
                if audio { vm.audioClips = [AudioClip(id: "audio", soundName: "Unsupplied clip", track: 1, startTime: 0, duration: 1)] }
                let outputParent = try parent(folder, "output"); let session = Session(outputParent: outputParent)
                try require(session.start(from: vm, background: audio ? .white : .transparent, scope: visible), "Unsupported test did not reach actual exporter")
                try await idle(session)
                try require(session.output == nil && session.notice == nil && contents(outputParent).isEmpty, "Unsupported project produced output/success")
                try require(session.errorMessage?.contains(audio ? "contains audio" : "transparency") == true, "Actual unsupported error lost")
            }
        }
        await test("retained legacy audio without canonical clips cannot be silently dropped") {
            let folder = try parent(root, "legacy-audio"); let docs = folder.appendingPathComponent("documents"); let store = DeviceStorageManager(documentsDirectory: docs)
            let vm = StudioViewModel(storage: store); let created = await vm.createProject(name: "Opaque history", width: 64, height: 32, fps: 24); try require(created, "Legacy fixture create failed")
            var project = try store.loadAnimation(id: vm.document.id)!
            project.audioTracks.append(AudioTrack(id: UUID(), name: "Retained legacy", format: "wav", audioData: Data([1]), startTime: 0, duration: 1))
            try store.saveAnimation(project)
            let reopened = StudioViewModel(storage: store); let opened = await reopened.openProject(project.metadata); try require(opened, "Legacy audio fixture did not reopen")
            try require(reopened.document.audioClips.isEmpty && reopened.projectAudioTracks.count == 1, "Fixture does not isolate retained audio")
            let outputParent = try parent(folder, "output"); let session = Session(outputParent: outputParent)
            try require(session.start(from: reopened, background: .white, scope: visible), "Legacy test did not start")
            try await idle(session); try require(session.output == nil && session.errorMessage?.contains("contains audio") == true && contents(outputParent).isEmpty, "Legacy audio became silent MP4")
        }
        await test("share request retains real decoded files through panel close and session release") {
            let folder = try parent(root, "share-lifetime"); var tuple: (StudioViewModel, Session, URL)? = try await ready(folder)
            let vm = tuple!.0; var session: Session? = tuple!.1; let outputParent = tuple!.2
            tuple = nil
            let urls = try session!.output!.checkedURLs()
            let weakSession = WeakBox(session)
            guard let request = session!.beginSharing(scope: visible) else { throw Failure(message: "Real share request unavailable") }
            session!.close(); session = nil
            try require(weakSession.value != nil && request.checkedURLs() == urls && urls.allSatisfy { fm.fileExists(atPath: $0.path) }, "Close/release removed active share files")
            let result = try await decode(urls[0]); try require(result.frames.count == 1 && vm.isEditing, "Share request lost actual movie")
            request.finish(completed: false, error: nil)
            try require(contents(outputParent).isEmpty && weakSession.value == nil, "Finished closed share did not clean owned files")
            try await rejected { _ = try request.checkedURLs() }
        }
        await test("share results are factual and duplicate old callbacks cannot finish a new share") {
            let folder = try parent(root, "share-tokens"); let (vm,session,_) = try await ready(folder)
            guard let first = session.beginSharing(scope: visible) else { throw Failure(message: "First share failed") }
            first.finish(completed: false, error: nil)
            try require(session.notice?.hasPrefix("Sharing cancelled") == true && session.output != nil, "Cancellation claimed publication")
            guard let second = session.beginSharing(scope: visible) else { throw Failure(message: "Second share failed") }
            first.finish(completed: true, error: nil)
            try require(session.isSharing && second.checkedURLs().count == 2, "Old callback consumed new request")
            second.finish(completed: true, error: nil)
            try require(session.notice == "The share sheet reported completion." && vm.isEditing, "Callback claimed a remote upload/link")
            guard let failed = session.beginSharing(scope: visible) else { throw Failure(message: "Failure share failed") }
            failed.finish(completed: false, error: NSError(domain: "ActualConsumer", code: 1, userInfo: [NSLocalizedDescriptionKey:"Destination rejected the file"]))
            try require(session.errorMessage == "Destination rejected the file" && session.output != nil, "Actual consumer error lost export")
            session.close()
        }
        await test("abandoned share request releases sharing state without inventing completion") {
            let folder = try parent(root, "abandoned-share"); let (vm,session,_) = try await ready(folder)
            var request = session.beginSharing(scope: visible); try require(request != nil && session.isSharing, "No share request")
            request = nil; let deadline = Date().addingTimeInterval(3)
            while session.isSharing && Date() < deadline { await Task.yield() }
            try require(!session.isSharing && session.notice?.hasPrefix("Sharing cancelled") == true && session.output != nil && vm.isEditing, "Abandoned consumer retained sharing or claimed completion")
            session.close()
        }
        await test("checked handoff rejects mutation and safe cleanup retries only after identity restoration") {
            let folder = try parent(root, "cleanup-retry"); let (vm,session,outputParent) = try await ready(folder)
            let output = session.output!; let moved = folder.appendingPathComponent("actual-original.mp4")
            try fm.moveItem(at: output.movieURL, to: moved); let foreign = Data("Foreign replacement".utf8); try foreign.write(to: output.movieURL)
            try require(session.beginSharing(scope: visible) == nil && session.needsCleanup, "Changed output was handed to a consumer")
            try require(!session.retryCleanup() && !session.start(from: vm, background: .white, scope: visible), "Unknown replacement was deleted or export bypassed cleanup")
            try require(Data(contentsOf: output.movieURL) == foreign && fm.fileExists(atPath: output.manifestURL.path), "Cleanup deleted foreign or another output")
            try fm.removeItem(at: output.movieURL); try fm.moveItem(at: moved, to: output.movieURL)
            try require(session.retryCleanup() && session.output == nil && session.errorMessage == nil && contents(outputParent).isEmpty, "Restored owned cleanup did not recover")
            try require(session.start(from: vm, background: .white, scope: visible), "Safe cleanup did not permit a new export")
            try await idle(session); try require(session.output != nil, "Retry never rendered a real file"); session.close()
        }
        await test("pre-return unknown partial is preserved and cannot be deleted through retry by URL") {
            let folder = try parent(root, "partial-recovery"); let vm = try await editor(folder); let outputParent = try parent(folder, "output")
            let session = Session(outputParent: outputParent); var foreign: URL?; var fixtureError: Error?
            let listener = session.$phase.sink { phase in
                if phase == .publishing {
                    do {
                        let staging = try contents(outputParent).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let file = staging.appendingPathComponent("foreign.txt"); try Data("Keep private owner data".utf8).write(to: file); foreign = file
                        session.cancel()
                    } catch { fixtureError = error }
                }
            }
            try require(session.start(from: vm, background: .white, scope: visible), "Partial test did not start")
            try await idle(session); listener.cancel()
            try require(fixtureError == nil && foreign != nil && session.needsCleanup && session.output == nil, "Actual partial conflict fixture failed")
            try require(!session.retryCleanup() && !session.start(from: vm, background: .white, scope: visible) && Data(contentsOf: foreign!) == Data("Keep private owner data".utf8), "Session adopted a failed partial URL")
            // The test owns its generated tree. Simulate an external owner
            // resolving it; the session itself must perform only read-only checks.
            try fm.removeItem(at: foreign!.deletingLastPathComponent())
            try require(session.retryCleanup() && !session.needsCleanup, "Resolved partial did not unblock recovery")
            try require(session.start(from: vm, background: .white, scope: visible), "Resolved partial blocked later export")
            try await idle(session); try require(session.output != nil, "Recovery did not produce actual output"); session.close()
        }
        print("STUDIO_MOVIE_SESSION_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        if failed != 0 { exit(1) }
    }
}
