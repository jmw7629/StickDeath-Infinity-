import Foundation
import AVFoundation
import Darwin

private struct Failure: Error { let message: String }
// Report the actual difference before the strict comparison fails. A second
// AVFoundation decode is a different boundary from attachment/persistence;
// equal lengths alone cannot distinguish header drift, quantization or damage.
private func describePCMComparison(_ actual: Data, _ expected: Data) {
    guard actual != expected else { return }
    guard actual.count == expected.count, actual.count >= 44,
          (actual.count - 44).isMultiple(of: 2) else {
        print("MOVIE_AUDIO PCM comparison incompatible lengths=\(actual.count)/\(expected.count)")
        return
    }
    var changed = 0, maximumDelta = 0, squaredDelta = 0.0
    var firstChangedSample: Int?
    for offset in stride(from: 44, to: actual.count, by: 2) {
        let lhs = Int(Int16(bitPattern: UInt16(actual[offset]) | UInt16(actual[offset + 1]) << 8))
        let rhs = Int(Int16(bitPattern: UInt16(expected[offset]) | UInt16(expected[offset + 1]) << 8))
        let delta = abs(lhs - rhs)
        if delta != 0 {
            changed += 1
            if firstChangedSample == nil { firstChangedSample = (offset - 44) / 2 }
        }
        maximumDelta = max(maximumDelta, delta)
        squaredDelta += Double(delta) * Double(delta)
    }
    let samples = (actual.count - 44) / 2
    let rms = samples == 0 ? 0 : sqrt(squaredDelta / Double(samples))
    print("MOVIE_AUDIO PCM headerMatches=\(actual.prefix(44) == expected.prefix(44)) changedSamples=\(changed)/\(samples) firstChangedSample=\(firstChangedSample ?? -1) maximumDeltaLSB=\(maximumDelta) rmsDeltaLSB=\(rms)")
}
// A sustained generated tone must still contain audio at its selected tail.
// Equal lengths alone would accept a preallocated zero-filled missing suffix.
private func tailPeak(_ wav: Data, frames: Int) -> Double {
    guard wav.count >= 44 + frames * 4 else { return 0 }
    var peak = 0
    for offset in stride(from: wav.count - frames * 4, to: wav.count, by: 2) {
        let sample = Int(Int16(bitPattern: UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8))
        peak = max(peak, abs(sample))
    }
    return Double(peak) / 32768
}
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message: message) }
}
private actor ChunkReceipt {
    var frames: Int64 = 0
    var total: Int64 = 0
    func record(_ progress: StudioAudioImportService.Progress) {
        frames = progress.completed; total = progress.total
    }
    func snapshot() -> (Int64, Int64) { (frames, total) }
}
private actor PreparedAudioReceipt {
    private var bytes: Data?
    func record(_ value: Data) { bytes = value }
    func snapshot() -> Data? { bytes }
}
@main @MainActor struct VideoAudioTests {
    static func idle(_ session: StudioAudioPreviewSession) async throws {
        for _ in 0..<14_000 {
            if !session.isBusy { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure(message: "Prepared movie import did not terminate")
    }
    static func requireAsync(_ condition: Bool, _ message: String) throws { try require(condition, message) }
    static func main() async {
        do { try await run() } catch { print("FAIL movie audio: \(error)"); exit(1) }
    }
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sdi-movie-audio-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        let sentinel = scratch.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        func clean() throws { try require(try fm.contentsOfDirectory(atPath: scratch.path) == ["sentinel"], "owned scratch leaked or sentinel removed") }
        let silent = root.appendingPathComponent("silent.mov")
        try await VideoFrameFixture.makeMovie(silent, rotate: true)
        let audio = root.appendingPathComponent("signal.wav")
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 88_200)!
            buffer.frameLength = 88_200
            for i in 0..<88_200 { buffer.floatChannelData![0][i] = (i < 44_100 ? 0.2 : 0.6) * sin(Float(i) * 2 * .pi * 440 / 44_100) }
            try file.write(from: buffer)
        }
        let videoAsset = AVURLAsset(url: silent), audioAsset = AVURLAsset(url: audio)
        let movie = root.appendingPathComponent("with-audio.mov")
        let composition = AVMutableComposition()
        let video = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let sound = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: video, at: .zero)
        vt.preferredTransform = try await video.load(.preferredTransform)
        let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try at.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: sound, at: .zero)
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        exporter.outputURL = movie; exporter.outputFileType = .mov
        await exporter.export()
        try require(exporter.status == .completed, "fixture export failed")
        let original = try Data(contentsOf: movie)
        print("MOVIE_AUDIO fixture movieBytes=\(original.count) generatedPCMFrames=88200 generatedPCMRate=44100 videoDuration=\(try await videoAsset.load(.duration).seconds) audioDuration=\(try await audioAsset.load(.duration).seconds)")
        let service = StudioVideoAudioImportService()
        print("MOVIE_AUDIO stage: full")
        let full = try await service.extract(from: movie, scratchParent: scratch) { progress in
            guard case .decoding = progress.phase else { return }
            print("MOVIE_AUDIO full decoded=\(progress.completed)/\(progress.total)")
        }
        print("MOVIE_AUDIO full result duration=\(full.audio.duration) channels=\(full.audio.channelCount)")
        try require(abs(full.audio.duration - 2) < 0.002 && full.audio.channelCount == 2, "wrong full output format/duration")
        try require(full.audio.waveformPeaks.max()! > 0.4, "actual waveform missing")
        try require(full.audio.track.audioData == full.audio.originalData && full.audio.track.startTime == 0, "not canonical managed audio")
        try clean()
        print("MOVIE_AUDIO stage: fast trim")
        let fast = try await service.extract(from: movie,
            mapping: .init(sourceStartSeconds: 1, sourceEndSeconds: 2, projectStartSeconds: 3, speed: 2), scratchParent: scratch)
        print("MOVIE_AUDIO fast result duration=\(fast.audio.duration) channels=\(fast.audio.channelCount)")
        try require(abs(fast.audio.duration - 0.5) < 0.002 && fast.projectStartSeconds == 3, "trim/speed/placement mapping failed")
        try require(fast.audio.waveformPeaks.max()! > 0.4, "trim selected wrong source samples")
        try require(tailPeak(fast.audio.originalData, frames: 40) > 0.4, "Fast soundtrack lost its final tone samples")
        try clean()
        print("MOVIE_AUDIO stage: slow trim")
        let slow = try await service.extract(from: movie,
            mapping: .init(sourceStartSeconds: 0, sourceEndSeconds: 1, speed: 0.5), scratchParent: scratch)
        print("MOVIE_AUDIO slow result duration=\(slow.audio.duration) channels=\(slow.audio.channelCount)")
        try require(abs(slow.audio.duration - 2) < 0.002 && slow.audio.waveformPeaks.max()! < 0.3, "slow trim ignored")
        try require(tailPeak(slow.audio.originalData, frames: 100) > 0.1, "Slow soundtrack lost its final tone samples")
        try clean()
        print("MOVIE_AUDIO stage: boundary and fractional speeds")
        for speed in [0.25, 4.0, 1.3] {
            let result = try await service.extract(from: movie,
                mapping: .init(sourceStartSeconds: 1, sourceEndSeconds: 2, speed: speed), scratchParent: scratch)
            let frames = Int((44_100 / speed).rounded())
            try require(result.audio.originalData.count == 44 + frames * 4 && tailPeak(result.audio.originalData, frames: 120) > 0.3,
                "Boundary/fractional speed lost duration or final tone: \(speed)")
            try clean()
        }
        let fractional = try await service.extract(from: movie,
            mapping: .init(sourceStartSeconds: 0.12345, sourceEndSeconds: 0.62345, speed: 1.3), scratchParent: scratch)
        try require(fractional.audio.originalData.count == 44 + Int((0.5 * 44_100 / 1.3).rounded()) * 4,
            "Fractional trim changed the selected duration")
        try require(tailPeak(fractional.audio.originalData, frames: 120) > 0.1, "Fractional trim lost its tone tail")
        try clean()
        print("MOVIE_AUDIO stage: no audio")
        do { _ = try await service.extract(from: silent, scratchParent: scratch); throw Failure(message: "no-audio returned success") }
        catch StudioVideoAudioImportService.Failure.noAudio { }
        try clean()
        print("MOVIE_AUDIO stage: invalid trim")
        do { _ = try await service.extract(from: movie, mapping: .init(sourceEndSeconds: 3), scratchParent: scratch); throw Failure(message: "past-end trim succeeded") }
        catch StudioVideoAudioImportService.Failure.invalidTrim { }
        try clean()
        print("MOVIE_AUDIO stage: unsafe source")
        let link = root.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: movie)
        do { _ = try await service.extract(from: link, scratchParent: scratch); throw Failure(message: "link accepted") }
        catch is StudioImageProviderFile.Failure { }
        try clean()
        print("MOVIE_AUDIO stage: pre-cancellation")
        let cancelled = Task { try await Task.sleep(nanoseconds: 1_000_000_000); return try await service.extract(from: movie, scratchParent: scratch) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message: "cancel succeeded") } catch is CancellationError { }
        try clean()
        print("MOVIE_AUDIO stage: chunk cancellation")
        let chunk = ChunkReceipt()
        do {
            _ = try await service.extract(from: movie, scratchParent: scratch) { progress in
                guard case .decoding = progress.phase else { return }
                await chunk.record(progress)
                throw CancellationError()
            }
            throw Failure(message: "Cancellation after a decoded chunk returned success")
        } catch is CancellationError { }
        let receipt = await chunk.snapshot()
        try require(receipt.0 > 0 && receipt.0 < receipt.1 && receipt.1 == 88_200,
            "Cancellation callback did not follow the first actual bounded PCM chunk")
        try clean()
        try require(try Data(contentsOf: movie) == original, "original movie changed")
        // One real one-second audio track occupies only the middle of a
        // two-second movie. Leading/trailing gaps must retain their timing.
        let gapMovie = root.appendingPathComponent("audio-gaps.mov")
        let gapComposition = AVMutableComposition()
        let gapVideo = gapComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try gapVideo.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: video, at: .zero)
        let gapAudio = gapComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try gapAudio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)),
            of: sound, at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let gapExport = AVAssetExportSession(asset: gapComposition, presetName: AVAssetExportPresetPassthrough)!
        gapExport.outputURL = gapMovie; gapExport.outputFileType = .mov
        await gapExport.export()
        try require(gapExport.status == .completed, "Gap fixture export failed")
        print("MOVIE_AUDIO stage: timeline gaps")
        let gap = try await service.extract(from: gapMovie, scratchParent: scratch)
        print("MOVIE_AUDIO gap result duration=\(gap.audio.duration) channels=\(gap.audio.channelCount)")
        try require(abs(gap.audio.duration - 2) < 0.002 && gap.audio.waveformPeaks.prefix(50).allSatisfy { $0 == 0 }
            && gap.audio.waveformPeaks.suffix(50).allSatisfy { $0 == 0 }
            && gap.audio.waveformPeaks[80..<176].max()! > 0.1,
            "Movie audio gaps were collapsed or replaced with a silent soundtrack")
        try clean()
        print("MOVIE_AUDIO stage: prepared import")
        let docs = root.appendingPathComponent("documents")
        let storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
        let vm = StudioViewModel(storage: storage)
        try requireAsync(await vm.createProject(name: "Movie soundtrack", width: 64, height: 64, fps: 8), "Project creation failed")
        vm.addFrame(); vm.addFrame()
        let projectID = vm.document.id, revision = vm.document.revision, frameID = vm.document.activeFrameID
        let session = StudioAudioPreviewSession(scratchParent: scratch)
        let mapping = StudioVideoFrameImportService.Mapping(sourceStartSeconds: 1, sourceEndSeconds: 2,
            projectStartSeconds: 0.25, speed: 2)
        let preparedReceipt = PreparedAudioReceipt()
        try require(session.importFile(movie, prepare: { progress in
            let audio = try await service.extract(from: movie, mapping: mapping, scratchParent: scratch, progress: progress).audio
            await preparedReceipt.record(audio.originalData)
            return audio
        }, stillCurrent: { vm.document.id == projectID && vm.document.revision == revision }, attach: {
            try vm.attachImportedAudio($0, expectedProjectID: projectID, expectedRevision: revision,
                frameID: frameID, trackNumber: 2)
        }), "Prepared movie import refused")
        try await idle(session)
        guard let clip = vm.audioClips.first, let assetID = clip.assetID,
              let bytes = vm.audioTrack(forAssetID: assetID)?.audioData else {
            throw Failure(message: "Prepared movie failed attachment: \(session.notice ?? "no notice")")
        }
        try require(clip.startTime == 0.25 && abs(clip.duration - 0.5) < 0.002 && clip.track == 2,
            "Prepared movie clip placed at wrong frame or ignored mapping")
        try require(vm.document.revision == revision + 1 && session.lastImportedClipID == clip.id,
            "Movie import was not one canonical edit")
        try require((session.measurements[assetID]?.peaks.max() ?? 0) > 0.4, "Prepared import lost measured waveform")
        guard let preparedBytes = await preparedReceipt.snapshot() else { throw Failure(message: "Missing prepared-audio receipt") }
        print("MOVIE_AUDIO attachment matches handoff=\(bytes == preparedBytes) separate decode identical=\(bytes == fast.audio.originalData) byteCounts=\(bytes.count)/\(preparedBytes.count)/\(fast.audio.originalData.count)")
        try require(bytes == preparedBytes, "Attachment changed the actual prepared movie PCM")
        describePCMComparison(bytes, fast.audio.originalData)
        try require((bytes == fast.audio.originalData), "Prepared import selected different movie PCM than the direct extraction")
        try requireAsync(await vm.save(), "Movie project save failed")
        let saved = try storage.loadAnimation(id: projectID)!
        try require(saved.audioTracks.count == 1 && saved.audioTracks[0].audioData == bytes,
            "Movie asset not persisted in same snapshot")
        try require(try StudioDocumentArchive.decode(saved.editableDocumentData!).document.audioClips == vm.audioClips,
            "Movie clip archive differs from saved asset")
        vm.undo()
        try require(vm.audioClips.isEmpty && vm.managedAudioByteCount == bytes.count, "Undo lost redo bytes or retained clip")
        vm.redo()
        try require(vm.audioClips.first == clip && vm.audioTrack(forAssetID: assetID)?.audioData == bytes,
            "Redo changed imported movie identity, timing or bytes")
        try requireAsync(await vm.save(), "Redo save failed")
        session.close(); await vm.backToProjects()
        let reopened = StudioViewModel(storage: storage)
        try requireAsync(await reopened.openProject(saved.metadata), "Movie project cold reopen failed")
        try require(reopened.audioClips.first == clip && reopened.audioTrack(forAssetID: assetID)?.audioData == bytes,
            "Cold reopen changed movie clip timing or managed audio bytes")
        await reopened.backToProjects(); try clean()
        print("PASS prepared movie import: selected-frame placement, single edit, measured waveform, managed bytes, undo/redo, actual save/cold reopen")
        print("PASS 12 production movie-audio groups: boundary/fractional speed and trim, actual PCM/waveform, canonical asset, trim/speed/placement, no-audio, bounds, unsafe source, cancellation, cleanup/original preservation")
    }
}
