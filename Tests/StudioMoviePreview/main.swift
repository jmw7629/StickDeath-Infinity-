import AppKit
import SwiftUI
import AVFoundation
import Combine

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}

@main @MainActor struct MoviePreviewTests {
    static let fm = FileManager.default
    static let scope = StudioMovieExportSession.Scope(isStudioVisible: true, isForeground: true, accountID: nil)
    static func wait(_ message: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), message)
    }
    static func fixture(_ root: URL, audio: Bool = false, frameCount: Int = 12, blankLater: Bool = false) async throws -> (StudioViewModel, StudioMovieExportSession) {
        let parent = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        let output = parent.appendingPathComponent("output")
        try fm.createDirectory(at: output, withIntermediateDirectories: false)
        let vm = StudioViewModel(storage: DeviceStorageManager(documentsDirectory: parent.appendingPathComponent("documents")))
        let created = await vm.createProject(name: "Actual preview", width: 64, height: 32, fps: 12)
        try require(created, "Production project creation failed")
        try require(vm.commitElement(DrawnElement(id: UUID().uuidString, tool: .brush,
            points: [.init(x: 0, y: 16), .init(x: 64, y: 16)], color: "#FF0000", width: 64,
            opacity: 1, layerID: vm.activeLayerID)), "Actual red stroke failed")
        for _ in 1..<frameCount { if blankLater { vm.addFrame() } else { vm.duplicateFrame() } }
        vm.currentFrameIndex = 0
        if audio {
            let url = parent.appendingPathComponent("original.caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let audioFrames = min(36_000, frameCount * 3_000)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFrames))!
                buffer.frameLength = AVAudioFrameCount(audioFrames)
                for n in 0..<audioFrames { for c in 0..<2 {
                    buffer.floatChannelData![c][n] = Float(sin(Double(n) * 2 * .pi * Double(c == 0 ? 480 : 960) / 48_000)) * 0.25
                } }
                try file.write(from: buffer)
            }
            let track = AudioTrack(id: UUID(), name: "Actual stereo", format: "caf",
                                  audioData: try Data(contentsOf: url), startTime: 0, duration: Double(min(36_000, frameCount * 3_000)) / 48_000)
            _ = try vm.attachImportedAudio(track, expectedProjectID: vm.document.id,
                expectedRevision: vm.document.revision, frameID: vm.currentFrame.id, trackNumber: 1)
        }
        let session = StudioMovieExportSession(outputParent: output)
        try require(session.start(from: vm, background: .white, scope: scope), "Real export did not start")
        try await wait("Real export exceeded its deadline", seconds: 20) { !session.isRunning }
        try require(session.output != nil && session.errorMessage == nil, session.errorMessage ?? "Missing rendered output")
        return (vm, session)
    }
    static func ready(_ state: StudioMoviePreviewState, _ session: StudioMovieExportSession) async throws {
        try require(state.load(session: session, scope: scope), "Preview did not obtain its actual export lease")
        try await wait("AVPlayer did not load the rendered movie: \(state.errorMessage ?? "no error")") { state.isReady || state.errorMessage != nil }
        try require(state.isReady && state.errorMessage == nil, state.errorMessage ?? "Player never became ready")
    }
    static func actualPlayback(_ root: URL) async throws {
        let (vm, session) = try await fixture(root)
        let state = StudioMoviePreviewState()
        defer { state.stop(); session.close(); withExtendedLifetime(vm) {} }
        try await ready(state, session)
        try require(abs(state.duration - 1) < 0.02 && state.currentTime == 0 && !state.isPlaying, "Preview invented its timing or autoplayed")
        guard let item = state.player?.currentItem else { throw Failure(message: "No actual AVPlayerItem") }
        let decoded = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(decoded)
        state.togglePlayback()
        try await wait("Actual player clock did not advance") { state.isPlaying && state.currentTime > 0.15 }
        state.togglePlayback()
        try await wait("Actual player did not pause") { !state.isPlaying && !state.isWaiting }
        let paused = state.player!.currentTime().seconds
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(abs(state.player!.currentTime().seconds - paused) < 0.03, "Pause left the decoder advancing")
        var frame: CVPixelBuffer?
        try await wait("AVPlayer did not decode actual preview pixels") {
            frame = decoded.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil)
            return frame != nil
        }
        let image = frame!
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let center = 16 * CVPixelBufferGetBytesPerRow(image) + 32 * 4
        let red = bytes[center + 2], blue = bytes[center], green = bytes[center + 1]
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        try require(CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 32 && red > 240 && blue < 16 && green < 16,
                    "Preview pixels are not the actual rendered red artwork")
        state.seek(to: 0.65)
        try await wait("Seek did not change actual player time") { abs(state.currentTime - 0.65) < 0.03 }
        state.togglePlayback()
        try await wait("Actual playback completion was not observed") { state.didFinish }
        try require(abs(state.currentTime - state.duration) < 0.02 && !state.isPlaying, "Completion invented a position")
        state.togglePlayback()
        try await wait("Replay did not restart the real movie") { state.isPlaying && !state.didFinish && state.currentTime < 0.5 }
        item.remove(decoded)
    }
    static func actualMixedPlayback(_ root: URL) async throws {
        let (vm, session) = try await fixture(root, audio: true)
        let state = StudioMoviePreviewState()
        defer { state.stop(); session.close(); withExtendedLifetime(vm) {} }
        try await ready(state, session)
        guard let item = state.player?.currentItem else { throw Failure(message: "No mixed preview item") }
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        try require(tracks.count == 1 && session.output?.manifest.audioIncluded == true, "Mixed preview dropped actual AAC")
        let reader = try AVAssetReader(asset: item.asset)
        let audio = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(audio); try require(reader.startReading(), "AAC decoder did not start")
        var energy = 0.0, count = 0
        while let sample = audio.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { throw Failure(message: "No actual AAC samples") }
            var length = 0; var pointer: UnsafeMutablePointer<Int8>?
            try require(CMBlockBufferGetDataPointer(data, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                   dataPointerOut: &pointer) == kCMBlockBufferNoErr, "Unreadable audio bytes")
            guard let pointer else { throw Failure(message: "Missing decoded PCM") }
            let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for i in 0..<(length / 4) { energy += Double(values[i] * values[i]); count += 1 }
        }
        try require(reader.status == .completed && count > 48_000 && energy / Double(count) > 0.01,
                    "Rendered audio is absent or silent")
        try require(state.player?.isMuted == false && state.player?.volume == 1, "Preview suppressed project audio")
        state.togglePlayback()
        try await wait("Mixed file did not actually play") { state.isPlaying && state.currentTime > 0.1 }
    }
    static func actualShortMovieScrubbing(_ root: URL) async throws {
        let (vm, session) = try await fixture(root, audio: true, frameCount: 4, blankLater: true)
        let state = StudioMoviePreviewState()
        defer { state.stop(); session.close(); withExtendedLifetime(vm) {} }
        try await ready(state, session)
        try require(abs(state.duration - 1.0 / 3) < 0.01, "Short mixed fixture timing changed")
        guard let item = state.player?.currentItem else { throw Failure(message: "Missing real short movie") }
        let decoded = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(decoded)
        defer { item.remove(decoded) }
        state.setScrubbing(true)
        for position in [0.02, 0.12, 0.20, 0.25] {
            state.updateSliderPosition(position)
            try require(state.sliderPosition == position && state.currentTime == 0 && state.isScrubbing,
                        "Slider did not retain direct finger feedback separately from actual decoder time")
            try await Task.sleep(nanoseconds: 20_000_000)
            try require(state.sliderPosition == position && state.player!.currentTime().seconds == 0,
                        "Paused decoder callback reset the active slider or claimed an unperformed seek")
        }
        state.setScrubbing(false)
        try await wait("Real short movie seek did not complete at the released slider position") {
            !state.isSeeking && abs(state.currentTime - 0.25) < 0.015 && abs(state.player!.currentTime().seconds - 0.25) < 0.015
        }
        try require(abs(state.sliderPosition - state.currentTime) < 0.001, "Slider did not return to actual decoder time")
        var frame: CVPixelBuffer?
        try await wait("The short movie did not decode the actual blank frame after seeking") {
            frame = decoded.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil)
            return frame != nil
        }
        let image = frame!
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let offset = 16 * CVPixelBufferGetBytesPerRow(image) + 32 * 4
        let actual = [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        try require(actual.allSatisfy { $0 > 240 }, "Actual seek decoded a drawn frame instead of the later blank")
        state.togglePlayback()
        try await wait("Short preview did not finish after scrubbing") { state.didFinish }
    }

    static func rapidAndInterruptedScrubbing(_ root: URL) async throws {
        let (vm, session) = try await fixture(root, frameCount: 4)
        let state = StudioMoviePreviewState()
        defer { state.stop(); session.close(); withExtendedLifetime(vm) {} }
        try await ready(state, session)
        // Accessibility-style updates may have no editing-start/end callbacks.
        for position in [0.22, 0.04, 0.12, 0.25] { state.updateSliderPosition(position) }
        try await wait("A stale seek replaced the final accessibility position") { !state.isSeeking && abs(state.currentTime - 0.25) < 0.015 }
        state.updateSliderPosition(.nan); state.updateSliderPosition(.infinity)
        try require(abs(state.sliderPosition - 0.25) < 0.015, "Nonfinite update changed playback")
        state.setScrubbing(true); state.updateSliderPosition(0.1)
        state.stop()
        state.setScrubbing(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(state.player == nil && !state.isSeeking && !state.isScrubbing && state.sliderPosition == 0 && !session.isPreviewing,
                    "Dismissed scrub restarted or retained the decoder")
        try require(session.output?.checkedURLs().count == 2, "Stopping a scrub deleted the completed export")
    }

    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-movie-preview-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var passed = 0, failed = 0
        func test(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        await test("actual player pixels, play, pause, seek, completion and replay") { try await actualPlayback(root) }
        await test("actual mixed H264/AAC file retains audible PCM and plays") { try await actualMixedPlayback(root) }
        await test("actual short mixed movie keeps finger feedback then seeks and decodes blank frame") { try await actualShortMovieScrubbing(root) }
        await test("rapid accessibility and interrupted scrubbing preserve last seek and cleanup") { try await rapidAndInterruptedScrubbing(root) }
        await test("one preview lease at a time, stop preserves output for another preview") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            let first = StudioMoviePreviewState(), second = StudioMoviePreviewState()
            try await ready(first, session)
            try require(!second.load(session: session, scope: scope) && first.isReady && session.isPreviewing, "Second preview replaced a live consumer")
            first.stop(); try require(session.output != nil && !session.isPreviewing, "Stop deleted a ready export")
            try await ready(second, session); second.stop()
        }
        await test("closing stops decoder before the output is removed") {
            let (vm, session) = try await fixture(root); defer { withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            state.togglePlayback()
            try await wait("Actual playback did not start before closing") { state.isPlaying }
            let url = session.output!.movieURL
            var stoppedBeforeRemoval = false
            let observer = session.$output.dropFirst().sink { value in
                if value == nil { stoppedBeforeRemoval = state.player == nil && !state.isPlaying }
            }
            session.close()
            try require(stoppedBeforeRemoval && !session.isPreviewing && state.player == nil && !fm.fileExists(atPath: url.path), "Cleanup raced a live decoder")
            observer.cancel()
        }
        await test("new export stops the old preview and retains only the new result") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            let old = session.output!.movieURL
            try require(session.start(from: vm, background: .white, scope: scope), "Preview prevented explicit new export")
            try require(state.player == nil && !session.isPreviewing && !fm.fileExists(atPath: old.path), "Old decoder/output survived replacement")
            try await wait("Replacement export did not finish", seconds: 20) { !session.isRunning }
            try require(session.output != nil && session.output!.movieURL != old, "New result is missing")
        }
        await test("background pauses and releases preview while preserving a reusable output") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            session.refreshScope(.init(isStudioVisible: true, isForeground: false, accountID: nil))
            try require(state.player == nil && !session.isPreviewing && session.output != nil && !session.isClosed, "Background did not stop preview safely")
            try await ready(state, session); state.stop()
        }
        await test("account change closes preview and never exposes the previous output") {
            let (vm, session) = try await fixture(root); defer { withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            session.refreshScope(.init(isStudioVisible: true, isForeground: true, accountID: "other"))
            try require(state.player == nil && session.isClosed && session.output == nil && !session.isPreviewing, "Previous account retained preview access")
        }
        await test("native sharing stops preview and owns its file through closed-panel cancellation") {
            let (vm, session) = try await fixture(root); defer { withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            guard let share = session.beginSharing(scope: scope) else { throw Failure(message: "Sharing was blocked by preview") }
            try require(state.player == nil && !session.isPreviewing && session.isSharing && share.checkedURLs().count == 2, "Consumer handoff lost its output")
            session.close(); try require(share.checkedURLs().count == 2, "Panel close deleted a native consumer file")
            share.finish(completed: false, error: nil); try require(session.output == nil, "Closed consumer did not clean after actual completion")
        }
        await test("integrity failure refuses preview and preserves unexpected files") {
            let (vm, session) = try await fixture(root); defer { withExtendedLifetime(vm) {} }
            let extra = session.output!.movieURL.deletingLastPathComponent().appendingPathComponent("foreign.txt")
            try Data("preserve me".utf8).write(to: extra)
            let state = StudioMoviePreviewState()
            try require(!state.load(session: session, scope: scope) && state.player == nil && session.needsCleanup, "Unverified output entered preview")
            session.close(); try require(fm.fileExists(atPath: extra.path), "Preview cleanup removed an unknown file")
            try fm.removeItem(at: extra); try require(session.retryCleanup(), "Explicit cleanup did not recover after conflict removal")
        }
        await test("synchronous close during preview publication cannot start a stale decoder") {
            let (vm, session) = try await fixture(root); defer { withExtendedLifetime(vm) {} }
            var closed = false
            let observer = session.$isPreviewing.dropFirst().sink { value in if value && !closed { closed = true; session.close() } }
            let state = StudioMoviePreviewState()
            try require(!state.load(session: session, scope: scope) && session.isClosed && !session.isPreviewing && state.player == nil, "Reentrant close leaked a decoder")
            observer.cancel()
        }
        await test("consumer invalidation cannot reenter export or reserve a second share") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            var refusedExport = false, refusedShare = false
            let lease = session.beginPreview(scope: scope) {
                refusedExport = !session.start(from: vm, background: .white, scope: scope)
                refusedShare = session.beginSharing(scope: scope) == nil
            }
            try require(lease != nil, "No actual preview lease")
            guard let share = session.beginSharing(scope: scope) else { throw Failure(message: "Outer share failed") }
            try require(refusedExport && refusedShare && share.checkedURLs().count == 2, "Reentrant operation stole consumer ownership")
            share.finish(completed: false, error: nil)
        }
        await test("releasing the preview model stops observers and releases its lease") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            var state: StudioMoviePreviewState? = StudioMoviePreviewState()
            try await ready(state!, session); weak var weakState = state; state = nil
            try await wait("Preview model or lease was retained after release") { weakState == nil && !session.isPreviewing }
            try require(session.output != nil, "Deinit deleted the reusable output")
        }
        await test("framework failure notification stops the real decoder, preserves output and permits retry") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            let item = state.player!.currentItem!
            state.togglePlayback(); try await wait("Playback did not start before failure notification") { state.isPlaying }
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
            try await wait("Playback failure was not exposed") { state.errorMessage != nil }
            try require(state.player == nil && !state.isPlaying && !state.isReady && !session.isPreviewing && session.output != nil,
                        "Playback failure retained the decoder, deleted output or claimed success")
            try await ready(state, session)
            try require(state.errorMessage == nil, "Actual retry retained an old failure")
            state.stop()
        }
        await test("a previous decoder failure notification cannot stop a replacement preview") {
            let (vm, session) = try await fixture(root); defer { session.close(); withExtendedLifetime(vm) {} }
            let state = StudioMoviePreviewState(); try await ready(state, session)
            let oldItem = state.player!.currentItem!
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
            // Replace synchronously before the old callback's MainActor task runs.
            try require(state.load(session: session, scope: scope), "Replacement preview refused current output")
            try await wait("Replacement preview failed to become ready") { state.isReady || state.errorMessage != nil }
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
            try await Task.sleep(nanoseconds: 50_000_000)
            try require(state.isReady && state.errorMessage == nil && session.isPreviewing, "Old failure stopped a new decoder")
            state.stop()
        }
        print("StudioMoviePreview: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
