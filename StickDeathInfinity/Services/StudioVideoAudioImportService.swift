import Foundation
import AVFoundation
import AudioToolbox
import Darwin

/// Produces an owned, decoded audio asset from one movie audio track. It does
/// not attach it or save a project: the caller must recheck its captured project
/// revision and commit through the existing audio import transaction.
actor StudioVideoAudioImportService {
    static let shared = StudioVideoAudioImportService()
    private var busy = false
    private static let rate = 44_100
    private static let bytesPerFrame = 4 // signed 16-bit interleaved stereo
    struct Result: Sendable {
        let audio: StudioAudioImportService.ImportedAudio
        let mapping: StudioVideoFrameImportService.Mapping
        let sourceDuration: Double
        var projectStartSeconds: Double { mapping.projectStartSeconds }
    }
    enum Failure: LocalizedError {
        case busy, unsupportedMovie, noAudio, invalidTrim, limitExceeded, decodeFailed, timedOut
        var errorDescription: String? {
            switch self {
            case .busy: return "Another movie soundtrack is being imported. Wait or cancel it first."
            case .unsupportedMovie: return "Choose a readable, unprotected MP4 or MOV with one video and one audio track."
            case .noAudio: return "This movie has no audio in the selected interval. No clip was added."
            case .invalidTrim: return "Choose a source trim within this movie and speed between 0.25× and 4×."
            case .limitExceeded: return "The extracted stereo soundtrack exceeds 16 MB. Choose a shorter trim (about 95 seconds at the selected speed)."
            case .decodeFailed: return "The movie soundtrack could not be decoded completely. No clip was added."
            case .timedOut: return "The movie soundtrack took too long to decode. No clip was added."
            }
        }
    }

    func extract(from url: URL, mapping: StudioVideoFrameImportService.Mapping = .init(),
                 scratchParent: URL = FileManager.default.temporaryDirectory,
                 progress: @escaping @Sendable (StudioAudioImportService.Progress) async throws -> Void = { _ in }) async throws -> Result {
        try Task.checkCancellation()
        guard !busy else { throw Failure.busy }
        _ = try mapping.sourceTime(projectSeconds: mapping.projectStartSeconds)
        guard ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { throw Failure.unsupportedMovie }
        busy = true
        defer { busy = false }
        let owned = try StudioImageProviderFile.materialize(from: url, scratchParent: scratchParent)
        do {
            let source = try owned.url()
            let decoded = try await withThrowingTaskGroup(of: Decoded.self) { group in
                group.addTask { try await Self.decode(source, mapping: mapping, progress: progress) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw Self.diagnosticDecodeFailure(line: #line) }
                return result
            }
            try Task.checkCancellation()
            _ = try owned.url()
            let scratch = try StudioAudioImportScratch.create(in: scratchParent)
            let imported: StudioAudioImportService.ImportedAudio
            do {
                let fd = try scratch.createSourceFile()
                do {
                    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    try file.write(contentsOf: decoded.wav)
                    guard fsync(fd) == 0 else { throw Self.diagnosticDecodeFailure(line: #line) }
                    _ = Darwin.close(fd)
                } catch { _ = Darwin.close(fd); throw error }
                try scratch.verify()
                imported = try await StudioAudioImportService.shared.importAudio(from: scratch.sourceURL,
                    name: String(owned.displayName.prefix(95)) + " soundtrack", scratchParent: scratchParent)
                guard abs(imported.duration - decoded.outputDuration) <= 0.002 else { throw Self.diagnosticDecodeFailure(line: #line) }
                try Task.checkCancellation()
                try scratch.cleanup()
            } catch {
                let operation = error
                do { try scratch.cleanup() }
                catch { throw StudioAudioImportService.ImportError.cleanupFailed(directory: scratch.directoryURL) }
                throw operation
            }
            try owned.cleanup()
            return Result(audio: imported, mapping: mapping, sourceDuration: decoded.sourceDuration)
        } catch {
            let operation = error
            do { try owned.cleanup() }
            catch { throw StudioImageProviderFile.Failure.operationAndCleanupFailed(operation: operation) }
            throw operation
        }
    }

    // Opt-in bounded diagnostics: numeric codec state only, never source paths/data.
    private static func diagnosticDecodeFailure(line: Int) -> Failure {
#if SDI_MOVIE_AUDIO_DIAGNOSTICS
        print("MOVIE_AUDIO decodeFailed sourceLine=\(line)")
#endif
        return .decodeFailed
    }

    private struct Decoded: Sendable {
        let wav: Data
        let sourceDuration: Double
        let outputDuration: Double
    }
    private static func decode(_ url: URL, mapping: StudioVideoFrameImportService.Mapping,
                               progress: @escaping @Sendable (StudioAudioImportService.Progress) async throws -> Void) async throws -> Decoded {
        let started = ContinuousClock.now
        func checkpoint() throws {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(60) else { throw Failure.timedOut }
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        return try await withTaskCancellationHandler {
            try checkpoint()
            guard try await asset.load(.isReadable), !(try await asset.load(.hasProtectedContent)) else { throw Failure.unsupportedMovie }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0, duration.seconds <= 3600 else { throw Failure.unsupportedMovie }
            let video = try await asset.loadTracks(withMediaType: .video)
            guard video.count == 1 else { throw Failure.unsupportedMovie }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw Failure.noAudio }
            guard tracks.count == 1 else { throw Failure.unsupportedMovie }
            let formats = try await tracks[0].load(.formatDescriptions)
            guard !formats.isEmpty, formats.count <= 16 else { throw Failure.unsupportedMovie }
            for format in formats {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      (1...2).contains(basic.mChannelsPerFrame), basic.mSampleRate.isFinite,
                      (8_000...96_000).contains(basic.mSampleRate) else { throw Failure.unsupportedMovie }
            }
            let end = mapping.sourceEndSeconds ?? duration.seconds
            guard end <= duration.seconds, end > mapping.sourceStartSeconds else { throw Failure.invalidTrim }
            let outputDuration = (end - mapping.sourceStartSeconds) / mapping.speed
            let outputFrames = Int((outputDuration * Double(rate)).rounded())
            guard outputDuration > 0, outputDuration <= 300, outputFrames > 0,
                  outputFrames <= (StudioAudioImportService.maximumEncodedBytes - 44) / bytesPerFrame else { throw Failure.limitExceeded }
            let sourceRange = CMTimeRange(start: CMTime(seconds: mapping.sourceStartSeconds, preferredTimescale: 600_000),
                end: CMTime(seconds: end, preferredTimescale: 600_000))
            let trackRange = try await tracks[0].load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(sourceRange, otherRange: trackRange)
            guard overlap.duration.isNumeric, overlap.duration > .zero else { throw Failure.noAudio }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Self.diagnosticDecodeFailure(line: #line) }
            // Empty portions are the movie's actual timeline gaps. Audio starts
            // at its original offset inside the selected interval, not at zero.
            let targetDuration = CMTime(seconds: outputDuration, preferredTimescale: 600_000)
            try track.insertTimeRange(overlap, of: tracks[0], at: CMTimeSubtract(overlap.start, sourceRange.start))
            if composition.duration < sourceRange.duration {
                composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration,
                    duration: CMTimeSubtract(sourceRange.duration, composition.duration)))
            }
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: sourceRange.duration), toDuration: targetDuration)
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            output.audioTimePitchAlgorithm = .varispeed
            reader.timeRange = CMTimeRange(start: .zero, duration: targetDuration)
            guard reader.canAdd(output) else { throw Self.diagnosticDecodeFailure(line: #line) }
            reader.add(output)
            return try await withTaskCancellationHandler {
                guard reader.startReading() else { throw Self.diagnosticDecodeFailure(line: #line) }
                defer { if reader.status == .reading { reader.cancelReading() } }
                var pcm = Data(count: outputFrames * bytesPerFrame)
                var endFrame = 0, actualFrames = 0
                while let sample = output.copyNextSampleBuffer() {
                    try checkpoint()
                    let frames = CMSampleBufferGetNumSamples(sample)
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard frames > 0, frames <= 65_536, time.isNumeric, time.seconds >= 0,
                          let block = CMSampleBufferGetDataBuffer(sample),
                          CMBlockBufferGetDataLength(block) == frames * bytesPerFrame else { throw Self.diagnosticDecodeFailure(line: #line) }
                    let startFrame = Int((time.seconds * Double(rate)).rounded())
#if SDI_MOVIE_AUDIO_DIAGNOSTICS
                    print("MOVIE_AUDIO buffer frames=\(frames) pts=\(time.value)/\(time.timescale) start=\(startFrame) end=\(endFrame) limit=\(outputFrames)")
#endif
                    guard startFrame >= endFrame, startFrame <= outputFrames,
                          frames <= outputFrames - startFrame + 1 else { throw Self.diagnosticDecodeFailure(line: #line) }
                    let count = min(frames, outputFrames - startFrame)
                    guard pcm.withUnsafeMutableBytes({ bytes in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * bytesPerFrame,
                            destination: bytes.baseAddress!.advanced(by: startFrame * bytesPerFrame))
                    }) == noErr else { throw Self.diagnosticDecodeFailure(line: #line) }
                    actualFrames += count; endFrame = startFrame + count
                    // Only report frames actually supplied by AVFoundation.
                    // Genuine timeline gaps can leave completed below total;
                    // final owned-file validation does not reset this progress.
                    try await progress(.init(phase: .decoding, completed: Int64(actualFrames), total: Int64(outputFrames)))
                    try checkpoint()
                    await Task.yield()
                }
                try checkpoint()
#if SDI_MOVIE_AUDIO_DIAGNOSTICS
                print("MOVIE_AUDIO terminal status=\(reader.status.rawValue) frames=\(actualFrames) end=\(endFrame) expected=\(outputFrames) errorCode=\((reader.error as NSError?)?.code ?? 0)")
#endif
                guard reader.status == .completed, actualFrames > 0 else { throw Self.diagnosticDecodeFailure(line: #line) }
                var wav = Data("RIFF".utf8)
                func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
                func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
                u32(UInt32(pcm.count + 36)); wav.append(contentsOf: "WAVEfmt ".utf8)
                u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * bytesPerFrame)); u16(4); u16(16)
                wav.append(contentsOf: "data".utf8); u32(UInt32(pcm.count)); wav.append(pcm)
                return Decoded(wav: wav, sourceDuration: duration.seconds, outputDuration: Double(outputFrames) / Double(rate))
            } onCancel: { reader.cancelReading() }
        } onCancel: { asset.cancelLoading() }
    }
}
