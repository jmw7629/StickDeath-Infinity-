import Foundation
import AudioToolbox
import CryptoKit
import Darwin

/// Offline foundation only. No playback, microphone, source-file URLs, or muxing.
/// Clip start/end round to the nearest 48 kHz frame (at most half a sample).
/// Output duration must be sample-aligned and contain every whole clip. Each
/// clip reads its canonical sourceOffset; muted clips contribute zero gain.
/// Track numbers identify additive lanes. No limiter or normalization is applied.
actor StudioAudioMixService {
    static let sampleRate = 48_000.0
    static let channels = 2
    struct Limits: Sendable {
        var maximumDuration = 120.0
        var maximumClips = 128
        var maximumAssets = 16
        var maximumEncodedBytes = 64 * 1024 * 1024
        var maximumDecodedSamples = 12_000_000
        var maximumMixedSamples = 48_000_000
        var maximumOutputBytes = 48 * 1024 * 1024
    }
    struct Progress: Sendable {
        enum Phase: Sendable { case decoding, mixing, validating }
        let phase: Phase
        let completed: Int
        let total: Int
    }
    struct Receipt: Sendable {
        let projectID: UUID
        let revision: Int
        let frameCount: Int
        let sampleRate: Double
        let channels: Int
        let clipCount: Int
        let assetCount: Int
        let peakAbsoluteSample: Float
        /// Float CAF preserves these values; it is not playback-safe limiting.
        let overRangeSampleCount: Int
        let bytes: Int
        let sha256: String
        var duration: Double { Double(frameCount) / sampleRate }
    }
    final class Output: @unchecked Sendable {
        let receipt: Receipt
        private let owner: MixOwnedFile
        fileprivate init(receipt: Receipt, owner: MixOwnedFile) { self.receipt = receipt; self.owner = owner }
        /// Call immediately before handoff. Consumers must finish before cleanup.
        func checkedURL() throws -> URL {
            let data = try owner.readChecked(maximumBytes: receipt.bytes)
            guard data.count == receipt.bytes, Self.hash(data) == receipt.sha256 else { throw MixError.outputChanged }
            return owner.fileURL
        }
        func cleanup() throws { try owner.cleanup() }
        private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
    /// A conflict preserves unknown/replaced files. Recovery is tied to captured
    /// descriptors, never a caller-supplied path. Restore ownership then retry.
    struct Failure: Error, LocalizedError {
        let underlying: Error
        let recovery: Recovery
        var errorDescription: String? { "Audio mixing failed and temporary output needs recovery: \(underlying.localizedDescription)" }
    }
    final class Recovery: @unchecked Sendable {
        private let owner: MixOwnedFile
        fileprivate init(_ owner: MixOwnedFile) { self.owner = owner }
        var directory: URL { owner.directoryURL }
        func cleanup() throws { try owner.cleanup() }
    }
    enum MixError: Error, LocalizedError {
        case invalidTimeline, invalidAsset, unresolvedLegacyAudio, missingAsset, unsupportedAudio
        case resourceLimit, invalidSamples, codecFailure, storageFailure, ownershipConflict, outputChanged, busy
        var errorDescription: String? {
            switch self {
            case .invalidTimeline: return "Audio timing must be finite, sample-aligned and fully contained in the requested mix."
            case .invalidAsset: return "An audio asset has invalid or inconsistent metadata or bytes."
            case .unresolvedLegacyAudio: return "Resolve legacy or unused audio assets before mixing this snapshot."
            case .missingAsset: return "An audio clip has no matching saved asset."
            case .unsupportedAudio: return "This audio format or channel layout is not supported by the mixer."
            case .resourceLimit: return "This mix exceeds its bounded duration, memory or processing limits."
            case .invalidSamples: return "The audio decoder returned incomplete or invalid samples."
            case .codecFailure: return "Apple audio decoding or encoding failed."
            case .storageFailure: return "The audio output could not be written."
            case .ownershipConflict: return "Audio output ownership changed; unknown files have been preserved."
            case .outputChanged: return "The rendered audio was changed or removed."
            case .busy: return "Another offline audio mix is still running."
            }
        }
    }

    func mix(document: StudioDocument, retainedAudioTracks: [AudioTrack], durationSeconds: Double,
             outputParent: URL = FileManager.default.temporaryDirectory, limits: Limits = .init(),
             progress: @Sendable (Progress) async throws -> Void = { _ in }) async throws -> Output {
        try Task.checkCancellation()
        try await MixLease.shared.acquire()
        do {
            let result = try await perform(document: document, tracks: retainedAudioTracks,
                                           duration: durationSeconds, parent: outputParent, limits: limits, progress: progress)
            await MixLease.shared.release()
            return result
        } catch { await MixLease.shared.release(); throw error }
    }

    private struct Clip {
        let assetID: UUID
        let start: Int
        let end: Int
        let sourceStart: Int
        let volume: Float
    }
    private func perform(document: StudioDocument, tracks: [AudioTrack], duration: Double,
                         parent: URL, limits: Limits,
                         progress: @Sendable (Progress) async throws -> Void) async throws -> Output {
        let hard = Limits()
        guard limits.maximumDuration.isFinite, limits.maximumDuration > 0, limits.maximumDuration <= hard.maximumDuration,
              (1...hard.maximumClips).contains(limits.maximumClips), (1...hard.maximumAssets).contains(limits.maximumAssets),
              (1...hard.maximumEncodedBytes).contains(limits.maximumEncodedBytes),
              (1...hard.maximumDecodedSamples).contains(limits.maximumDecodedSamples),
              (1...hard.maximumMixedSamples).contains(limits.maximumMixedSamples),
              (1...hard.maximumOutputBytes).contains(limits.maximumOutputBytes) else { throw MixError.resourceLimit }
        try document.validate()
        guard duration.isFinite, duration > 0, duration <= limits.maximumDuration else { throw MixError.invalidTimeline }
        let framesValue = duration * Self.sampleRate
        guard abs(framesValue - framesValue.rounded()) < 0.000001 else { throw MixError.invalidTimeline }
        let totalFrames = Int(framesValue.rounded())
        guard totalFrames > 0, totalFrames <= (limits.maximumOutputBytes - 4096) / 8,
              document.audioClips.count <= limits.maximumClips, tracks.count <= limits.maximumAssets else { throw MixError.resourceLimit }
        var trackMap: [UUID: AudioTrack] = [:], bytes = 0
        for track in tracks {
            guard track.legacySourceFilename == nil, track.startTime == 0 else { throw MixError.unresolvedLegacyAudio }
            guard trackMap[track.id] == nil, !track.name.isEmpty, track.name.count <= 120,
                  track.duration.isFinite, track.duration > 0, track.duration <= 300,
                  let data = track.audioData, !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw MixError.invalidAsset }
            guard data.count <= limits.maximumEncodedBytes - bytes else { throw MixError.resourceLimit }
            bytes += data.count; trackMap[track.id] = track
        }
        var clips: [Clip] = [], work = 0
        for clip in document.audioClips {
            guard let id = clip.assetID else { throw MixError.unresolvedLegacyAudio }
            guard trackMap[id] != nil else { throw MixError.missingAsset }
            guard clip.duration > 0, clip.startTime + clip.duration <= duration + 0.000000001,
                  (1...4).contains(clip.track) else { throw MixError.invalidTimeline }
            let start = Int((clip.startTime * Self.sampleRate).rounded()), end = Int(((clip.startTime + clip.duration) * Self.sampleRate).rounded())
            guard start >= 0, end > start, end <= totalFrames else { throw MixError.invalidTimeline }
            let samples = (end - start) * 2
            guard samples <= limits.maximumMixedSamples - work else { throw MixError.resourceLimit }
            let sourceStart = Int((clip.sourceOffset * Self.sampleRate).rounded())
            guard sourceStart >= 0, clip.sourceOffset + clip.duration <= trackMap[id]!.duration + 1 / Self.sampleRate else {
                throw MixError.invalidTimeline
            }
            work += samples
            clips.append(.init(assetID: id, start: start, end: end, sourceStart: sourceStart,
                               volume: clip.isMuted ? 0 : Float(clip.volume)))
        }
        guard Set(clips.map(\.assetID)) == Set(trackMap.keys) else { throw MixError.unresolvedLegacyAudio }
        // Sort UUIDs for deterministic decode/progress ordering; clip summation
        // order is the canonical array order, including overlaps on one lane.
        var assets: [UUID: [Float]] = [:], decodedSamples = 0
        for id in trackMap.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let asset = try await decode(trackMap[id]!, remainingSamples: limits.maximumDecodedSamples - decodedSamples,
                                         completedBefore: decodedSamples, progress: progress)
            decodedSamples += asset.count; assets[id] = asset
        }
        for clip in clips {
            guard clip.sourceStart + clip.end - clip.start <= assets[clip.assetID]!.count / 2 else { throw MixError.invalidTimeline }
        }
        try Task.checkCancellation()
        let owner = try MixOwnedFile(parent: parent)
        do {
            let writer = try MixCAFWriter(owner: owner, maximumBytes: limits.maximumOutputBytes)
            var peak: Float = 0, overRange = 0, offset = 0
            var expectedPCM = SHA256()
            do {
                while offset < totalFrames {
                    try Task.checkCancellation(); try owner.check()
                    let count = min(4096, totalFrames - offset)
                    var buffer = [Float](repeating: 0, count: count * 2)
                    for clip in clips {
                        let first = max(offset, clip.start), end = min(offset + count, clip.end)
                        if first >= end { continue }
                        let source = assets[clip.assetID]!
                        for frame in first..<end {
                            let src = (clip.sourceStart + frame - clip.start) * 2, dst = (frame - offset) * 2
                            buffer[dst] += source[src] * clip.volume
                            buffer[dst + 1] += source[src + 1] * clip.volume
                        }
                    }
                    for sample in buffer {
                        guard sample.isFinite else { throw MixError.invalidSamples }
                        peak = max(peak, abs(sample)); if abs(sample) > 1 { overRange += 1 }
                    }
                    buffer.withUnsafeBytes { expectedPCM.update(bufferPointer: $0) }
                    try writer.write(buffer, frames: count)
                    offset += count
                    try await progress(.init(phase: .mixing, completed: offset, total: totalFrames))
                    await Task.yield()
                }
                try writer.finish()
            } catch { writer.close(); throw error }
            try Task.checkCancellation(); try owner.check()
            try await progress(.init(phase: .validating, completed: 0, total: totalFrames))
            try Task.checkCancellation()
            var data = try owner.readChecked(maximumBytes: limits.maximumOutputBytes)
            // Reopen the actual generated container via Apple's decoder and
            // verify every sample, frame count and exact reported over-range.
            try await verifyOutput(data, frames: totalFrames, expectedPeak: peak, expectedOverRange: overRange,
                                   expectedPCM: expectedPCM.finalize(), progress: progress)
            try Task.checkCancellation(); try owner.check()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let byteCount = data.count
            // Validation yields between decoded chunks. Recheck the actual file
            // before returning a ready receipt, and release the first container
            // buffer before that bounded reread. No suspension follows the check.
            data = Data()
            let output = Output(receipt: .init(projectID: document.id, revision: document.revision, frameCount: totalFrames,
                                         sampleRate: Self.sampleRate, channels: 2, clipCount: clips.count, assetCount: assets.count,
                                         peakAbsoluteSample: peak, overRangeSampleCount: overRange, bytes: byteCount, sha256: digest), owner: owner)
            _ = try output.checkedURL()
            return output
        } catch let original {
            do { try owner.cleanup() }
            catch { throw Failure(underlying: original, recovery: Recovery(owner)) }
            throw original
        }
    }

    private func decode(_ track: AudioTrack, remainingSamples: Int, completedBefore: Int,
                        progress: @Sendable (Progress) async throws -> Void) async throws -> [Float] {
        let reader = try MixAudioReader(data: track.audioData!)
        guard reader.container == track.format.lowercased() else { throw MixError.invalidAsset }
        guard (8000...96000).contains(reader.originalRate), (1...2).contains(reader.originalChannels),
              reader.originalFrames > 0 else { throw MixError.unsupportedAudio }
        let duration = Double(reader.originalFrames) / reader.originalRate
        guard duration <= 300, abs(duration - track.duration) <= 1 / reader.originalRate + 0.000000001 else { throw MixError.invalidAsset }
        let expectedFrames = Int((duration * Self.sampleRate).rounded())
        guard expectedFrames > 0, expectedFrames <= remainingSamples / 2 else { throw MixError.resourceLimit }
        var result: [Float] = []; result.reserveCapacity(expectedFrames * 2)
        while true {
            try Task.checkCancellation()
            let chunk = try reader.read(frames: 4096)
            if chunk.isEmpty { break }
            guard chunk.count <= remainingSamples - result.count, chunk.count <= expectedFrames * 2 - result.count else { throw MixError.invalidSamples }
            guard chunk.allSatisfy(\.isFinite) else { throw MixError.invalidSamples }
            result.append(contentsOf: chunk)
            try await progress(.init(phase: .decoding, completed: completedBefore + result.count, total: completedBefore + expectedFrames * 2))
            await Task.yield()
        }
        guard result.count == expectedFrames * 2 else { throw MixError.invalidSamples }
        return result
    }
    private func verifyOutput(_ data: Data, frames: Int, expectedPeak: Float, expectedOverRange: Int,
                              expectedPCM: SHA256.Digest,
                              progress: @Sendable (Progress) async throws -> Void) async throws {
        let reader = try MixAudioReader(data: data)
        guard reader.container == "caf", reader.originalRate == Self.sampleRate,
              reader.originalChannels == 2, reader.originalFrames == frames else { throw MixError.outputChanged }
        var count = 0, peak: Float = 0, over = 0
        var actualPCM = SHA256()
        while true {
            try Task.checkCancellation(); let values = try reader.read(frames: 4096)
            if values.isEmpty { break }
            guard values.count <= frames * 2 - count else { throw MixError.outputChanged }
            for value in values { guard value.isFinite else { throw MixError.outputChanged }; peak = max(peak, abs(value)); if abs(value) > 1 { over += 1 } }
            values.withUnsafeBytes { actualPCM.update(bufferPointer: $0) }
            count += values.count
            try await progress(.init(phase: .validating, completed: count / 2, total: frames))
            await Task.yield()
        }
        guard count == frames * 2, peak == expectedPeak, over == expectedOverRange,
              actualPCM.finalize() == expectedPCM else { throw MixError.outputChanged }
    }
}

private actor MixLease {
    static let shared = MixLease()
    var active = false
    func acquire() throws { guard !active else { throw StudioAudioMixService.MixError.busy }; active = true }
    func release() { active = false }
}

private func mixPCMFormat() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
}

/// Core Audio owns no input URL. Strong `memory` outlives both wrapped handles;
/// callback contexts are borrowed only during these synchronous Apple calls.
private final class MixAudioMemory {
    let data: Data
    init(_ data: Data) { self.data = data }
}
private final class MixAudioReader {
    private let memory: MixAudioMemory
    private var file: AudioFileID?
    private var extended: ExtAudioFileRef?
    let originalRate: Double
    let originalChannels: Int
    let originalFrames: Int64
    let container: String
    init(data: Data) throws {
        memory = MixAudioMemory(data)
        // Recoverable truncated RIFF/FORM must not become a shorter valid mix.
        let signature = String(decoding: data.prefix(4), as: UTF8.self)
        if ["RIFF", "RIFX", "FORM"].contains(signature) {
            guard data.count >= 12 else { throw StudioAudioMixService.MixError.invalidAsset }
            let bytes = [UInt8](data[4..<8]); let le = signature == "RIFF"
            let declared = bytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << UInt64((le ? $1.offset : 3 - $1.offset) * 8)) }
            guard declared + 8 == data.count else { throw StudioAudioMixService.MixError.invalidAsset }
            var offset = 12, chunks = 0
            while offset < data.count {
                guard data.count - offset >= 8, chunks < 4096 else { throw StudioAudioMixService.MixError.invalidAsset }
                let parts = [UInt8](data[(offset + 4)..<(offset + 8)])
                let length = parts.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << UInt64((le ? $1.offset : 3 - $1.offset) * 8)) }
                guard length <= data.count - offset - 8 else { throw StudioAudioMixService.MixError.invalidAsset }
                let padded = Int(length) + Int(length % 2)
                guard padded <= data.count - offset - 8 else { throw StudioAudioMixService.MixError.invalidAsset }
                offset += 8 + padded; chunks += 1
            }
        } else if signature == "caff" {
            guard data.count >= 8 else { throw StudioAudioMixService.MixError.invalidAsset }
            var offset = 8, chunks = 0
            while offset < data.count {
                guard data.count - offset >= 12, chunks < 4096 else { throw StudioAudioMixService.MixError.invalidAsset }
                let length = data[(offset + 4)..<(offset + 12)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                // Persisted assets must have finalized lengths. Streaming -1
                // data chunks are not accepted as complete offline sources.
                guard length <= data.count - offset - 12 else { throw StudioAudioMixService.MixError.invalidAsset }
                offset += 12 + Int(length); chunks += 1
            }
        }
        var opened: AudioFileID?
        let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(memory).toOpaque(), { context, position, requested, buffer, actual in
            let memory = Unmanaged<MixAudioMemory>.fromOpaque(context).takeUnretainedValue()
            guard position >= 0, position <= memory.data.count else { actual.pointee = 0; return kAudioFilePositionError }
            let count = min(Int(requested), memory.data.count - Int(position)); actual.pointee = UInt32(count)
            if count > 0 { memory.data.withUnsafeBytes { raw in buffer.copyMemory(from: raw.baseAddress!.advanced(by: Int(position)), byteCount: count) } }
            return noErr
        }, nil, { context in Int64(Unmanaged<MixAudioMemory>.fromOpaque(context).takeUnretainedValue().data.count) }, nil, 0, &opened)
        guard status == noErr, let opened else { throw StudioAudioMixService.MixError.codecFailure }
        var ext: ExtAudioFileRef?
        do {
            guard ExtAudioFileWrapAudioFileID(opened, false, &ext) == noErr, let ext else { throw StudioAudioMixService.MixError.codecFailure }
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr else { throw StudioAudioMixService.MixError.codecFailure }
            var frames: Int64 = 0; size = 8
            guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr,
                  format.mSampleRate.isFinite, format.mSampleRate > 0 else { throw StudioAudioMixService.MixError.invalidAsset }
            var type: AudioFileTypeID = 0; size = 4
            guard AudioFileGetProperty(opened, kAudioFilePropertyFileFormat, &size, &type) == noErr else { throw StudioAudioMixService.MixError.codecFailure }
            let kinds: [AudioFileTypeID: String] = [kAudioFileWAVEType: "wav", kAudioFileAIFFType: "aiff", kAudioFileAIFCType: "aifc", kAudioFileCAFType: "caf", kAudioFileM4AType: "m4a", kAudioFileMP3Type: "mp3", kAudioFileAAC_ADTSType: "aac"]
            guard let kind = kinds[type] else { throw StudioAudioMixService.MixError.unsupportedAudio }
            var client = mixPCMFormat(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, size, &client) == noErr else { throw StudioAudioMixService.MixError.unsupportedAudio }
            originalRate = format.mSampleRate; originalChannels = Int(format.mChannelsPerFrame); originalFrames = frames; container = kind
            self.file = opened; self.extended = ext
        } catch { if let ext { ExtAudioFileDispose(ext) }; AudioFileClose(opened); throw error }
    }
    func read(frames: Int) throws -> [Float] {
        guard let extended else { throw StudioAudioMixService.MixError.codecFailure }
        var values = [Float](repeating: 0, count: frames * 2), count = UInt32(frames)
        let status = values.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileRead(extended, &count, &list)
        }
        guard status == noErr, count <= frames else { throw StudioAudioMixService.MixError.codecFailure }
        values.removeLast(values.count - Int(count) * 2); return values
    }
    deinit { if let extended { ExtAudioFileDispose(extended) }; if let file { AudioFileClose(file) } }
}

/// The only writable file is exclusively created and held open before any
/// suspension. Audio File callbacks address this descriptor, never a pathname.
private final class MixOwnedFile: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL
    let fd: Int32
    private let parentURL: URL
    private let parentFD: Int32
    private let directoryFD: Int32
    private let parentIdentity: stat
    private let directoryIdentity: stat
    private let fileIdentity: stat
    private let name: String
    private let lock = NSLock()
    private var fileRemoved = false, directoryRemoved = false

    init(parent: URL) throws {
        guard parent.isFileURL, parent.host == nil || parent.host == "localhost", parent.query == nil, parent.fragment == nil,
              !parent.path.utf8.contains(0) else { throw StudioAudioMixService.MixError.storageFailure }
        var original = stat()
        guard lstat(parent.path, &original) == 0, original.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw StudioAudioMixService.MixError.storageFailure }
        parentURL = parent.resolvingSymlinksInPath().standardizedFileURL
        let pfd = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard pfd >= 0 else { throw StudioAudioMixService.MixError.storageFailure }
        var p = stat()
        guard fstat(pfd, &p) == 0, Self.same(original, p) else { Darwin.close(pfd); throw StudioAudioMixService.MixError.ownershipConflict }
        name = ".sdi-audio-mix-" + UUID().uuidString
        directoryURL = parentURL.appendingPathComponent(name, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("mix.caf")
        guard mkdirat(pfd, name, 0o700) == 0 else { Darwin.close(pfd); throw StudioAudioMixService.MixError.storageFailure }
        let dfd = openat(pfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        // If identity could not be captured, preserve the directory rather than
        // deleting a possibly replaced path during initialization failure.
        guard dfd >= 0 else { Darwin.close(pfd); throw StudioAudioMixService.MixError.storageFailure }
        var d = stat()
        guard fstat(dfd, &d) == 0 else { Darwin.close(dfd); Darwin.close(pfd); throw StudioAudioMixService.MixError.storageFailure }
        let f = openat(dfd, "mix.caf", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard f >= 0 else { Darwin.close(dfd); Darwin.close(pfd); throw StudioAudioMixService.MixError.storageFailure }
        var info = stat()
        guard fstat(f, &info) == 0 else { Darwin.close(f); Darwin.close(dfd); Darwin.close(pfd); throw StudioAudioMixService.MixError.storageFailure }
        parentFD = pfd; directoryFD = dfd; fd = f
        parentIdentity = p; directoryIdentity = d; fileIdentity = info
    }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & mode_t(S_IFMT) == b.st_mode & mode_t(S_IFMT) }
    private func directoryEntries() throws -> Set<String> {
        // Opening '.' makes an independent enumeration position for each check.
        let copy = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw StudioAudioMixService.MixError.ownershipConflict }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw StudioAudioMixService.MixError.ownershipConflict }
        defer { closedir(stream) }
        var names = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let value = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) } }
            if value != "." && value != ".." { names.insert(value) }
            guard names.count <= 1 else { throw StudioAudioMixService.MixError.ownershipConflict }
            errno = 0
        }
        guard errno == 0 else { throw StudioAudioMixService.MixError.ownershipConflict }
        return names
    }
    private func checkUnlocked() throws {
        guard !directoryRemoved else { throw StudioAudioMixService.MixError.outputChanged }
        var p = stat(), d = stat(), f = stat()
        guard lstat(parentURL.path, &p) == 0, Self.same(p, parentIdentity),
              fstatat(parentFD, name, &d, AT_SYMLINK_NOFOLLOW) == 0, Self.same(d, directoryIdentity) else { throw StudioAudioMixService.MixError.ownershipConflict }
        let expected: Set<String> = fileRemoved ? [] : ["mix.caf"]
        guard try directoryEntries() == expected else { throw StudioAudioMixService.MixError.ownershipConflict }
        if !fileRemoved {
            guard fstatat(directoryFD, "mix.caf", &f, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.same(f, fileIdentity), f.st_nlink == 1 else { throw StudioAudioMixService.MixError.ownershipConflict }
        }
    }
    func check() throws { lock.lock(); defer { lock.unlock() }; try checkUnlocked() }
    func readChecked(maximumBytes: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }; try checkUnlocked()
        guard !fileRemoved else { throw StudioAudioMixService.MixError.outputChanged }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= maximumBytes else { throw StudioAudioMixService.MixError.outputChanged }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let amount = pread(fd, raw.baseAddress!.advanced(by: offset), min(65536, raw.count - offset), off_t(offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw StudioAudioMixService.MixError.storageFailure }; offset += amount
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw StudioAudioMixService.MixError.outputChanged }
        try checkUnlocked(); return data
    }
    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        if directoryRemoved { return }
        try checkUnlocked()
        if !fileRemoved {
            guard unlinkat(directoryFD, "mix.caf", 0) == 0 else { throw StudioAudioMixService.MixError.storageFailure }
            fileRemoved = true
        }
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw StudioAudioMixService.MixError.ownershipConflict }
        directoryRemoved = true
    }
    deinit { Darwin.close(fd); Darwin.close(directoryFD); Darwin.close(parentFD) }
}

private final class MixWriteContext {
    let owner: MixOwnedFile
    let maximumBytes: Int
    init(_ owner: MixOwnedFile, maximumBytes: Int) { self.owner = owner; self.maximumBytes = maximumBytes }
}
private final class MixCAFWriter {
    private let context: MixWriteContext
    private var file: AudioFileID?
    private var extended: ExtAudioFileRef?
    init(owner: MixOwnedFile, maximumBytes: Int) throws {
        context = MixWriteContext(owner, maximumBytes: maximumBytes)
        var format = mixPCMFormat(), file: AudioFileID?
        let result = AudioFileInitializeWithCallbacks(Unmanaged.passUnretained(context).toOpaque(), { context, pos, requested, buffer, actual in
            let value = Unmanaged<MixWriteContext>.fromOpaque(context).takeUnretainedValue()
            guard pos >= 0, pos <= value.maximumBytes else { actual.pointee = 0; return kAudioFilePositionError }
            var amount: Int
            repeat { amount = pread(value.owner.fd, buffer, Int(requested), off_t(pos)) } while amount < 0 && errno == EINTR
            guard amount >= 0 else { actual.pointee = 0; return kAudioFileUnspecifiedError }; actual.pointee = UInt32(amount); return noErr
        }, { context, pos, requested, buffer, actual in
            let value = Unmanaged<MixWriteContext>.fromOpaque(context).takeUnretainedValue()
            guard pos >= 0, pos <= value.maximumBytes, Int(requested) <= value.maximumBytes - Int(pos) else { actual.pointee = 0; return kAudioFilePositionError }
            var offset = 0
            while offset < requested {
                let amount = pwrite(value.owner.fd, buffer.advanced(by: offset), Int(requested) - offset, off_t(pos) + off_t(offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { actual.pointee = UInt32(offset); return kAudioFileUnspecifiedError }; offset += amount
            }
            actual.pointee = requested; return noErr
        }, { context in
            var info = stat(); let value = Unmanaged<MixWriteContext>.fromOpaque(context).takeUnretainedValue()
            return fstat(value.owner.fd, &info) == 0 ? info.st_size : 0
        }, { context, size in
            let value = Unmanaged<MixWriteContext>.fromOpaque(context).takeUnretainedValue()
            guard size >= 0, size <= value.maximumBytes else { return kAudioFilePositionError }
            return ftruncate(value.owner.fd, off_t(size)) == 0 ? noErr : kAudioFileUnspecifiedError
        }, kAudioFileCAFType, &format, [], &file)
        guard result == noErr, let file else { throw StudioAudioMixService.MixError.codecFailure }
        var ext: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(file, true, &ext) == noErr, let ext else { AudioFileClose(file); throw StudioAudioMixService.MixError.codecFailure }
        self.file = file; self.extended = ext
    }
    func write(_ values: [Float], frames: Int) throws {
        guard let extended else { throw StudioAudioMixService.MixError.codecFailure }
        let status = values.withUnsafeBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)))
            return ExtAudioFileWrite(extended, UInt32(frames), &list)
        }
        guard status == noErr else { throw StudioAudioMixService.MixError.codecFailure }
    }
    func finish() throws {
        let a = extended.map { ExtAudioFileDispose($0) } ?? noErr; extended = nil
        let b = file.map { AudioFileClose($0) } ?? noErr; file = nil
        guard a == noErr, b == noErr, fsync(context.owner.fd) == 0 else { throw StudioAudioMixService.MixError.storageFailure }
    }
    func close() { if let extended { ExtAudioFileDispose(extended) }; extended = nil; if let file { AudioFileClose(file) }; file = nil }
    deinit { close() }
}
