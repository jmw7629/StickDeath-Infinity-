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
            guard let firstFormat = formats.first,
                  let sourceBasic = CMAudioFormatDescriptionGetStreamBasicDescription(firstFormat)?.pointee else { throw Failure.unsupportedMovie }
            let sourceRate = sourceBasic.mSampleRate
            for format in formats {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      (1...2).contains(basic.mChannelsPerFrame), basic.mSampleRate.isFinite,
                      (8_000...96_000).contains(basic.mSampleRate), basic.mSampleRate == sourceRate else { throw Failure.unsupportedMovie }
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
            // Only source-backed timeline intervals require decoded coverage.
            // Empty edit-list segments are genuine silence, not decoder output.
            let segments = try await tracks[0].load(.segments)
            guard segments.count <= 4096 else { throw Failure.unsupportedMovie }
            let sourceFrames = Int((sourceRange.duration.seconds * sourceRate).rounded())
            let requiredRanges: [Range<Int>] = segments.filter { !$0.isEmpty }.compactMap { segment in
                let region = CMTimeRangeGetIntersection(sourceRange, otherRange: segment.timeMapping.target)
                guard region.duration.isNumeric, region.duration > .zero else { return nil }
                let first = max(0, Int(((region.start.seconds - mapping.sourceStartSeconds) * sourceRate).rounded()))
                let last = min(sourceFrames, Int(((CMTimeRangeGetEnd(region).seconds - mapping.sourceStartSeconds) * sourceRate).rounded()))
                return first < last ? first..<last : nil
            }
            guard !requiredRanges.isEmpty else { throw Failure.noAudio }
            func requiresAudio(_ gap: Range<Int>) -> Bool {
                requiredRanges.contains { $0.overlaps(gap) }
            }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Self.diagnosticDecodeFailure(line: #line) }
            // Empty portions are the movie's actual timeline gaps. Audio starts
            // at its original offset inside the selected interval, not at zero.
            try track.insertTimeRange(overlap, of: tracks[0], at: CMTimeSubtract(overlap.start, sourceRange.start))
            if composition.duration < sourceRange.duration {
                composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration,
                    duration: CMTimeSubtract(sourceRange.duration, composition.duration)))
            }
            // Read native-rate PCM first. AVAssetReader's rate conversion and
            // time-stretch paths can finish without delivering their final samples.
            // A separate streaming converter receives an explicit endOfStream to
            // flush those samples; its output is interpreted at 44.1 kHz to apply
            // the requested varispeed and pitch change.
            let decodeRate = Double(rate) / mapping.speed
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sourceRate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            reader.timeRange = CMTimeRange(start: .zero, duration: sourceRange.duration)
            guard reader.canAdd(output) else { throw Self.diagnosticDecodeFailure(line: #line) }
            reader.add(output)
            return try await withTaskCancellationHandler {
                guard reader.startReading() else { throw Self.diagnosticDecodeFailure(line: #line) }
                defer { if reader.status == .reading { reader.cancelReading() } }
                guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sourceRate, channels: 2, interleaved: true),
                      let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: decodeRate, channels: 2, interleaved: true),
                      let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                      let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else {
                    throw Self.diagnosticDecodeFailure(line: #line)
                }
                var pcm = Data(count: outputFrames * bytesPerFrame)
                var sourceCursor = 0, decodedEnd = 0, written = 0
                var pending: (block: CMBlockBuffer, start: Int, frames: Int)?
                var readerDone = false
                var callbackError: Error?
                // Reader chunks and converter buffers are bounded independently
                // of source duration. Only the final <=16MB PCM is retained.
                func loadChunk() throws {
                    try checkpoint()
                    guard !readerDone, pending == nil else { return }
                    guard let sample = output.copyNextSampleBuffer() else {
                        guard reader.status == .completed else { throw Self.diagnosticDecodeFailure(line: #line) }
                        readerDone = true
                        return
                    }
                    let frames = CMSampleBufferGetNumSamples(sample)
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard frames > 0, frames <= 65_536, time.isNumeric, time.seconds.isFinite,
                          time.seconds >= 0, time.seconds <= sourceRange.duration.seconds,
                          let format = CMSampleBufferGetFormatDescription(sample),
                          let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                          basic.mFormatID == kAudioFormatLinearPCM, abs(basic.mSampleRate - sourceRate) < 0.000001,
                          basic.mChannelsPerFrame == 2, basic.mBitsPerChannel == 16, basic.mBytesPerFrame == bytesPerFrame,
                          basic.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                          basic.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
                          let block = CMSampleBufferGetDataBuffer(sample),
                          CMBlockBufferGetDataLength(block) == frames * bytesPerFrame else { throw Self.diagnosticDecodeFailure(line: #line) }
                    let start = Int((time.seconds * sourceRate).rounded())
                    guard start >= decodedEnd, start < sourceFrames else { throw Self.diagnosticDecodeFailure(line: #line) }
                    decodedEnd = start + frames
                    pending = (block, start, frames)
                }
                var stalled = 0
                while true {
                    try checkpoint()
                    let previousCursor = sourceCursor
                    converted.frameLength = 0
                    var conversionError: NSError?
                    let status = converter.convert(to: converted, error: &conversionError) { requested, inputStatus in
                        do {
                            try checkpoint()
                            if sourceCursor == sourceFrames {
                                // The final reader buffer can include a rounding
                                // sample beyond the chosen range; never save it.
                                pending = nil
                                try loadChunk()
                                guard readerDone else { throw Self.diagnosticDecodeFailure(line: #line) }
                                inputStatus.pointee = .endOfStream
                                return nil
                            }
                            let count = min(Int(requested), 8192, sourceFrames - sourceCursor)
                            guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
                                throw Self.diagnosticDecodeFailure(line: #line)
                            }
                            buffer.frameLength = AVAudioFrameCount(count)
                            let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData!
                            var filled = 0
                            while filled < count {
                                try loadChunk()
                                if let chunk = pending, chunk.start <= sourceCursor {
                                    let offset = sourceCursor - chunk.start
                                    let available = min(count - filled, chunk.frames - offset)
                                    guard available > 0, CMBlockBufferCopyDataBytes(chunk.block, atOffset: offset * bytesPerFrame,
                                        dataLength: available * bytesPerFrame, destination: destination.advanced(by: filled * bytesPerFrame)) == noErr else {
                                        throw Self.diagnosticDecodeFailure(line: #line)
                                    }
                                    filled += available; sourceCursor += available
                                    if offset + available == chunk.frames { pending = nil }
                                } else {
                                    let gapEnd = min(sourceCursor + count - filled, pending?.start ?? sourceFrames)
                                    guard gapEnd > sourceCursor, !requiresAudio(sourceCursor..<gapEnd) else {
                                        throw Self.diagnosticDecodeFailure(line: #line)
                                    }
                                    let silent = gapEnd - sourceCursor
                                    memset(destination.advanced(by: filled * bytesPerFrame), 0, silent * bytesPerFrame)
                                    filled += silent; sourceCursor = gapEnd
                                }
                            }
                            inputStatus.pointee = .haveData
                            return buffer
                        } catch {
                            callbackError = error
                            inputStatus.pointee = .endOfStream
                            return nil
                        }
                    }
                    if let callbackError { throw callbackError }
                    guard status != .error, conversionError == nil else { throw Self.diagnosticDecodeFailure(line: #line) }
                    let count = min(Int(converted.frameLength), outputFrames - written)
                    if count > 0 {
                        let source = converted.audioBufferList.pointee.mBuffers.mData!
                        pcm.withUnsafeMutableBytes { bytes in
                            memcpy(bytes.baseAddress!.advanced(by: written * bytesPerFrame), source, count * bytesPerFrame)
                        }
                        written += count
                        try await progress(.init(phase: .decoding, completed: Int64(written), total: Int64(outputFrames)))
                    }
                    try checkpoint()
                    if status == .endOfStream { break }
                    stalled = previousCursor == sourceCursor && converted.frameLength == 0 ? stalled + 1 : 0
                    guard stalled < 8 else { throw Self.diagnosticDecodeFailure(line: #line) }
                    await Task.yield()
                }
#if SDI_MOVIE_AUDIO_DIAGNOSTICS
                print("MOVIE_AUDIO terminal reader=\(reader.status.rawValue) source=\(sourceCursor)/\(sourceFrames) output=\(written)/\(outputFrames)")
#endif
                guard readerDone, reader.status == .completed, sourceCursor == sourceFrames, written == outputFrames else {
                    throw Self.diagnosticDecodeFailure(line: #line)
                }
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
