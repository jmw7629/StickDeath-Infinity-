import Foundation
import AVFoundation
import Darwin

private struct Failure: Error { let message: String }
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
        let service = StudioVideoAudioImportService()
        let full = try await service.extract(from: movie, scratchParent: scratch)
        try require(abs(full.audio.duration - 2) < 0.002 && full.audio.channelCount == 2, "wrong full output format/duration")
        try require(full.audio.waveformPeaks.max()! > 0.4, "actual waveform missing")
        try require(full.audio.track.audioData == full.audio.originalData && full.audio.track.startTime == 0, "not canonical managed audio")
        try clean()
        let fast = try await service.extract(from: movie,
            mapping: .init(sourceStartSeconds: 1, sourceEndSeconds: 2, projectStartSeconds: 3, speed: 2), scratchParent: scratch)
        try require(abs(fast.audio.duration - 0.5) < 0.002 && fast.projectStartSeconds == 3, "trim/speed/placement mapping failed")
        try require(fast.audio.waveformPeaks.max()! > 0.4, "trim selected wrong source samples")
        try clean()
        let slow = try await service.extract(from: movie,
            mapping: .init(sourceStartSeconds: 0, sourceEndSeconds: 1, speed: 0.5), scratchParent: scratch)
        try require(abs(slow.audio.duration - 2) < 0.002 && slow.audio.waveformPeaks.max()! < 0.3, "slow trim ignored")
        try clean()
        do { _ = try await service.extract(from: silent, scratchParent: scratch); throw Failure(message: "no-audio returned success") }
        catch StudioVideoAudioImportService.Failure.noAudio { }
        try clean()
        do { _ = try await service.extract(from: movie, mapping: .init(sourceEndSeconds: 3), scratchParent: scratch); throw Failure(message: "past-end trim succeeded") }
        catch StudioVideoAudioImportService.Failure.invalidTrim { }
        try clean()
        let link = root.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: movie)
        do { _ = try await service.extract(from: link, scratchParent: scratch); throw Failure(message: "link accepted") }
        catch is StudioImageProviderFile.Failure { }
        try clean()
        let cancelled = Task { try await Task.sleep(nanoseconds: 1_000_000_000); return try await service.extract(from: movie, scratchParent: scratch) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure(message: "cancel succeeded") } catch is CancellationError { }
        try clean()
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
        let gap = try await service.extract(from: gapMovie, scratchParent: scratch)
        try require(abs(gap.audio.duration - 2) < 0.002 && gap.audio.waveformPeaks.prefix(50).allSatisfy { $0 == 0 }
            && gap.audio.waveformPeaks.suffix(50).allSatisfy { $0 == 0 }
            && gap.audio.waveformPeaks[80..<176].max()! > 0.1,
            "Movie audio gaps were collapsed or replaced with a silent soundtrack")
        try clean()
        let docs = root.appendingPathComponent("documents")
        let storage = DeviceStorageManager(documentsDirectory: docs, cachesDirectory: docs)
        let vm = StudioViewModel(storage: storage)
        try requireAsync(await vm.createProject(name: "Movie soundtrack", width: 64, height: 64, fps: 8), "Project creation failed")
        vm.addFrame(); vm.addFrame()
        let projectID = vm.document.id, revision = vm.document.revision, frameID = vm.document.activeFrameID
        let session = StudioAudioPreviewSession(scratchParent: scratch)
        let mapping = StudioVideoFrameImportService.Mapping(sourceStartSeconds: 1, sourceEndSeconds: 2,
            projectStartSeconds: 0.25, speed: 2)
        try require(session.importFile(movie, prepare: { progress in
            try await service.extract(from: movie, mapping: mapping, scratchParent: scratch, progress: progress).audio
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
        try require(bytes == fast.audio.originalData, "Prepared import changed selected movie PCM")
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
        print("PASS 11 production movie-audio groups: actual PCM/waveform, canonical asset, trim/speed/placement, no-audio, bounds, unsafe source, cancellation, cleanup/original preservation")
    }
}
