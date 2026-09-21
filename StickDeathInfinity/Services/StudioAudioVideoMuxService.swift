import Foundation
import AVFoundation
import CryptoKit
import Darwin

/// A same-capture media foundation. It has no arbitrary input-URL API and never
/// clears canonical audio, changes a revision, normalizes overload, or shares.
@MainActor final class StudioAudioVideoMuxService {
    struct Limits {
        var maximumOutputBytes = 80 * 1024 * 1024
        var operationTimeout = 120.0
        var readinessTimeout = 10.0
    }
    enum Phase { case writing, finalizing, verifying, publishing }
    struct Progress { let phase: Phase; let videoFrames: Int; let audioSamples: Int }
    struct Receipt: Codable {
        let version: Int
        let captureProof: StudioMuxCapture.Proof
        let videoCodec: String
        let audioCodec: String
        let audioSampleRate: Int
        let audioChannels: Int
        let width: Int
        let height: Int
        let videoFrames: Int
        let decodedAudioFrames: Int
        let durationNumerator: Int
        let durationDenominator: Int
        let encodedBytes: Int
        let sha256: String
        let sourceVideoSHA256: String
        let sourceAudioSHA256: String
        let maximumDecodedAudioSample: Float
    }
    @MainActor final class AudioComponent {
        let capture: StudioMuxCapture
        private let output: StudioAudioMixService.Output
        fileprivate init(capture: StudioMuxCapture, output: StudioAudioMixService.Output) { self.capture = capture; self.output = output }
        func checkedSource() throws -> (URL, StudioAudioMixService.Receipt) { (try output.checkedURL(), output.receipt) }
        func cleanup() throws { try output.cleanup() }
    }
    @MainActor struct Output {
        let receipt: Receipt
        private let owner: StudioMuxOutputOwnership
        let directory: URL
        fileprivate init(receipt: Receipt, owner: StudioMuxOutputOwnership, directory: URL) { self.receipt = receipt; self.owner = owner; self.directory = directory }
        func checkedURLs() throws -> [URL] {
            try owner.validateForUse()
            return [directory.appendingPathComponent("animation.mp4"), directory.appendingPathComponent("manifest.json")]
        }
        func cleanup() throws { try owner.cleanup() }
    }
    @MainActor final class Recovery {
        private let encoding: StudioMuxEncodingOwnership?
        private let published: StudioMuxOutputOwnership?
        let directory: URL
        fileprivate init(directory: URL, encoding: StudioMuxEncodingOwnership?, published: StudioMuxOutputOwnership?) {
            self.directory = directory; self.encoding = encoding; self.published = published
        }
        func cleanup() async throws {
            if let published { try published.cleanup() }
            else if let encoding { try await encoding.cleanupAfterWriterRelease() }
            else { throw MuxError.cleanupFailed(directory) }
        }
    }
    struct Failure: Error { let underlying: Error; let recovery: Recovery }
    enum MuxError: Error {
        case mismatchedCapture, unsupportedSource, overload, limitExceeded, busy
        case timing(String)
        case writerFailed, verificationFailed, outputUnavailable, unsafeDestination, cleanupFailed(URL)
    }
    private let limits: Limits
    private static var active = false
    init(limits: Limits = Limits()) { self.limits = limits }

    func mixAudioComponent(capture: StudioMuxCapture, outputParent: URL,
                           progress: @Sendable (StudioAudioMixService.Progress) async throws -> Void = { _ in }) async throws -> AudioComponent {
        let proof = capture.proof
        let output = try await StudioAudioMixService().mix(document: capture.snapshot.document,
            retainedAudioTracks: capture.snapshot.retainedAudioTracks,
            durationSeconds: Double(proof.audioSampleFrames) / 48_000, outputParent: outputParent, progress: progress)
        return AudioComponent(capture: capture, output: output)
    }

    func mux(video: StudioMovieExportService.VisualComponent, audio: AudioComponent, outputParent: URL,
             progress: (Progress) throws -> Void = { _ in }) async throws -> Output {
        try Task.checkCancellation()
        guard video.capture === audio.capture, video.capture.proof == audio.capture.proof else { throw MuxError.mismatchedCapture }
        guard !Self.active else { throw MuxError.busy }; Self.active = true; defer { Self.active = false }
        let hard = Limits()
        guard (1...hard.maximumOutputBytes).contains(limits.maximumOutputBytes),
              limits.operationTimeout.isFinite, limits.operationTimeout > 0, limits.operationTimeout <= hard.operationTimeout,
              limits.readinessTimeout.isFinite, limits.readinessTimeout > 0, limits.readinessTimeout <= hard.readinessTimeout else { throw MuxError.limitExceeded }
        let started = ProcessInfo.processInfo.systemUptime, proof = video.capture.proof
        let duration = CMTime(value: Int64(proof.durationNumerator), timescale: CMTimeScale(proof.durationDenominator))
        let (videoURL, vm) = try video.checkedSource(); let (audioURL, am) = try audio.checkedSource()
        guard vm.visualComponentProof == proof, vm.projectID == proof.projectID, vm.documentRevision == proof.revision,
              vm.frameIDs == proof.frameIDs, vm.width == proof.width, vm.height == proof.height, !vm.audioIncluded,
              vm.durationNumerator == proof.durationNumerator, vm.durationDenominator == proof.durationDenominator,
              am.projectID == proof.projectID, am.revision == proof.revision, am.frameCount == proof.audioSampleFrames,
              am.sampleRate == 48_000, am.channels == 2,
              am.clipCount == video.capture.snapshot.document.audioClips.count,
              am.assetCount == video.capture.snapshot.retainedAudioTracks.count else { throw MuxError.mismatchedCapture }
        guard am.overRangeSampleCount == 0, am.peakAbsoluteSample.isFinite, am.peakAbsoluteSample <= 1 else { throw MuxError.overload }
        let sourceVideoHash = try fingerprint(videoURL, maximum: 64 * 1024 * 1024, started: started)
        let vAsset = AVURLAsset(url: videoURL), aAsset = AVURLAsset(url: audioURL)
        let vTracks = try await vAsset.loadTracks(withMediaType: .video), aTracks = try await aAsset.loadTracks(withMediaType: .audio)
        guard vTracks.count == 1, aTracks.count == 1, try await vAsset.loadTracks(withMediaType: .audio).isEmpty,
              try await aAsset.loadTracks(withMediaType: .video).isEmpty else { throw MuxError.unsupportedSource }
        let vt = vTracks[0], at = aTracks[0]
        let vFormats = try await vt.load(.formatDescriptions), aFormats = try await at.load(.formatDescriptions)
        guard vFormats.count == 1, aFormats.count == 1, CMFormatDescriptionGetMediaSubType(vFormats[0]) == kCMVideoCodecType_H264,
              CMFormatDescriptionGetMediaSubType(aFormats[0]) == kAudioFormatLinearPCM,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(aFormats[0]),
              asbd.pointee.mSampleRate == 48_000, asbd.pointee.mChannelsPerFrame == 2 else { throw MuxError.unsupportedSource }
        let size = try await vt.load(.naturalSize), transform = try await vt.load(.preferredTransform)
        guard size.width == CGFloat(proof.width), size.height == CGFloat(proof.height), transform == .identity,
              CMTimeCompare(try await vAsset.load(.duration), duration) == 0,
              CMTimeCompare(try await aAsset.load(.duration), CMTime(value: Int64(proof.audioSampleFrames), timescale: 48_000)) == 0 else { throw MuxError.timing("source duration or transform") }
        _ = try video.checkedSource(); _ = try audio.checkedSource(); try checkpoint(started)
        guard outputParent.isFileURL else { throw MuxError.unsafeDestination }
        let parent = outputParent.standardizedFileURL
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw MuxError.unsafeDestination }
        let staging = parent.appendingPathComponent(".sdi-mux-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var encoding: StudioMuxEncodingOwnership?, owned: StudioMuxOutputOwnership?, writer: AVAssetWriter?
        var videoReader: AVAssetReader?, audioReader: AVAssetReader?
        do {
            encoding = try StudioMuxEncodingOwnership(parent: parent, staging: staging)
            let movie = staging.appendingPathComponent("animation.mp4")
            writer = try AVAssetWriter(outputURL: movie, fileType: .mp4)
            writer!.movieTimeScale = 48_000
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormats[0])
            // Match the canonical encoder's exact per-frame clock. Apple's
            // default 600-tick video track rounds rates such as 7 and 59 fps.
            vi.mediaTimeScale = CMTimeScale(proof.durationDenominator * 600)
            vi.expectsMediaDataInRealTime = false; vi.transform = transform
            let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            guard writer!.canApply(outputSettings: audioSettings, forMediaType: .audio) else { throw MuxError.unsupportedSource }
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: aFormats[0])
            ai.expectsMediaDataInRealTime = false
            guard writer!.canAdd(vi), writer!.canAdd(ai) else { throw MuxError.unsupportedSource }
            writer!.add(vi); writer!.add(ai)
            videoReader = try AVAssetReader(asset: vAsset); audioReader = try AVAssetReader(asset: aAsset)
            let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: nil); vo.alwaysCopiesSampleData = false
            let ao = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]); ao.alwaysCopiesSampleData = false
            guard videoReader!.canAdd(vo), audioReader!.canAdd(ao) else { throw MuxError.unsupportedSource }
            videoReader!.add(vo); audioReader!.add(ao)
            guard writer!.startWriting() else { throw MuxError.writerFailed }
            try encoding!.captureStartedMovie(); writer!.startSession(atSourceTime: .zero)
            guard videoReader!.startReading(), audioReader!.startReading() else { throw MuxError.unsupportedSource }
            var vDone = false, aDone = false, frames = 0, audioFrames = 0, videoMarkers = 0
            var sourceVideoPCM = SHA256(), stalled = ProcessInfo.processInfo.systemUptime
            while !vDone || !aDone {
                try checkpoint(started); try encoding!.validateKnownFiles(); try checkSize(movie)
                var advanced = false
                if !vDone && vi.isReadyForMoreMediaData {
                    if let sample = vo.copyNextSampleBuffer() {
                        if CMSampleBufferGetNumSamples(sample) == 0 {
                            try validateEmptyMarker(sample, count: &videoMarkers)
                        } else {
                        guard frames < proof.frameIDs.count, CMSampleBufferGetNumSamples(sample) == 1,
                              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(frames), timescale: CMTimeScale(proof.durationDenominator))) == 0,
                              CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: 1, timescale: CMTimeScale(proof.durationDenominator))) == 0 else { throw MuxError.timing("source video sample timing") }
                        try updateDigest(sample, digest: &sourceVideoPCM)
                        guard vi.append(sample) else { throw MuxError.writerFailed }; frames += 1
                        }
                    } else { vDone = true; vi.markAsFinished() }
                    advanced = true
                }
                if !aDone && ai.isReadyForMoreMediaData {
                    if let sample = ao.copyNextSampleBuffer() {
                        let count = CMSampleBufferGetNumSamples(sample)
                        guard count > 0, count <= 65_536, count <= proof.audioSampleFrames - audioFrames,
                              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(audioFrames), timescale: 48_000)) == 0 else { throw MuxError.timing("source audio sample timing") }
                        guard ai.append(sample) else { throw MuxError.writerFailed }; audioFrames += count
                    } else { aDone = true; ai.markAsFinished() }
                    advanced = true
                }
                if advanced {
                    stalled = ProcessInfo.processInfo.systemUptime
                    try progress(.init(phase: .writing, videoFrames: frames, audioSamples: audioFrames))
                    try encoding!.validateKnownFiles()
                } else {
                    guard writer!.status == .writing, ProcessInfo.processInfo.systemUptime - stalled <= limits.readinessTimeout else { throw MuxError.writerFailed }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                await Task.yield()
            }
            guard videoReader!.status == .completed, audioReader!.status == .completed,
                  frames == proof.frameIDs.count, audioFrames == proof.audioSampleFrames else { throw MuxError.timing("source reader completion") }
            writer!.endSession(atSourceTime: duration)
            try progress(.init(phase: .finalizing, videoFrames: frames, audioSamples: audioFrames))
            try encoding!.validateKnownFiles()
            _ = try video.checkedSource(); _ = try audio.checkedSource(); try checkpoint(started)
            writer!.finishWriting {}
            while writer!.status == .writing { try checkpoint(started); try checkSize(movie); try await Task.sleep(nanoseconds: 5_000_000) }
            guard writer!.status == .completed else { throw MuxError.writerFailed }
            writer = nil; videoReader = nil; audioReader = nil
            try encoding!.validateKnownFiles(); try checkpoint(started)
            // Bind the completed encoder output before exposing a callback.
            // A valid MP4 with different audio must not replace this capture.
            let beforeHash = try fingerprint(movie, maximum: limits.maximumOutputBytes, started: started)
            try progress(.init(phase: .verifying, videoFrames: frames, audioSamples: audioFrames)); try checkpoint(started)
            try encoding!.validateKnownFiles()
            let decoded = try await verify(movie, proof: proof, expectedVideo: sourceVideoPCM.finalize(), started: started)
            _ = try video.checkedSource(); _ = try audio.checkedSource()
            guard try fingerprint(videoURL, maximum: 64 * 1024 * 1024, started: started) == sourceVideoHash else { throw MuxError.outputUnavailable }
            let bytes = try checkSize(movie, nonempty: true)
            let receipt = Receipt(version: 1, captureProof: proof, videoCodec: "H.264 passthrough", audioCodec: "AAC",
                audioSampleRate: 48_000, audioChannels: 2, width: proof.width, height: proof.height,
                videoFrames: frames, decodedAudioFrames: decoded.frames,
                durationNumerator: proof.durationNumerator, durationDenominator: proof.durationDenominator,
                encodedBytes: bytes, sha256: hex(beforeHash), sourceVideoSHA256: hex(sourceVideoHash),
                sourceAudioSHA256: am.sha256, maximumDecodedAudioSample: decoded.peak)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(receipt); try encoding!.writeManifest(data)
            try progress(.init(phase: .publishing, videoFrames: frames, audioSamples: audioFrames)); try checkpoint(started)
            try encoding!.validateKnownFiles()
            _ = try video.checkedSource(); _ = try audio.checkedSource()
            guard try fingerprint(movie, maximum: limits.maximumOutputBytes, started: started) == beforeHash else { throw MuxError.verificationFailed }
            let final = try StudioMuxOutputOwnership(parent: parent, staging: staging, movieDigest: beforeHash, movieBytes: bytes, manifestData: data, original: try encoding!.publicationIdentity())
            owned = final; try final.validateForUse()
            return Output(receipt: receipt, owner: final, directory: staging)
        } catch let original {
            videoReader?.cancelReading(); audioReader?.cancelReading()
            videoReader = nil; audioReader = nil; writer = nil
            do {
                if let owned { try owned.cleanup() }
                else if let encoding { try await encoding.cleanupAfterWriterRelease() }
                else { throw MuxError.cleanupFailed(staging) }
            } catch { throw Failure(underlying: original, recovery: Recovery(directory: staging, encoding: encoding, published: owned)) }
            throw original
        }
    }

    private func checkpoint(_ started: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - started <= limits.operationTimeout else { throw MuxError.limitExceeded }
    }
    @discardableResult private func checkSize(_ url: URL, nonempty: Bool = false) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= (nonempty ? 1 : 0), info.st_size <= limits.maximumOutputBytes else { throw MuxError.limitExceeded }
        return Int(info.st_size)
    }
    private func fingerprint(_ url: URL, maximum: Int, started: TimeInterval) throws -> SHA256.Digest {
        var before = stat(); guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum else { throw MuxError.outputUnavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MuxError.outputUnavailable }; defer { Darwin.close(fd) }
        var opened = stat(); guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else { throw MuxError.outputUnavailable }
        var digest = SHA256(), bytes = [UInt8](repeating: 0, count: 65536), offset = 0
        while offset < before.st_size {
            try checkpoint(started)
            let amount = min(bytes.count, Int(before.st_size) - offset)
            let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, amount, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw MuxError.outputUnavailable }
            digest.update(data: Data(bytes.prefix(count))); offset += count
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              path.st_dev == before.st_dev, path.st_ino == before.st_ino, path.st_size == before.st_size,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec, after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw MuxError.outputUnavailable }
        return digest.finalize()
    }
    private func updateDigest(_ sample: CMSampleBuffer, digest: inout SHA256) throws {
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw MuxError.verificationFailed }
        let count = CMBlockBufferGetDataLength(buffer)
        guard count > 0, count <= 16 * 1024 * 1024 else { throw MuxError.limitExceeded }
        var bytes = [UInt8](repeating: 0, count: count)
        guard bytes.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }) == noErr else { throw MuxError.verificationFailed }
        digest.update(data: Data(bytes))
    }
    private func hex(_ value: SHA256.Digest) -> String { value.map { String(format: "%02x", $0) }.joined() }

    private func validateEmptyMarker(_ sample: CMSampleBuffer, count: inout Int) throws {
        // The actual production H.264 reader emits an initial zero-sample,
        // zero-duration marker. It contains no picture/media bytes to append.
        guard count < 4, CMSampleBufferGetNumSamples(sample) == 0,
              CMTimeCompare(CMSampleBufferGetDuration(sample), .zero) == 0,
              CMSampleBufferGetImageBuffer(sample) == nil,
              CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? 0 == 0 else { throw MuxError.verificationFailed }
        count += 1
    }

    private func verify(_ url: URL, proof: StudioMuxCapture.Proof, expectedVideo: SHA256.Digest,
                        started: TimeInterval) async throws -> (frames: Int, peak: Float) {
        let asset = AVURLAsset(url: url), duration = CMTime(value: Int64(proof.durationNumerator), timescale: CMTimeScale(proof.durationDenominator))
        let video = try await asset.loadTracks(withMediaType: .video), audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count == 1, audio.count == 1, CMTimeCompare(try await asset.load(.duration), duration) == 0,
              try await video[0].load(.naturalSize) == CGSize(width: proof.width, height: proof.height),
              try await video[0].load(.preferredTransform) == .identity else { throw MuxError.verificationFailed }
        let vf = try await video[0].load(.formatDescriptions), af = try await audio[0].load(.formatDescriptions)
        guard vf.count == 1, af.count == 1, CMFormatDescriptionGetMediaSubType(vf[0]) == kCMVideoCodecType_H264,
              CMFormatDescriptionGetMediaSubType(af[0]) == kAudioFormatMPEG4AAC,
              let ab = CMAudioFormatDescriptionGetStreamBasicDescription(af[0]), ab.pointee.mChannelsPerFrame == 2,
              ab.pointee.mSampleRate == 48_000 else { throw MuxError.verificationFailed }
        let timingReader = try AVAssetReader(asset: asset), timing = AVAssetReaderTrackOutput(track: video[0], outputSettings: nil)
        timingReader.add(timing); guard timingReader.startReading() else { throw MuxError.verificationFailed }
        var count = 0, digest = SHA256(), markers = 0
        while let sample = timing.copyNextSampleBuffer() {
            try checkpoint(started)
            if CMSampleBufferGetNumSamples(sample) == 0 { try validateEmptyMarker(sample, count: &markers); continue }
            guard count < proof.frameIDs.count, CMSampleBufferGetNumSamples(sample) == 1,
                  CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(count), timescale: CMTimeScale(proof.durationDenominator))) == 0,
                  CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: 1, timescale: CMTimeScale(proof.durationDenominator))) == 0 else { throw MuxError.verificationFailed }
            try updateDigest(sample, digest: &digest); count += 1; await Task.yield()
        }
        guard timingReader.status == .completed, count == proof.frameIDs.count, digest.finalize() == expectedVideo else { throw MuxError.verificationFailed }
        let reader = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: video[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(vo); guard reader.startReading() else { throw MuxError.verificationFailed }; count = 0; markers = 0
        while let sample = vo.copyNextSampleBuffer() {
            try checkpoint(started)
            if CMSampleBufferGetNumSamples(sample) == 0 { try validateEmptyMarker(sample, count: &markers); continue }
            guard let pixel = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(pixel) == proof.width,
                  CVPixelBufferGetHeight(pixel) == proof.height, count < proof.frameIDs.count else { throw MuxError.verificationFailed }
            count += 1; await Task.yield()
        }
        guard reader.status == .completed, count == proof.frameIDs.count else { throw MuxError.verificationFailed }
        let ar = try AVAssetReader(asset: asset)
        let ao = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        ar.add(ao); guard ar.startReading() else { throw MuxError.verificationFailed }
        var audioFrames = 0, peak: Float = 0
        while let sample = ao.copyNextSampleBuffer() {
            try checkpoint(started)
            let n = CMSampleBufferGetNumSamples(sample)
            guard n > 0, n <= 65_536, n <= proof.audioSampleFrames - audioFrames,
                  CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(audioFrames), timescale: 48_000)) == 0,
                  let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) == n * 8 else { throw MuxError.verificationFailed }
            var values = [Float](repeating: 0, count: n * 2)
            guard values.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 8, destination: $0.baseAddress!) }) == noErr else { throw MuxError.verificationFailed }
            for value in values { guard value.isFinite else { throw MuxError.verificationFailed }; peak = max(peak, abs(value)) }
            audioFrames += n; await Task.yield()
        }
        guard ar.status == .completed, audioFrames == proof.audioSampleFrames else { throw MuxError.verificationFailed }
        guard peak <= 1 else { throw MuxError.overload }
        return (audioFrames, peak)
    }
}
