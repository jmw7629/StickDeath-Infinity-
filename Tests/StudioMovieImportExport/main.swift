import Foundation
import AppKit
import SwiftUI
import AVFoundation
import Darwin

typealias UIImage = NSImage
extension Image { init(uiImage: NSImage) { self.init(nsImage: uiImage) } }
private struct Failure: Error { let message: String }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw Failure(message: message) }
}
@main @MainActor struct MovieImportExportTests {
    static func requireAsync(_ value: Bool, _ message: String) throws { try require(value, message) }
    static func main() async {
        do { try await run() } catch { print("FAIL movie import/export journey: \(error)"); exit(1) }
    }
    static func run() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-import-export-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch"), outputParent = root.appendingPathComponent("output")
        for folder in [scratch, outputParent] { try fm.createDirectory(at: folder, withIntermediateDirectories: false) }
        let source = try await makeMovie(root)
        let originalMovie = try Data(contentsOf: source)
        let mapping = StudioVideoFrameImportService.Mapping(sourceStartSeconds: 1, sourceEndSeconds: 1.75,
            projectStartSeconds: 0.125, speed: 2)
        let pictures = try await StudioVideoFrameImportService().extractSequence(from: source,
            projectFrameIndex: 1, fps: 8, frameCount: 3, mapping: mapping, scratchParent: scratch)
        let soundtrack = try await StudioVideoAudioImportService().extract(from: source, mapping: mapping, scratchParent: scratch)
        try require(pictures.map { $0.sourceRequestedSeconds } == [1, 1.25, 1.5]
            && abs(soundtrack.audio.duration - 0.375) < 0.002, "Source trim/speed mapping differs between pictures and sound")
        let docs = root.appendingPathComponent("documents")
        let storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
        let vm = StudioViewModel(storage: storage)
        try requireAsync(await vm.createProject(name: "Movie round trip", width: 64, height: 96, fps: 8), "Create failed")
        let originalFrame = vm.document.activeFrameID
        let frames = try vm.attachImportedImageSequence(pictures.map(\.image), expectedProjectID: vm.document.id,
            expectedRevision: vm.document.revision, frameID: originalFrame, layerID: vm.document.activeLayerID)
        try require(vm.document.activeFrameID == frames[0] && vm.frames.count == 4, "Reference sequence not appended after original frame")
        let clipID = try vm.attachImportedAudio(soundtrack.audio.track, expectedProjectID: vm.document.id,
            expectedRevision: vm.document.revision, frameID: frames[0], trackNumber: 2)
        try require(vm.audioClips[0].startTime == 0.125, "Audio not attached alongside first imported image")
        vm.selectedAudioClip = vm.audioClips[0]
        guard let trim = vm.prepareAudioTrim() else { throw Failure(message: "Real clip trim unavailable") }
        try vm.trimAudioClip(trim, sourceOffset: 0.0625, duration: 0.25)
        vm.setAudioClipVolume(clipID, volume: 0.5)
        let expectedClip = vm.audioClips[0], projectID = vm.document.id
        try require(abs(expectedClip.sourceOffset - 0.0625) < 0.00001 && abs(expectedClip.duration - 0.25) < 0.00001
            && abs(expectedClip.volume - 0.5) < 0.00001, "Canonical clip trim and gain were not applied")
        try requireAsync(await vm.save(), "Actual project save failed")
        let saved = try storage.loadAnimation(id: projectID)!
        await vm.backToProjects()
        let reopened = StudioViewModel(storage: storage)
        try requireAsync(await reopened.openProject(saved.metadata), "Cold reopen failed")
        try require(reopened.audioClips == [expectedClip] && reopened.frames.map(\.id) == [originalFrame] + frames,
            "Reopen changed canonical timing/order")
        try require(reopened.audioTrack(forAssetID: soundtrack.audio.id)?.audioData == soundtrack.audio.originalData,
            "Cold reopen changed source audio bytes")
        var rasters: [String: Data] = [:]
        for (index, frame) in reopened.frames.dropFirst().enumerated() {
            guard let id = frame.rasterAssetID, let data = reopened.rasterData(id) else { throw Failure(message: "Managed image missing") }
            try require(data == pictures[index].image.normalizedPNG, "Cold reopen changed oriented reference bytes")
            rasters[id] = data
        }
        let snapshot = StudioMovieExportService.Snapshot(document: reopened.document,
            retainedAudioTracks: reopened.projectAudioTracks, rasterDataByID: rasters)
        // An untrimmed fractional-rate asset must reach its real EOF, not fail
        // because Core Audio emits floor rather than rounded output samples.
        var fullDocument = reopened.document
        fullDocument.audioClips[0].sourceOffset = 0
        fullDocument.audioClips[0].duration = soundtrack.audio.duration
        fullDocument.audioClips[0].volume = 1
        print("BEGIN_UNTRIMMED_MIX originalFrames=\(soundtrack.audio.decodedFrameCount) sampleRate=\(soundtrack.audio.sampleRate) duration=\(soundtrack.audio.duration)")
        let fullMix = try await StudioAudioMixService().mix(document: fullDocument,
            retainedAudioTracks: reopened.projectAudioTracks, durationSeconds: 1, outputParent: outputParent) { progress in
                print("ACTUAL_UNTRIMMED_MIX_STAGE=\(progress.phase) COMPLETED=\(progress.completed) TOTAL=\(progress.total)")
            }
        let fullURL = try fullMix.checkedURL()
        let fullReader = try AVAudioFile(forReading: fullURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        try require(fullReader.length == 48_000, "Full fractional asset changed output duration")
        let ending = AVAudioPCMBuffer(pcmFormat: fullReader.processingFormat, frameCapacity: 2048)!
        fullReader.framePosition = 22_000
        try fullReader.read(into: ending, frameCount: 2048)
        guard let channel = ending.floatChannelData else { throw Failure(message: "Full mix has no real PCM") }
        let tailPeak = (0..<1800).map { abs(channel[0][$0]) }.max() ?? 0
        let afterPeak = (2002..<2048).map { abs(channel[0][$0]) }.max() ?? 0
        try require(tailPeak > 0.2 && afterPeak == 0, "Full fractional asset lost tail samples or played past source EOF")
        try fullMix.cleanup()
        // A genuine one-sample source overrun must remain rejected even though
        // old metadata preflight allows one frame of rounding tolerance.
        fullDocument.audioClips[0].duration += 1 / 48_000.0
        do {
            let unexpected = try await StudioAudioMixService().mix(document: fullDocument,
                retainedAudioTracks: reopened.projectAudioTracks, durationSeconds: 1, outputParent: outputParent)
            try unexpected.cleanup()
            throw Failure(message: "Fractional source overrun unexpectedly accepted")
        } catch StudioAudioMixService.MixError.invalidTimeline { }
        try require(fm.contentsOfDirectory(atPath: outputParent.path).isEmpty, "Fractional endpoint check leaked output")
        // The adjacent resampling endpoint rule must not accept a shortened
        // encoded source or falsified duration metadata.
        for truncate in [true, false] {
            var damaged = reopened.projectAudioTracks
            if truncate { damaged[0].audioData!.removeLast(2) }
            else { damaged[0].duration += 0.01 }
            do {
                let unexpected = try await StudioAudioMixService().mix(document: reopened.document,
                    retainedAudioTracks: damaged, durationSeconds: 0.5, outputParent: outputParent)
                try unexpected.cleanup()
                throw Failure(message: "Damaged imported PCM unexpectedly mixed")
            } catch StudioAudioMixService.MixError.invalidAsset { }
            try require(fm.contentsOfDirectory(atPath: outputParent.path).isEmpty, "Rejected mix left partial output")
        }
        print("IMPORTED_SOURCE_FRAMES=\(soundtrack.audio.decodedFrameCount) RATE=\(soundtrack.audio.sampleRate) DURATION=\(soundtrack.audio.duration)")
        let output = try await StudioMixedMovieExportService().export(snapshot: snapshot, outputParent: outputParent) { progress in
            print("ACTUAL_MIXED_EXPORT_STAGE=\(progress.phase) COMPLETED=\(progress.completed) TOTAL=\(progress.total)")
        }
        let url = try output.checkedURLs()[0], asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        try require(video.count == 1 && audio.count == 1 && output.receipt.videoFrames == 4,
            "Real MP4 does not contain canonical picture/audio tracks")
        let duration = try await asset.load(.duration)
        try require(abs(duration.seconds - 0.5) < 0.0001 && output.receipt.decodedAudioFrames == 24_000,
            "Real exported movie duration differs from Studio")
        try await verifyVideo(asset, track: video[0])
        let samples = try await decodeAudio(asset, track: audio[0])
        try require(samples.count == 48_000, "Real AAC decoded sample count differs")
        var silence: Float = 0, squares = 0.0
        for n in 0..<24_000 {
            let value = samples[n * 2]
            if n < 4_500 || n > 20_000 { silence = max(silence, abs(value)) }
            if (8_000..<16_000).contains(n) {
                squares += Double(value * value)
            }
        }
        let rms = sqrt(squares / 8_000)
        // Source changes 440 -> 660 Hz at 1.375s. Import starts at 1s,
        // speed 2 maps that marker to 0.1875s in the managed asset. The
        // canonical 0.0625s clip trim moves it to movie time 0.25s:
        // 0.125 + (1.375 - 1) / 2 - 0.0625. Without sourceOffset it
        // occurs at 0.3125s. Probe windows avoid AAC transition ringing
        // and distinguish both behaviors in the actual cold-reopened MP4.
        func frequency(in frames: Range<Int>) -> Double {
            var crossings = 0
            for n in frames where samples[n * 2] >= 0 && samples[(n - 1) * 2] < 0 { crossings += 1 }
            return Double(crossings) * 48_000 / Double(frames.count)
        }
        let beforeMarker = frequency(in: 7_440..<9_360) // 0.155..<0.195s
        let afterMarker = frequency(in: 12_960..<14_400) // 0.270..<0.300s
        print("ACTUAL_EXPORTED_AUDIO_RMS=\(rms) BEFORE_MARKER_HZ=\(beforeMarker) AFTER_MARKER_HZ=\(afterMarker) SILENCE=\(silence)")
        // Measure the actual imported stereo amplitude, then assert that the
        // editable clip gain reaches AAC once (without assuming a downmix law).
        let expectedRMS = Double(soundtrack.audio.waveformPeaks.max() ?? 0) * 0.5 / sqrt(2)
        try require(rms > 0.05 && abs(rms - expectedRMS) < 0.006 && abs(beforeMarker - 880) < 40 && abs(afterMarker - 1320) < 40 && silence < 0.002,
            "Export lost real source tone, varispeed, gain, trim or leading/trailing silence")
        try require(try Data(contentsOf: source) == originalMovie, "Original source movie changed")
        try require(fm.contentsOfDirectory(atPath: scratch.path).isEmpty, "Import temporary media leaked")
        try output.cleanup()
        try require(fm.contentsOfDirectory(atPath: outputParent.path).isEmpty, "Export output cleanup leaked files")
        await reopened.backToProjects()
        print("PASS actual movie trim/speed → managed reference sequence/audio → edited clip → save/cold reopen → decoded H264/AAC MP4 timing, pixels, tone, gain and silence")
    }
    static func makeMovie(_ root: URL) async throws -> URL {
        let silent = root.appendingPathComponent("rotated.mov"), tone = root.appendingPathComponent("tone.wav")
        try await VideoFrameFixture.makeMovie(silent, rotate: true)
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: tone, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 88_200)!
            buffer.frameLength = 88_200
            for n in 0..<88_200 {
                let seconds = Double(n) / 44_100
                // Pre-trim sentinel plus a marker inside the selected interval:
                // fixed amplitude keeps the existing gain/RMS assertion useful.
                let cycles: Double
                if seconds < 1 { cycles = seconds * 220 }
                else if seconds < 1.375 { cycles = 220 + (seconds - 1) * 440 }
                else { cycles = 385 + (seconds - 1.375) * 660 }
                buffer.floatChannelData![0][n] = Float(0.4 * sin(cycles * 2 * .pi))
            }
            try writer.write(from: buffer)
        }
        let videoAsset = AVURLAsset(url: silent), soundAsset = AVURLAsset(url: tone), composition = AVMutableComposition()
        let video = try await videoAsset.loadTracks(withMediaType: .video)[0], audio = try await soundAsset.loadTracks(withMediaType: .audio)[0]
        let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        try vt.insertTimeRange(range, of: video, at: .zero); vt.preferredTransform = try await video.load(.preferredTransform)
        try at.insertTimeRange(range, of: audio, at: .zero)
        let url = root.appendingPathComponent("original.mov")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        export.outputURL = url; export.outputFileType = .mov; await export.export()
        try require(export.status == .completed, "Original tone/movie fixture export failed")
        return url
    }
    static func verifyVideo(_ asset: AVAsset, track: AVAssetTrack) async throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); try require(reader.startReading(), "Video decoder did not start")
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            guard count < 4, let image = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "Unexpected video frame") }
            try require(CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 96, "Export changed oriented canvas size")
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(count), timescale: 8)) == 0, "Actual video PTS differs")
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let p = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                .advanced(by: 48 * CVPixelBufferGetBytesPerRow(image) + 32 * 4)
            let b = p[0], g = p[1], r = p[2]
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if count == 0 { try require(r > 220 && g > 220 && b > 220, "Original blank frame overwritten") }
            else if count == 1 { try require(g > 180 && r < 60 && b < 60, "First trimmed movie frame is not green") }
            else { try require(b > 180 && r < 60 && g < 60, "Subsequent movie frame is not blue") }
            count += 1
        }
        try require(reader.status == .completed && count == 4, "Video decoder did not finish all frames")
    }
    static func decodeAudio(_ asset: AVAsset, track: AVAssetTrack) async throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        reader.add(output); try require(reader.startReading(), "Audio decoder did not start")
        var values: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, count <= 65_536, count <= 24_000 - values.count / 2,
                  let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) == count * 8 else { throw Failure(message: "Invalid bounded PCM") }
            try require(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(values.count / 2), timescale: 48_000)) == 0, "Actual audio PTS differs")
            var chunk = [Float](repeating: 0, count: count * 2)
            try require(chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 8, destination: $0.baseAddress!) } == noErr, "Audio PCM copy failed")
            values.append(contentsOf: chunk)
        }
        try require(reader.status == .completed, "Audio decoder failed")
        return values
    }
}
