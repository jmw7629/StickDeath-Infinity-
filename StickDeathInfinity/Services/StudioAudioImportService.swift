import Foundation
import AVFoundation
import AudioToolbox
import Darwin

/// Imports a materialized Files URL without playing, recording, uploading or
/// retaining that URL. Callers commit `result.track` with the editable document
/// in the existing atomic AnimationProject snapshot; return is not a save claim.
/// Security scope is balanced here. The caller must obtain the URL through an
/// authorized picker and recheck its project/revision before committing.
actor StudioAudioImportService {
    static let shared = StudioAudioImportService()
    static let maximumEncodedBytes = 16 * 1024 * 1024
    static let maximumDurationSeconds = 300.0
    static let maximumDecodedSamples: Int64 = 28_800_000
    static let waveformBinCount = 256
    static let maximumContainerChunks = 4096
    private static let copyChunkBytes = 64 * 1024
    private static let decodeChunkFrames: AVAudioFrameCount = 4096

    enum Container: String, Codable, Sendable {
        case wav, aiff, aifc, caf, m4a, mp3, aac
    }
    struct Progress: Sendable {
        enum Phase: Sendable { case reading, decoding }
        let phase: Phase
        let completed: Int64
        let total: Int64
    }
    struct ImportedAudio: Sendable {
        let id: UUID
        let name: String
        let container: Container
        let originalData: Data
        let duration: Double
        let sampleRate: Double
        let channelCount: Int
        let decodedFrameCount: Int64
        let codecID: UInt32
        /// Peak absolute sample across channels in 256 equal time intervals.
        /// Values are capped at 1 for display; silence remains exactly zero.
        let waveformPeaks: [Float]
        let hasClippedSamples: Bool

        var track: AudioTrack {
            AudioTrack(id: id, name: name, format: container.rawValue,
                       audioData: originalData, startTime: 0, duration: duration)
        }
    }

    /// A process-wide lease bounds concurrent memory even across service instances.
    /// Decode runs on this actor, not MainActor, and yields between bounded chunks.
    func importAudio(from sourceURL: URL, name: String? = nil,
                     scratchParent: URL = FileManager.default.temporaryDirectory,
                     progress: @Sendable (Progress) async throws -> Void = { _ in }) async throws -> ImportedAudio {
        try Task.checkCancellation()
        try await StudioAudioImportLease.shared.acquire()
        let result: ImportedAudio
        do {
            result = try await performImport(from: sourceURL, name: name,
                                             scratchParent: scratchParent, progress: progress)
            try Task.checkCancellation()
        } catch {
            await StudioAudioImportLease.shared.release()
            throw error
        }
        await StudioAudioImportLease.shared.release()
        return result
    }

    private func performImport(from sourceURL: URL, name: String?, scratchParent: URL,
                               progress: @Sendable (Progress) async throws -> Void) async throws -> ImportedAudio {
        guard sourceURL.isFileURL, sourceURL.host == nil || sourceURL.host == "localhost",
              sourceURL.query == nil, sourceURL.fragment == nil, !sourceURL.path.utf8.contains(0) else { throw ImportError.unsafeSource }
        let title = (name ?? sourceURL.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportError.invalidName }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let parent = try checkedScratchParent(scratchParent)
        let scratch = try StudioAudioImportScratch.create(in: parent)
        do {
            let data = try await copySource(sourceURL, scratch: scratch, progress: progress)
            try scratch.verify()
            let result = try await decode(scratch.sourceURL, name: title, data: data) { value in
                try await progress(value)
                try scratch.verify()
            }
            try Task.checkCancellation()
            try scratch.verify()
            try scratch.cleanup()
            return result
        } catch {
            let operationError = error
            do { try scratch.cleanup() }
            catch { throw ImportError.cleanupFailed(directory: scratch.directoryURL) }
            throw operationError
        }
    }

    private func checkedScratchParent(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0) else { throw ImportError.temporaryStorage }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImportError.temporaryStorage }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func copySource(_ source: URL, scratch: StudioAudioImportScratch,
                            progress: @Sendable (Progress) async throws -> Void) async throws -> Data {
        // O_NOFOLLOW rejects a selected symlink; fstat validates the opened file
        // descriptor so a path swap cannot turn a regular-file check into a read
        // of a different file type. The source is never opened for writing.
        let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard inputFD >= 0 else { throw ImportError.unsafeSource }
        defer { _ = Darwin.close(inputFD) }
        var before = stat()
        guard fstat(inputFD, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportError.unsafeSource }
        guard before.st_size > 0 else { throw ImportError.invalidAudio }
        guard before.st_size <= Self.maximumEncodedBytes else { throw ImportError.limitExceeded }
        let outputFD = try scratch.createSourceFile()
        defer { _ = Darwin.close(outputFD) }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
        var data = Data(); data.reserveCapacity(Int(before.st_size))
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: Self.copyChunkBytes), !chunk.isEmpty else { break }
            guard chunk.count <= Self.maximumEncodedBytes - data.count else { throw ImportError.limitExceeded }
            try output.write(contentsOf: chunk)
            data.append(chunk)
            try await progress(.init(phase: .reading, completed: Int64(data.count), total: before.st_size))
            try scratch.verify()
            await Task.yield()
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0, after.st_size == before.st_size,
              data.count == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw ImportError.sourceChanged }
        try Task.checkCancellation()
        return data
    }

    private func actualContainer(_ url: URL) throws -> Container {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { throw ImportError.invalidAudio }
        defer { AudioFileClose(file) }
        var fileType: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &fileType) == noErr else { throw ImportError.invalidAudio }
        switch fileType {
        case kAudioFileWAVEType: return .wav
        case kAudioFileAIFFType: return .aiff
        case kAudioFileAIFCType: return .aifc
        case kAudioFileCAFType: return .caf
        case kAudioFileM4AType: return .m4a
        case kAudioFileMP3Type: return .mp3
        case kAudioFileAAC_ADTSType: return .aac
        default: throw ImportError.unsupportedContainer
        }
    }

    private func decode(_ url: URL, name: String, data: Data,
                        progress: @Sendable (Progress) async throws -> Void) async throws -> ImportedAudio {
        try Task.checkCancellation()
        let signature = String(decoding: data.prefix(4), as: UTF8.self)
        if signature == "RIFF" || signature == "RIFX" { try validateDeclaredChunks(.wav, data: data) }
        else if signature == "FORM" { try validateDeclaredChunks(.aiff, data: data) }
        let container = try actualContainer(url)
        try validateDeclaredChunks(container, data: data)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw ImportError.invalidAudio }
        let format = file.processingFormat
        let channels = Int(format.channelCount), rate = format.sampleRate, frames = file.length
        guard channels > 0, rate.isFinite, rate > 0, frames > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else { throw ImportError.invalidAudio }
        guard channels <= 2, (8_000...96_000).contains(rate),
              Double(frames) / rate <= Self.maximumDurationSeconds,
              frames <= Self.maximumDecodedSamples / Int64(channels) else { throw ImportError.limitExceeded }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.decodeChunkFrames) else { throw ImportError.invalidAudio }
        var peaks = [Float](repeating: 0, count: Self.waveformBinCount)
        var decoded: Int64 = 0, clipped = false
        while decoded < frames {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(Self.decodeChunkFrames), frames - decoded))
            do { try file.read(into: buffer, frameCount: count) }
            catch { throw ImportError.invalidAudio }
            guard buffer.frameLength > 0, buffer.frameLength <= count,
                  let channelData = buffer.floatChannelData else { throw ImportError.invalidAudio }
            for offset in 0..<Int(buffer.frameLength) {
                var peak: Float = 0
                for channel in 0..<channels {
                    let value = channelData[channel][offset * buffer.stride]
                    guard value.isFinite else { throw ImportError.invalidAudio }
                    peak = max(peak, abs(value))
                }
                if peak > 1 { clipped = true }
                let bin = Int((decoded + Int64(offset)) * Int64(Self.waveformBinCount) / frames)
                peaks[bin] = max(peaks[bin], min(1, peak))
            }
            decoded += Int64(buffer.frameLength)
            try await progress(.init(phase: .decoding, completed: decoded, total: frames))
            await Task.yield()
        }
        // AVAudioFile can throw an unspecified error when asked to read past
        // valid EOF. Check its actual frame position instead of an extra read.
        try Task.checkCancellation()
        guard decoded == frames, file.framePosition == frames else { throw ImportError.invalidAudio }
        return ImportedAudio(id: UUID(), name: name, container: container, originalData: data,
                             duration: Double(decoded) / rate, sampleRate: rate, channelCount: channels,
                             decodedFrameCount: decoded, codecID: file.fileFormat.streamDescription.pointee.mFormatID,
                             waveformPeaks: peaks, hasClippedSamples: clipped)
    }

    /// Core Audio can recover available PCM from a truncated RIFF/FORM file.
    /// An import must surface that damage, not silently shorten the original.
    private func validateDeclaredChunks(_ container: Container, data: Data) throws {
        guard container == .wav || container == .aiff || container == .aifc else { return }
        guard data.count >= 12 else { throw ImportError.invalidAudio }
        let signature = String(decoding: data.prefix(4), as: UTF8.self)
        let littleEndian = signature == "RIFF"
        guard container == .wav ? ["RIFF", "RIFX"].contains(signature) : signature == "FORM" else { throw ImportError.unsupportedContainer }
        func length(at offset: Int) -> Int {
            let bytes = Array(data[offset..<(offset + 4)])
            return littleEndian ? Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
                : Int(bytes[3]) | Int(bytes[2]) << 8 | Int(bytes[1]) << 16 | Int(bytes[0]) << 24
        }
        let end = length(at: 4) + 8
        guard end == data.count else { throw ImportError.invalidAudio }
        var cursor = 12, chunks = 0
        while cursor < end {
            try Task.checkCancellation()
            chunks += 1
            guard chunks <= Self.maximumContainerChunks else { throw ImportError.limitExceeded }
            guard end - cursor >= 8 else { throw ImportError.invalidAudio }
            let count = length(at: cursor + 4)
            guard count <= end - cursor - 8 else { throw ImportError.invalidAudio }
            cursor += 8 + count + (count % 2)
        }
        guard cursor == end else { throw ImportError.invalidAudio }
    }

    enum ImportError: LocalizedError {
        case unsafeSource, sourceChanged, invalidName, invalidAudio, unsupportedContainer
        case limitExceeded, busy, temporaryStorage, cleanupFailed(directory: URL)
        var errorDescription: String? {
            switch self {
            case .unsafeSource: return "Choose an accessible regular audio file from Files. Links and remote URLs cannot be imported."
            case .sourceChanged: return "The audio file changed while it was being read. Select the finished file and try again."
            case .invalidName: return "Use an audio name from 1 to 120 characters without control characters."
            case .invalidAudio: return "This file could not be decoded completely as audio. No audio was added."
            case .unsupportedContainer: return "This audio container is not supported. Choose WAV, AIFF, CAF, M4A, MP3 or AAC."
            case .limitExceeded: return "Audio import supports files up to 16 MB and 5 minutes, mono or stereo at 8–96 kHz, within decoded sample and metadata limits. No audio was added."
            case .busy: return "Another audio import is running. Wait for it to finish or cancel it."
            case .temporaryStorage: return "Temporary storage is unavailable. No audio was added."
            case .cleanupFailed: return "Audio import could not remove its temporary copy. No audio was added; cleanup needs attention."
            }
        }
    }
}

private actor StudioAudioImportLease {
    static let shared = StudioAudioImportLease()
    private var busy = false
    func acquire() throws {
        guard !busy else { throw StudioAudioImportService.ImportError.busy }
        busy = true
    }
    func release() { busy = false }
}

/// Scoped to one actor operation. File descriptors bind cleanup to the directory
/// we created, even across asynchronous progress callbacks. Unknown entries and
/// replaced paths are never recursively removed; failure leaves them for review.
final class StudioAudioImportScratch {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    var sourceURL: URL { directoryURL.appendingPathComponent(Self.filename) }
    let directoryURL: URL
    private let parentURL: URL
    private let directoryName: String
    private let parentIdentity: Identity
    private let directoryIdentity: Identity
    private let parentFD: Int32
    private let directoryFD: Int32
    private var sourceIdentity: Identity?
    private var cleaned = false
    private static let filename = "source.audio"

    static func create(in parentURL: URL) throws -> StudioAudioImportScratch {
        var parent = stat()
        guard lstat(parentURL.path, &parent) == 0, isDirectory(parent) else {
            throw StudioAudioImportService.ImportError.temporaryStorage
        }
        let canonical = parentURL.resolvingSymlinksInPath().standardizedFileURL
        let parentFD = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw StudioAudioImportService.ImportError.temporaryStorage }
        var openedParent = stat()
        guard fstat(parentFD, &openedParent) == 0, Identity(parent) == Identity(openedParent) else {
            _ = Darwin.close(parentFD); throw StudioAudioImportService.ImportError.temporaryStorage
        }
        let name = ".sdi-audio-import-" + UUID().uuidString
        let directoryURL = canonical.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            _ = Darwin.close(parentFD); throw StudioAudioImportService.ImportError.temporaryStorage
        }
        let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var directory = stat()
        guard directoryFD >= 0, fstat(directoryFD, &directory) == 0, isDirectory(directory) else {
            if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
            _ = Darwin.close(parentFD)
            // Without an opened identity we cannot safely remove the new entry.
            throw StudioAudioImportService.ImportError.cleanupFailed(directory: directoryURL)
        }
        return StudioAudioImportScratch(parentURL: canonical, directoryName: name,
            parentFD: parentFD, directoryFD: directoryFD,
            parentIdentity: Identity(openedParent), directoryIdentity: Identity(directory))
    }

    private init(parentURL: URL, directoryName: String, parentFD: Int32, directoryFD: Int32,
                 parentIdentity: Identity, directoryIdentity: Identity) {
        self.parentURL = parentURL; self.directoryName = directoryName
        self.parentFD = parentFD; self.directoryFD = directoryFD
        self.parentIdentity = parentIdentity; self.directoryIdentity = directoryIdentity
        directoryURL = parentURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    func createSourceFile() throws -> Int32 {
        try verify()
        guard sourceIdentity == nil else { throw StudioAudioImportService.ImportError.temporaryStorage }
        let fd = openat(directoryFD, Self.filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StudioAudioImportService.ImportError.temporaryStorage }
        var file = stat()
        guard fstat(fd, &file) == 0, Self.isRegular(file) else {
            _ = Darwin.close(fd); throw StudioAudioImportService.ImportError.temporaryStorage
        }
        sourceIdentity = Identity(file)
        return fd
    }

    func verify() throws {
        var parent = stat()
        guard !cleaned, lstat(parentURL.path, &parent) == 0, Self.isDirectory(parent),
              Identity(parent) == parentIdentity else { throw failure }
        try verifyDirectory()
        if let expected = sourceIdentity {
            var file = stat()
            guard fstatat(directoryFD, Self.filename, &file, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isRegular(file), Identity(file) == expected else { throw failure }
        }
    }

    /// Remove only the captured regular file and then an empty captured directory.
    /// Cleanup uses the opened parent: a renamed parent does not redirect deletion
    /// into a replacement at its former URL. A renamed/replaced child fails closed.
    func cleanup() throws {
        guard !cleaned else { return }
        try verifyDirectory()
        var file = stat()
        if fstatat(directoryFD, Self.filename, &file, AT_SYMLINK_NOFOLLOW) == 0 {
            guard let expected = sourceIdentity, Self.isRegular(file), Identity(file) == expected else { throw failure }
            guard unlinkat(directoryFD, Self.filename, 0) == 0 else { throw failure }
        } else if errno != ENOENT { throw failure }
        // AT_REMOVEDIR cannot remove another entry or recursively erase contents.
        guard unlinkat(parentFD, directoryName, AT_REMOVEDIR) == 0 else { throw failure }
        cleaned = true
    }

    private func verifyDirectory() throws {
        var entry = stat(), opened = stat()
        guard fstatat(parentFD, directoryName, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(directoryFD, &opened) == 0, Self.isDirectory(entry),
              Identity(entry) == directoryIdentity, Identity(opened) == directoryIdentity else { throw failure }
    }
    private var failure: StudioAudioImportService.ImportError { .cleanupFailed(directory: directoryURL) }
    private static func isDirectory(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    private static func isRegular(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    deinit { _ = Darwin.close(directoryFD); _ = Darwin.close(parentFD) }
}
