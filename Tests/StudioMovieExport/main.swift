import AppKit
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

@main @MainActor struct StudioMovieExportTests {
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
    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-movie-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("real H.264 frames dimensions exact PTS full last-frame duration and owned output lifetime") {
            let folder = try parent(root, "basic"); var service: Service? = Service()
            var doc = try document(); doc.revision = 7; doc.gridEnabled = true; doc.onionEnabled = true
            let original = doc; var counts: [Int] = []
            let output = try await service!.export(snapshot: snapshot(doc), outputParent: folder, background: .white) {
                if $0.phase == .rendering { counts.append($0.completedFrames) }
                if $0.phase == .verifying, let artifacts = ProcessInfo.processInfo.environment["SDI_MOVIE_TEST_ARTIFACTS"] {
                    let target = URL(fileURLWithPath: artifacts, isDirectory: true)
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    let source = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!.appendingPathComponent("animation.mp4")
                    try fm.copyItem(at: source, to: target.appendingPathComponent("actual-three-frames-" + UUID().uuidString + ".mp4"))
                }
            }
            service = nil
            let result = try await decode(output.movieURL)
            let pngReference = try await StudioExportService().export(document: doc, format: .pngSequence, outputParent: folder)
            for i in pngReference.imageURLs.indices { print("SOLID_REFERENCE", i, try readPNG(pngReference.imageURLs[i]).pixel(32, 16), "MOVIE", result.frames[i].pixel(32, 16)) }
            try require(result.frames.count == 3 && counts == [1, 2, 3] && doc == original, "Input changed or frames/progress lost")
            for (index, expected) in [[UInt8](arrayLiteral: 255, 0, 0, 255), [0, 0, 255, 255], [0, 255, 0, 255]].enumerated() {
                try require(result.frames[index].width == 64 && result.frames[index].height == 32, "Wrong actual MP4 dimensions")
                try pixel(result.frames[index].pixel(32, 16), expected)
                try require(CMTimeCompare(result.pts[index], CMTime(value: Int64(index), timescale: 24)) == 0, "Frame PTS changed")
                try require(CMTimeCompare(result.durations[index], CMTime(value: 1, timescale: 24)) == 0, "Frame duration changed")
            }
            try require(CMTimeCompare(result.duration, CMTime(value: 3, timescale: 24)) == 0, "Last frame duration was lost")
            let manifest = try JSONDecoder().decode(Service.Manifest.self, from: Data(contentsOf: output.manifestURL))
            try require(manifest.frameIDs == doc.frames.map(\.id) && manifest.projectID == doc.id && manifest.documentRevision == 7 && manifest.fps == 24, "Manifest lost canonical identity/timing")
            try require(!manifest.audioIncluded && !manifest.editorGuidesIncluded && manifest.encodedBytes == Data(contentsOf: output.movieURL).count, "Manifest claimed unavailable work")
        }
        await test("one frame and nondivisor FPS retain exact complete duration without duplicate frames") {
            let folder = try parent(root, "timing")
            for fps in [1, 7, 30, 60] {
                let doc = try document(colors: ["#FF0000"], fps: fps)
                let output = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
                let decoded = try await decode(output.movieURL)
                try require(decoded.frames.count == 1 && CMTimeCompare(decoded.duration, CMTime(value: 1, timescale: CMTimeScale(fps))) == 0, "One frame was lost, duplicated or mistimed at \(fps) FPS")
            }
        }
        await test("immutable original raster orientation and real white PNG compositor survive video encoding") {
            let folder = try parent(root, "raster"); var doc = try document(colors: ["#FF0000"])
            doc.frames[0].elements = []; doc.frames[0].rasterAssetID = "original"; doc.frames[0].rasterLayerID = doc.activeLayerID
            let data = try png(fixtureImage()); let original = data
            let output = try await Service().export(snapshot: snapshot(doc, rasters: ["original": data]), outputParent: folder, background: .white)
            let movie = try await decode(output.movieURL).frames[0]
            let reference = try await StudioExportService().export(document: doc, format: .pngSequence, outputParent: folder, rasterData: { _ in data })
            try matchesPNG(movie, readPNG(reference.imageURLs[0]))
            try pixel(movie.pixel(16, 8), [255, 0, 0, 255]); try pixel(movie.pixel(48, 8), [0, 0, 255, 255])
            try pixel(movie.pixel(16, 24), [255, 255, 0, 255]); try pixel(movie.pixel(48, 24), [0, 255, 0, 255])
            try require(data == original, "Original raster bytes changed")
        }
        await test("canonical layer order opacity visibility eraser blend and glow match actual PNG outputs") {
            let folder = try parent(root, "layers"); var doc = try document(colors: ["#FF0000"], height: 64)
            var top = CanvasLayer(id: "top", name: "Top"); top.opacity = 0.5; top.glowEnabled = true; top.glowColor = "#0000FF"
            doc.layers.insert(top, at: 0)
            doc.frames[0].elements.append(DrawnElement(id: "top-stroke", tool: .brush, points: [StrokePoint(x: 8, y: 32), StrokePoint(x: 56, y: 32)], color: "#0000FF", width: 16, opacity: 1, layerID: top.id))
            doc.frames[0].elements.append(DrawnElement(id: "eraser", tool: .eraser, points: [StrokePoint(x: 8, y: 32), StrokePoint(x: 56, y: 32)], color: "#FFFFFF", width: 6, opacity: 1, layerID: top.id))
            for blend in ["normal", "multiply", "screen", "overlay", "darken", "lighten"] {
                doc.layers[0].blendMode = blend
                let movie = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
                let reference = try await StudioExportService().export(document: doc, format: .pngSequence, outputParent: folder)
                let pixels = try await decode(movie.movieURL).frames[0]
                try matchesPNG(pixels, readPNG(reference.imageURLs[0]))
            }
            doc.layers[0].visible = false
            let hidden = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
            let pixels = try await decode(hidden.movieURL).frames[0]
            try pixel(pixels.pixel(32, 32), [255, 0, 0, 255])
        }
        await test("all schema2 seeded brush families pressure smoothing and texture use actual shared renderer") {
            let folder = try parent(root, "brushes"); var doc = try document(colors: ["#FF0000"], height: 64)
            doc.schemaVersion = 2
            doc.frames = StudioBrushFamily.allCases.enumerated().map { index, family in
                AnimationFrame(id: "brush-frame-\(index)", elements: [DrawnElement(id: "brush-\(index)", tool: .brush,
                    points: [StrokePoint(x: 8, y: 10, pressure: 0.3, timestamp: 0), StrokePoint(x: 32, y: 50, pressure: 0.8, timestamp: 0.2), StrokePoint(x: 56, y: 16, pressure: 1, timestamp: 0.4)],
                    color: "#FF0000", width: 12, opacity: 0.85, layerID: doc.activeLayerID,
                    brush: StudioBrushDescriptor(family: family, seed: 71, smoothing: 2, gradientEndColor: family == .gradient ? StudioBrushColor(red: 0, green: 0, blue: 1) : nil))])
            }
            doc.activeFrameID = doc.frames[0].id
            let original = doc
            let movie = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
            let reference = try await StudioExportService().export(document: doc, format: .pngSequence, outputParent: folder)
            let decoded = try await decode(movie.movieURL)
            try require(decoded.frames.count == StudioBrushFamily.allCases.count && doc == original, "Brush frames or editable settings changed")
            for index in decoded.frames.indices { try matchesPNG(decoded.frames[index], readPNG(reference.imageURLs[index])) }
        }
        await test("captured document and raster values stay immutable while caller continues editing") {
            let folder = try parent(root, "snapshot")
            var doc = try document(); doc.frames = [doc.frames[0]]; doc.activeFrameID = doc.frames[0].id
            doc.frames[0].elements = []; doc.frames[0].rasterAssetID = "original"; doc.frames[0].rasterLayerID = doc.activeLayerID
            var data = try png(fixtureImage())
            let captured = snapshot(doc, rasters: ["original": data])
            let output = try await Service().export(snapshot: captured, outputParent: folder, background: .white) { state in
                if state.phase == .rendering {
                    doc.name = "Caller edited"; doc.frames[0].rasterAssetID = nil
                    data.removeAll()
                }
            }
            let movie = try await decode(output.movieURL)
            try pixel(movie.frames[0].pixel(16, 8), [255, 0, 0, 255])
            try pixel(movie.frames[0].pixel(48, 24), [0, 255, 0, 255])
            try require(captured.document.name == "Actual movie fixture" && captured.rasterDataByID["original"]!.count > 0 && data.isEmpty && doc.name == "Caller edited", "Captured input changed with caller storage")
        }
        await test("explicit white background produces an opaque white decoded empty frame") {
            let folder = try parent(root, "white")
            var doc = try document(colors: ["#FF0000"]); doc.frames[0].elements = []
            let output = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
            let result = try await decode(output.movieURL)
            try pixel(result.frames[0].pixel(0, 0), [255, 255, 255, 255])
            try pixel(result.frames[0].pixel(32, 16), [255, 255, 255, 255])
        }
        await test("audio clips including muted and opaque retained historical tracks reject before writing") {
            let folder = try parent(root, "audio"); var doc = try document()
            doc.audioClips = [AudioClip(id: "muted", soundName: "Retained", track: 1, startTime: 0, duration: 1, volume: 0)]
            try await tryAudioRejection(snapshot(doc), folder: folder)
            doc.audioClips = []
            let legacy = AudioTrack(id: UUID(), name: "Legacy", format: "wav", audioData: Data([1]), startTime: 0, duration: 1)
            try await tryAudioRejection(snapshot(doc, audio: [legacy]), folder: folder)
            try require(contents(folder).isEmpty, "Audio rejection wrote output")
        }
        await test("transparent odd dimensions and unsupported visible content never silently flatten or resize") {
            let folder = try parent(root, "unsupported"); let doc = try document()
            try await rejected { _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .transparent) }
            let odd = try document(width: 65)
            try await rejected { _ = try await Service().export(snapshot: snapshot(odd), outputParent: folder, background: .white) }
            var invalid = doc; invalid.frames[0].elements[0].tool = .smudge
            try await rejected { _ = try await Service().export(snapshot: snapshot(invalid), outputParent: folder, background: .white) }
            invalid = doc; invalid.layers[0].blendMode = "unknown"
            try await rejected { _ = try await Service().export(snapshot: snapshot(invalid), outputParent: folder, background: .white) }
            try require(contents(folder).isEmpty, "Unsupported output was published")
        }
        await test("missing corrupt truncated and multi-image raster references fail even on hidden layers") {
            let folder = try parent(root, "bad-raster"); var doc = try document()
            doc.frames[0].rasterAssetID = "asset"; doc.frames[0].rasterLayerID = doc.activeLayerID; doc.layers[0].visible = false
            for data in [nil, Data([0, 1, 2]), try png(fixtureImage()).prefix(24), try png(fixtureImage(), type: .gif, count: 2)] as [Data?] {
                let bytes = data.map { ["asset": $0] } ?? [:]
                try await rejected { _ = try await Service().export(snapshot: snapshot(doc, rasters: bytes), outputParent: folder, background: .white) }
            }
            try require(contents(folder).isEmpty, "Missing hidden original silently exported")
        }
        await test("frame pixels aggregate pixels and immutable encoded raster budgets fail before output") {
            let folder = try parent(root, "limits"); let doc = try document()
            for limits in [Service.Limits(maximumFrames: 2), Service.Limits(maximumFramePixels: 2047), Service.Limits(maximumTotalPixels: 6143), Service.Limits(maximumRasterBytes: 2)] {
                try await rejected { _ = try await Service(limits: limits).export(snapshot: snapshot(doc, rasters: ["unused": Data([1, 2, 3])]), outputParent: folder, background: .white) }
            }
            try require(contents(folder).isEmpty, "Preflight budget left partial output")
        }
        await test("cancellation before work and after real encoded frame removes only owned partial output") {
            let folder = try parent(root, "cancel"); let sentinel = folder.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: sentinel); let doc = try document()
            let before = Task { () throws -> Service.Output in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
            }
            try await rejected({ _ = try await before.value }, matching: { $0 is CancellationError })
            let during = Task {
                try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) {
                    if $0.phase == .rendering && $0.completedFrames == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            try await rejected({ _ = try await during.value }, matching: { $0 is CancellationError })
            try require(contents(folder).map(\.lastPathComponent) == ["keep.txt"] && Data(contentsOf: sentinel) == Data("keep".utf8), "Cancellation touched unrelated output")
        }
        await test("cancel at actual finalization checkpoint cleans output and releases movie lease") {
            let folder = try parent(root, "cancel-finish"); let doc = try document()
            let task = Task {
                try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) {
                    if $0.phase == .finalizing { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            try await rejected({ _ = try await task.value }, matching: { $0 is CancellationError })
            try require(contents(folder).isEmpty, "Finalization cancellation leaked output")
            _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
        }
        await test("process-wide movie capacity rejects a second actual encoder without corrupting first") {
            let folder = try parent(root, "capacity"); let doc = try document(); var duplicate: Task<Service.Output, Error>?
            _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) {
                if $0.phase == .rendering && duplicate == nil {
                    duplicate = Task { try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) }
                }
            }
            try require(duplicate != nil, "Concurrent attempt did not run")
            try await rejected({ _ = try await duplicate!.value }, matching: { if case Service.ExportError.alreadyExporting = $0 { return true }; return false })
            try require(contents(folder).count == 1, "Capacity failure changed first output")
        }
        await test("encoded output byte cap and progress failure remove partials without false success") {
            let folder = try parent(root, "output-limit"); let doc = try document()
            try await rejected({ _ = try await Service(limits: Service.Limits(maximumOutputBytes: 128)).export(snapshot: snapshot(doc), outputParent: folder, background: .white) }, matching: { if case Service.ExportError.limitExceeded = $0 { return true }; return false })
            try await rejected { _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { _ in throw Failure(message: "Caller stopped work") } }
            try require(contents(folder).isEmpty, "Bound/failure leaked output")
        }
        await test("real finalized MP4 corruption is detected by production decoder before publication") {
            let folder = try parent(root, "corrupt-output"); let doc = try document(); var sabotaged = false
            try await rejected {
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    if state.phase == .verifying {
                        let partial = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let file = try FileHandle(forWritingTo: partial.appendingPathComponent("animation.mp4"))
                        try file.truncate(atOffset: 20); try file.close(); sabotaged = true
                    }
                }
            }
            try require(sabotaged && contents(folder).isEmpty, "Corrupt finalized movie was accepted or leaked")
        }
        await test("publication collision preserves existing bytes and cleans only owned staging") {
            let folder = try parent(root, "collision"); let doc = try document(); var collision: URL?
            try await rejected {
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    if state.phase == .publishing {
                        let partial = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let id = partial.lastPathComponent.dropFirst(".sdi-movie-".count).dropLast(".partial".count)
                        let target = folder.appendingPathComponent("SDI-Movie-" + doc.id.uuidString + "-" + id)
                        try Data("existing".utf8).write(to: target); collision = target
                    }
                }
            }
            try require(collision != nil && contents(folder).count == 1 && Data(contentsOf: collision!) == Data("existing".utf8), "Collision overwritten or unrelated file cleaned")
        }
        await test("a changed already-verified movie cannot be published by a progress callback") {
            let folder = try parent(root, "changed-after-verification"); let doc = try document()
            try await rejected {
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    if state.phase == .publishing {
                        let partial = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let movie = partial.appendingPathComponent("animation.mp4")
                        let handle = try FileHandle(forWritingTo: movie)
                        try handle.seek(toOffset: 16); try handle.write(contentsOf: Data([0x73, 0x64, 0x69])); try handle.close()
                    }
                }
            }
            try require(contents(folder).isEmpty, "Changed verified movie was published")
        }
        await test("deadline on finalization and symlink destination reject without following foreign paths") {
            let folder = try parent(root, "deadline"); let doc = try document()
            try await rejected({ _ = try await Service(limits: Service.Limits(operationTimeout: 1)).export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                if state.phase == .finalizing { Thread.sleep(forTimeInterval: 1.01) }
            } }, matching: { if case Service.ExportError.timedOut = $0 { return true }; return false })
            try require(contents(folder).isEmpty, "Deadline output leaked")
            let link = root.appendingPathComponent("link"); try fm.createSymbolicLink(at: link, withDestinationURL: folder)
            try await rejected { _ = try await Service().export(snapshot: snapshot(doc), outputParent: link, background: .white) }
            try require(contents(folder).isEmpty, "Symlink destination was followed")
        }
        await test("replaced staging identity preserves foreign contents and moved original movie") {
            let folder = try parent(root, "staging-replaced"); let doc = try document()
            let preserved = folder.appendingPathComponent("owned-original-preserved", isDirectory: true)
            var foreign: URL?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    if state.phase == .publishing {
                        let partial = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        try fm.moveItem(at: partial, to: preserved)
                        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
                        let sentinel = partial.appendingPathComponent("foreign.txt")
                        try Data("foreign content".utf8).write(to: sentinel); foreign = sentinel
                        throw Failure(message: "Caller failed after replacing staging path")
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(foreign != nil && Data(contentsOf: foreign!) == Data("foreign content".utf8), "Replacement directory was recursively deleted")
            let decoded = try await decode(preserved.appendingPathComponent("animation.mp4"))
            try require(decoded.frames.count == doc.frames.count, "Moved original movie was deleted or damaged")
        }
        await test("replaced parent identity prevents publication and preserves both directory trees") {
            let folder = try parent(root, "parent-replaced"); let doc = try document()
            let preserved = root.appendingPathComponent("original-parent-preserved", isDirectory: true)
            var sentinel: URL?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    if state.phase == .publishing {
                        let basename = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!.lastPathComponent
                        try fm.moveItem(at: folder, to: preserved)
                        let replacement = folder.appendingPathComponent(basename, isDirectory: true)
                        try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
                        let file = replacement.appendingPathComponent("foreign.txt")
                        try Data("foreign parent".utf8).write(to: file); sentinel = file
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(sentinel != nil && Data(contentsOf: sentinel!) == Data("foreign parent".utf8), "Replacement parent contents were removed")
            let partial = try contents(preserved).first { $0.lastPathComponent.hasSuffix(".partial") }!
            let decoded = try await decode(partial.appendingPathComponent("animation.mp4"))
            try require(decoded.frames.count == doc.frames.count, "Original parent contents were damaged")
        }
        await test("lost ownership during active writing never cancels over a foreign movie path") {
            let folder = try parent(root, "active-path-replaced"); let doc = try document()
            let preserved = folder.appendingPathComponent("active-original-preserved", isDirectory: true)
            var foreign: URL?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    if state.phase == .rendering && state.completedFrames == 1 {
                        let partial = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        try fm.moveItem(at: partial, to: preserved)
                        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
                        let movie = partial.appendingPathComponent("animation.mp4")
                        try Data("foreign movie bytes".utf8).write(to: movie); foreign = movie
                        throw Failure(message: "Caller failed during active encoding")
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            await Task.yield()
            try require(foreign != nil && Data(contentsOf: foreign!) == Data("foreign movie bytes".utf8), "AVAssetWriter cancellation deleted a foreign movie")
            _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white)
            try require(Data(contentsOf: foreign!) == Data("foreign movie bytes".utf8), "Later codec release damaged foreign bytes")
        }
        await test("managed image placement uses the actual image-era VM and movie compositor") {
            let folder = try parent(root, "managed-image-movie")
            let input = folder.appendingPathComponent("asymmetric-source.png")
            let original = try png(fixtureImage())
            try original.write(to: input, options: .withoutOverwriting)
            let imported = try await StudioImageImportService().importImage(from: input, scratchParent: folder)
            let store = DeviceStorageManager(documentsDirectory: folder.appendingPathComponent("documents"))
            let vm = StudioViewModel(storage: store)
            let created = await vm.createProject(name: "Managed movie", width: 160, height: 160, fps: 7)
            try require(created, "Real managed-image project could not be created")
            let assetID = try vm.attachImportedImage(imported, expectedProjectID: vm.document.id,
                expectedRevision: vm.document.revision, frameID: vm.currentFrame.id, layerID: vm.activeLayerID)
            try require(vm.currentFrame.rasterPlacement == .init(x: 0, y: 40, width: 160, height: 80), "Image aspect fit changed before movie export")
            vm.duplicateFrame()
            let saved = await vm.save(); try require(saved, "Actual managed image project did not save")
            let stored = try store.loadAnimation(id: vm.document.id)!
            let reopened = StudioViewModel(storage: store)
            let opened = await reopened.openProject(stored.metadata); try require(opened, "Managed image did not reopen")
            let captured = snapshot(reopened.document, rasters: [assetID: reopened.rasterData(assetID)!], audio: reopened.projectAudioTracks)
            let output = try await Service().export(snapshot: captured, outputParent: folder, background: .white)
            let movie = try await decode(output.movieURL)
            try require(movie.frames.count == 2 && CMTimeCompare(movie.duration, CMTime(value: 2, timescale: 7)) == 0, "Image-era movie lost exact frame order/timing")
            for image in movie.frames {
                try pixel(image.pixel(20, 20), [255,255,255,255])
                try pixel(image.pixel(20, 140), [255,255,255,255])
                try pixel(image.pixel(40, 60), [255,0,0,255])
                try pixel(image.pixel(120, 60), [0,0,255,255])
                try pixel(image.pixel(40, 100), [255,255,0,255])
                try pixel(image.pixel(120, 100), [0,255,0,255])
            }
            try require(reopened.originalImageSource(assetID)?.originalData == original && Data(contentsOf: input) == original, "Movie changed imported original bytes")
            if let artifacts = ProcessInfo.processInfo.environment["SDI_MOVIE_TEST_ARTIFACTS"] {
                let target = URL(fileURLWithPath: artifacts, isDirectory: true)
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try fm.copyItem(at: output.movieURL, to: target.appendingPathComponent("managed-image-movie.mp4"))
            }
        }
        await test("returned verified files clean explicitly once without deleting a later path replacement") {
            let folder = try parent(root, "returned-clean")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            try require(output.checkedURLs() == [output.movieURL, output.manifestURL], "Checked handoff changed its files")
            let result = try await decode(output.movieURL)
            try require(result.frames.count == 3, "Actual returned movie no longer decodes")
            try output.cleanup(); try output.cleanup()
            try require(output.isCleaned && !fm.fileExists(atPath: output.directory.path), "Idempotent owned cleanup failed")
            try fm.createDirectory(at: output.directory, withIntermediateDirectories: false)
            let foreign = output.directory.appendingPathComponent("foreign.txt")
            try Data("later owner".utf8).write(to: foreign)
            try output.cleanup()
            try require(Data(contentsOf: foreign) == Data("later owner".utf8), "Repeated cleanup removed a new path owner")
            try await rejected({ _ = try output.checkedURLs() }, matching: { if case Service.ExportError.outputUnavailable = $0 { return true }; return false })
        }
        await test("copied output handles share cancellation state and cleanup works inside a cancelled Task") {
            let folder = try parent(root, "returned-cancel")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            let alias = output
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try alias.cancel()
            }
            try await task.value
            try require(output.isCancelled && output.isCleaned && contents(folder).isEmpty, "Cancellation did not clean the shared ownership handle")
            try await rejected { _ = try output.checkedURLs() }
            try alias.cancel(); try output.cleanup()
        }
        await test("a returned replacement movie is preserved and cleanup retries only after the original is restored") {
            let folder = try parent(root, "returned-file-replaced")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            let moved = folder.appendingPathComponent("original-movie-preserved.mp4")
            let manifest = try Data(contentsOf: output.manifestURL)
            try fm.moveItem(at: output.movieURL, to: moved)
            let foreign = Data("foreign movie".utf8); try foreign.write(to: output.movieURL)
            try await rejected({ try output.cleanup() }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(!output.isCleaned && Data(contentsOf: output.movieURL) == foreign && Data(contentsOf: output.manifestURL) == manifest, "Cleanup touched a replacement or another owned file")
            let retainedDecode = try await decode(moved)
            try require(retainedDecode.frames.count == 3, "Moved original movie was damaged")
            try await rejected { _ = try output.checkedURLs() }
            try fm.removeItem(at: output.movieURL); try fm.moveItem(at: moved, to: output.movieURL)
            try output.cleanup(); try require(contents(folder).isEmpty, "Restored original did not permit safe retry")
        }
        await test("returned file symlink or nested-directory replacements never get followed or recursively removed") {
            let folder = try parent(root, "returned-links")
            for replacementIsDirectory in [false, true] {
                let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
                let moved = folder.appendingPathComponent("original-manifest-\(replacementIsDirectory).json")
                let foreignTarget = folder.appendingPathComponent("foreign-target-\(replacementIsDirectory).txt")
                try Data("foreign target".utf8).write(to: foreignTarget)
                try fm.moveItem(at: output.manifestURL, to: moved)
                if replacementIsDirectory {
                    try fm.createDirectory(at: output.manifestURL, withIntermediateDirectories: false)
                    try Data("nested foreign".utf8).write(to: output.manifestURL.appendingPathComponent("nested.txt"))
                } else { try fm.createSymbolicLink(at: output.manifestURL, withDestinationURL: foreignTarget) }
                let movie = try Data(contentsOf: output.movieURL)
                try await rejected { try output.cleanup() }
                try require(Data(contentsOf: output.movieURL) == movie && Data(contentsOf: foreignTarget) == Data("foreign target".utf8), "Replacement cleanup touched actual content")
                if replacementIsDirectory {
                    try require(Data(contentsOf: output.manifestURL.appendingPathComponent("nested.txt")) == Data("nested foreign".utf8), "Unknown nested file removed")
                } else { try require(fm.destinationOfSymbolicLink(atPath: output.manifestURL.path) == foreignTarget.path, "Replacement symlink removed") }
                try fm.removeItem(at: output.manifestURL); try fm.moveItem(at: moved, to: output.manifestURL)
                try output.cleanup()
            }
        }
        await test("a returned directory moved or replaced preserves both trees until its original identity returns") {
            let folder = try parent(root, "returned-directory")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            let moved = folder.appendingPathComponent("original-directory-preserved", isDirectory: true)
            try fm.moveItem(at: output.directory, to: moved)
            try await rejected { try output.cleanup() }
            try fm.createDirectory(at: output.directory, withIntermediateDirectories: false)
            let foreign = output.directory.appendingPathComponent("foreign.txt")
            try Data("foreign directory".utf8).write(to: foreign)
            try await rejected { try output.cancel() }
            try require(output.isCancelled && !output.isCleaned && Data(contentsOf: foreign) == Data("foreign directory".utf8), "Cancellation removed foreign directory")
            let retainedDecode = try await decode(moved.appendingPathComponent("animation.mp4"))
            try require(retainedDecode.frames.count == 3, "Moved output damaged")
            try fm.removeItem(at: output.directory); try fm.moveItem(at: moved, to: output.directory)
            try output.cleanup(); try require(output.isCleaned, "Cancelled output cleanup could not retry after restore")
            try await rejected { _ = try output.checkedURLs() }
        }
        await test("post-return parent replacement never deletes the old tree or the replacement parent") {
            let folder = try parent(root, "returned-parent")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            let moved = root.appendingPathComponent("returned-original-parent")
            try fm.moveItem(at: folder, to: moved)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            let foreign = folder.appendingPathComponent("foreign.txt")
            try Data("foreign parent".utf8).write(to: foreign)
            try await rejected { try output.cleanup() }
            try require(Data(contentsOf: foreign) == Data("foreign parent".utf8), "Replacement parent changed")
            let preserved = moved.appendingPathComponent(output.directory.lastPathComponent)
            let retainedDecode = try await decode(preserved.appendingPathComponent("animation.mp4"))
            try require(retainedDecode.frames.count == 3, "Pinned old tree changed")
            try fm.removeItem(at: folder); try fm.moveItem(at: moved, to: folder)
            try output.cleanup(); try require(contents(folder).isEmpty, "Parent restore did not allow retry")
        }
        await test("same-inode movie and manifest mutations fail before either owned file is removed") {
            let folder = try parent(root, "returned-mutated")
            for mutateMovie in [true, false] {
                let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
                let target = mutateMovie ? output.movieURL : output.manifestURL
                let original = try Data(contentsOf: target)
                let otherURL = mutateMovie ? output.manifestURL : output.movieURL
                let other = try Data(contentsOf: otherURL)
                let file = try FileHandle(forWritingTo: target)
                try file.write(contentsOf: Data([original[0] ^ 0xff])); try file.close()
                try await rejected { _ = try output.checkedURLs() }
                try await rejected { try output.cleanup() }
                try require(Data(contentsOf: otherURL) == other && Data(contentsOf: target) != original, "Mutation caused another file deletion")
                let restore = try FileHandle(forWritingTo: target)
                try restore.write(contentsOf: original); try restore.close()
                try output.cleanup()
            }
            try require(contents(folder).isEmpty, "Restored exact bytes could not clean")
        }
        await test("unexpected returned files and nested contents keep both verified outputs intact") {
            let folder = try parent(root, "returned-extra")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            let movie = try Data(contentsOf: output.movieURL), manifest = try Data(contentsOf: output.manifestURL)
            let nested = output.directory.appendingPathComponent("unknown", isDirectory: true)
            try fm.createDirectory(at: nested, withIntermediateDirectories: false)
            let foreign = nested.appendingPathComponent("keep.txt")
            try Data("unknown nested content".utf8).write(to: foreign)
            try await rejected { try output.cleanup() }
            try require(Data(contentsOf: foreign) == Data("unknown nested content".utf8) && Data(contentsOf: output.movieURL) == movie && Data(contentsOf: output.manifestURL) == manifest, "Unexpected contents did not prevent deletion")
            try fm.removeItem(at: nested)
            try output.cleanup(); try require(contents(folder).isEmpty, "Unknown-entry removal did not enable retry")
        }
        await test("an already removed owned file allows remaining cleanup without inventing a usable handoff") {
            let folder = try parent(root, "returned-missing")
            let output = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white)
            try fm.removeItem(at: output.movieURL)
            try await rejected { _ = try output.checkedURLs() }
            try output.cleanup(); try output.cleanup()
            try require(output.isCleaned && contents(folder).isEmpty, "Missing owned file prevented remaining cleanup")
        }
        await test("unexpected contents before returned ownership capture are preserved with an explicit cleanup error") {
            let folder = try parent(root, "seal-foreign")
            var foreign: URL?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { state in
                    if state.phase == .publishing {
                        let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let file = staging.appendingPathComponent("foreign.txt")
                        try Data("before publication".utf8).write(to: file); foreign = file
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(foreign != nil && Data(contentsOf: foreign!) == Data("before publication".utf8), "Ownership capture recursively removed an unknown entry")
            let staging = foreign!.deletingLastPathComponent()
            let retainedDecode = try await decode(staging.appendingPathComponent("animation.mp4"))
            try require(retainedDecode.frames.count == 3, "Ownership refusal damaged verified movie")
        }
        await test("publishing callback failure preserves an unknown staged file") {
            let folder = try parent(root, "publishing-failure-foreign")
            var foreign: URL?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { state in
                    if state.phase == .publishing {
                        let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let file = staging.appendingPathComponent("foreign.txt")
                        try Data("before publication".utf8).write(to: file); foreign = file
                        throw Failure(message: "Injected caller failure after adding an unknown file")
                    }
                }
            })
            try require(foreign != nil && Data(contentsOf: foreign!) == Data("before publication".utf8), "Ownership capture recursively removed an unknown entry")
            let staging = foreign!.deletingLastPathComponent()
            let retainedDecode = try await decode(staging.appendingPathComponent("animation.mp4"))
            try require(retainedDecode.frames.count == 3, "Ownership refusal damaged verified movie")
        }
        await test("early encoder deadlines remove proven owned partials and preserve original timeout") {
            for duration in [0.001, 0.005] {
                let folder = try parent(root, "early-deadline-" + String(duration)); var callbacks = 0
                try await rejected({
                    _ = try await Service(limits: Service.Limits(operationTimeout: duration)).export(snapshot: snapshot(document()), outputParent: folder, background: .white) { _ in callbacks += 1 }
                }, matching: { if case Service.ExportError.timedOut = $0 { return true }; return false })
                try require(contents(folder).isEmpty, "Early timeout retained an owned partial")
                print("EARLY_DEADLINE_CLEAN", duration, "callbacks", callbacks)
            }
        }
        await test("concurrent foreign file before first encoded progress is never adopted or deleted") {
            let folder = try parent(root, "concurrent-before-first-frame")
            let watcher = Task.detached { () throws -> URL? in
                let localFM = FileManager.default; let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if let staging = try localFM.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasSuffix(".partial") }) {
                        let file = staging.appendingPathComponent("foreign-before-first-frame.txt")
                        try Data("Independent concurrent owner data".utf8).write(to: file, options: .withoutOverwriting)
                        return file
                    }
                    usleep(100)
                }
                return nil
            }
            let doc = try StudioDocument.new(name: "Valid blank 4 MP frame", width: 2048, height: 2048, fps: 24)
            var callbacks = 0; var error: Error?
            do {
                _ = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { state in
                    callbacks += 1
                    if state.phase == .rendering { throw Failure(message: "Caller cancels at first actual progress") }
                }
            } catch let caught { error = caught }
            let foreign = try await watcher.value
            try require(foreign != nil && callbacks == 1, "Actual concurrent pre-capture fixture did not run")
            guard let error, case Service.ExportError.cleanupFailed = error else { throw Failure(message: "Unknown data did not surface explicit cleanup refusal") }
            try require(Data(contentsOf: foreign!) == Data("Independent concurrent owner data".utf8), "Foreign data was adopted and deleted")
            try require(fm.fileExists(atPath: foreign!.deletingLastPathComponent().appendingPathComponent("animation.mp4").path), "Whole-set refusal deleted another known output")
        }
        await test("manifest creation collision preserves the foreign manifest and verified movie") {
            let folder = try parent(root, "manifest-exclusive-collision"); var foreign: URL?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { state in
                    if state.phase == .verifying {
                        let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let file = staging.appendingPathComponent("manifest.json")
                        try Data("Manifest belongs to another owner".utf8).write(to: file, options: .withoutOverwriting)
                        foreign = file
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(foreign != nil && Data(contentsOf: foreign!) == Data("Manifest belongs to another owner".utf8), "Exclusive manifest create adopted or overwrote a foreign file")
            let result = try await decode(foreign!.deletingLastPathComponent().appendingPathComponent("animation.mp4"))
            try require(result.frames.count == 3, "Manifest collision deleted or damaged the verified movie")
        }
        await test("publishing byte-identical movie clone is preserved and cannot become returned ownership") {
            let folder = try parent(root, "publishing-identical-movie"), moved = root.appendingPathComponent("publishing-movie-original.mp4")
            var replacement: URL?, originalBytes: Data?, originalInode: UInt64?, foreignInode: UInt64?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { progress in
                    if progress.phase == .publishing {
                        let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        let file = staging.appendingPathComponent("animation.mp4")
                        originalBytes = try Data(contentsOf: file); originalInode = try inode(file)
                        try fm.moveItem(at: file, to: moved); try originalBytes!.write(to: file, options: .withoutOverwriting)
                        replacement = file; foreignInode = try inode(file)
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(originalInode != foreignInode && inode(replacement!) == foreignInode && inode(moved) == originalInode, "Replacement fixture did not retain distinct original and foreign inodes")
            try require(Data(contentsOf: replacement!) == originalBytes! && Data(contentsOf: moved) == originalBytes!, "Byte-identical foreign movie or original was deleted or changed")
            try require(fm.fileExists(atPath: replacement!.deletingLastPathComponent().appendingPathComponent("manifest.json").path), "Ownership refusal deleted the other output")
            let original = try await decode(moved), foreign = try await decode(replacement!)
            try require(original.frames.count == 3 && foreign.frames.count == 3, "Real movie copies failed decode")
        }
        await test("publishing byte-identical manifest clone is preserved and cannot become returned ownership") {
            let folder = try parent(root, "publishing-identical-manifest"), moved = root.appendingPathComponent("publishing-manifest-original.json")
            var replacement: URL?, originalBytes: Data?, originalInode: UInt64?, foreignInode: UInt64?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { progress in
                    if progress.phase == .publishing {
                        let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!, file = staging.appendingPathComponent("manifest.json")
                        originalBytes = try Data(contentsOf: file); originalInode = try inode(file)
                        try fm.moveItem(at: file, to: moved); try originalBytes!.write(to: file, options: .withoutOverwriting)
                        replacement = file; foreignInode = try inode(file)
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(originalInode != foreignInode && inode(replacement!) == foreignInode && inode(moved) == originalInode, "Manifest replacement identities changed")
            try require(Data(contentsOf: replacement!) == originalBytes! && Data(contentsOf: moved) == originalBytes!, "Foreign manifest or original was lost")
            let decoded = try await decode(replacement!.deletingLastPathComponent().appendingPathComponent("animation.mp4"))
            try require(decoded.frames.count == 3, "Manifest refusal removed the verified movie")
        }
        await test("both identical output clones preserve whole set at transfer") {
            let folder = try parent(root, "publishing-identical-pair"), originals = try parent(root, "publishing-original-pair")
            var staging: URL?, records: [String: (Data, UInt64)] = [:]
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { progress in
                    if progress.phase == .publishing {
                        staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                        for name in ["animation.mp4", "manifest.json"] {
                            let file = staging!.appendingPathComponent(name), bytes = try Data(contentsOf: file), id = try inode(file)
                            records[name] = (bytes, id); try fm.moveItem(at: file, to: originals.appendingPathComponent(name)); try bytes.write(to: file, options: .withoutOverwriting)
                        }
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            for (name, record) in records {
                try require(Data(contentsOf: staging!.appendingPathComponent(name)) == record.0 && Data(contentsOf: originals.appendingPathComponent(name)) == record.0, "Pair cleanup deleted original or foreign bytes")
                try require(inode(staging!.appendingPathComponent(name)) != record.1 && inode(originals.appendingPathComponent(name)) == record.1, "Pair inode adoption")
            }
            try require(records.count == 2, "Both actual outputs reached transfer")
        }
        await test("identical completed movie replaced before verifier fingerprint is not adopted later") {
            let folder = try parent(root, "verifying-identical-movie"), moved = root.appendingPathComponent("verifying-original.mp4")
            var foreign: URL?, bytes: Data?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { progress in
                    if progress.phase == .verifying {
                        let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!, file = staging.appendingPathComponent("animation.mp4")
                        bytes = try Data(contentsOf: file); try fm.moveItem(at: file, to: moved); try bytes!.write(to: file, options: .withoutOverwriting); foreign = file
                    }
                }
            }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
            try require(Data(contentsOf: foreign!) == bytes! && Data(contentsOf: moved) == bytes!, "Verifier fingerprint adopted a pre-verification clone")
            let decoded = try await decode(foreign!); try require(decoded.frames.count == 3, "Completed clone was damaged")
        }
        await test("hardlink at transfer fails closed without unlinking either owner link") {
            let folder = try parent(root, "publishing-hardlink"), alias = root.appendingPathComponent("other-owner-hardlink.mp4")
            var original: URL?, bytes: Data?
            try await rejected({
                _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { progress in
                    if progress.phase == .publishing {
                        original = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!.appendingPathComponent("animation.mp4")
                        bytes = try Data(contentsOf: original!); try fm.linkItem(at: original!, to: alias)
                    }
                }
            })
            try require(inode(original!) == inode(alias) && Data(contentsOf: original!) == bytes! && Data(contentsOf: alias) == bytes!, "Transfer removed an added hardlink")
            try require(fm.fileExists(atPath: original!.deletingLastPathComponent().appendingPathComponent("manifest.json").path), "Hardlink refusal deleted the manifest")
        }
        await test("clone plus callback failure preserves replacement and original in both explicit files") {
            for name in ["animation.mp4", "manifest.json"] {
                let folder = try parent(root, "publishing-clone-then-error-" + name)
                var foreign: URL?, bytes: Data?
                let moved = root.appendingPathComponent("error-original-" + name)
                try await rejected({
                    _ = try await Service().export(snapshot: snapshot(document()), outputParent: folder, background: .white) { progress in
                        if progress.phase == .publishing {
                            let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                            foreign = staging.appendingPathComponent(name); bytes = try Data(contentsOf: foreign!)
                            try fm.moveItem(at: foreign!, to: moved); try bytes!.write(to: foreign!, options: .withoutOverwriting)
                            throw Failure(message: "Original caller failure after clone")
                        }
                    }
                }, matching: { if case Service.ExportError.cleanupFailed = $0 { return true }; return false })
                try require(Data(contentsOf: foreign!) == bytes! && Data(contentsOf: moved) == bytes!, "Caller failure deleted clone or original")
            }
        }
        await test("unmodified inode survives final transfer despite legitimate metadata-only change") {
            let folder = try parent(root, "publication-same-inode"), doc = try document()
            var movieInode: UInt64?, manifestInode: UInt64?
            let output = try await Service().export(snapshot: snapshot(doc), outputParent: folder, background: .white) { progress in
                if progress.phase == .publishing {
                    let staging = try contents(folder).first { $0.lastPathComponent.hasSuffix(".partial") }!
                    let movie = staging.appendingPathComponent("animation.mp4"), manifest = staging.appendingPathComponent("manifest.json")
                    movieInode = try inode(movie); manifestInode = try inode(manifest)
                    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: movie.path)
                }
            }
            try require(inode(output.movieURL) == movieInode && inode(output.manifestURL) == manifestInode, "Successful transfer changed an inode")
            let result = try await decode(output.movieURL); try require(result.frames.count == 3, "Metadata-only change damaged media")
            _ = try output.checkedURLs(); try output.cleanup(); try require(contents(folder).isEmpty, "Original owned output could not clean")
        }
        print("STUDIO_MOVIE_EXPORT_TESTS=\(failed == 0 ? "PASS" : "FAIL") \(passed)/\(passed + failed)")
        if failed != 0 { exit(1) }
    }
    static func inode(_ url: URL) throws -> UInt64 {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let value = attributes[.systemFileNumber] as? NSNumber else { throw Failure(message: "Actual inode unavailable") }
        return value.uint64Value
    }
    static func tryAudioRejection(_ input: Service.Snapshot, folder: URL) async throws {
        try await rejected({ _ = try await Service().export(snapshot: input, outputParent: folder, background: .white) }, matching: { if case Service.ExportError.audioUnsupported = $0 { return true }; return false })
    }
}
