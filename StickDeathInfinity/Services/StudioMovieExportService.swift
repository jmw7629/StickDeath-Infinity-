import Foundation
import SwiftUI
import AVFoundation
import ImageIO
import CryptoKit
import Darwin

/// Animation-only MP4 foundation. The caller captures the entire document,
/// including retained legacy audio and raster bytes, before starting this work.
/// No picker, Photos, cloud, publishing, or background-task side effects.
@MainActor
final class StudioMovieExportService {
    enum Background: String, Codable { case white, transparent }
    struct Snapshot {
        let document: StudioDocument
        let retainedAudioTracks: [AudioTrack]
        let rasterDataByID: [String: Data]
    }
    enum Phase { case rendering, finalizing, verifying, publishing }
    struct Progress {
        let phase: Phase
        let completedFrames: Int
        let totalFrames: Int
    }
    struct Manifest: Codable {
        let version: Int
        let projectID: UUID
        let documentRevision: Int
        let frameIDs: [String]
        let fps: Int
        let width: Int
        let height: Int
        let durationNumerator: Int
        let durationDenominator: Int
        let codec: String
        let background: Background
        let audioIncluded: Bool
        let editorGuidesIncluded: Bool
        let encodedBytes: Int
        /// Present only for an internal video component, never a completed audio export.
        var visualComponentProof: StudioMuxCapture.Proof? = nil
    }
    /// The caller retains this handle while a share sheet or decoder consumes
    /// its files. URLs alone do not transfer cleanup ownership. Neither service
    /// nor handle deinitialization deletes a successfully returned movie.
    @MainActor struct Output {
        let directory: URL
        let movieURL: URL
        let manifestURL: URL
        let manifest: Manifest
        fileprivate let ownership: OutputOwnership

        /// Revalidate immediately before handing files to a consumer. No API can
        /// protect a naked URL after another task replaces that path; the caller
        /// must serialize its consumers and cleanup for the whole share session.
        func checkedURLs() throws -> [URL] {
            try ownership.validateForUse()
            return [movieURL, manifestURL]
        }
        var isCleaned: Bool { ownership.cleaned }
        var isCancelled: Bool { ownership.cancelled }
        /// Idempotent after success. Failure preserves unknown/replaced content
        /// and is retryable after its owner restores/removes the conflicting item.
        /// This deliberately still runs when the enclosing Task is cancelled.
        func cleanup() throws { try ownership.cleanup() }
        func cancel() throws { ownership.cancelled = true; try ownership.cleanup() }
    }

    /// Internal component handle. Its complete capture (including audio) is
    /// retained; this type is not the ordinary finished movie export receipt.
    @MainActor final class VisualComponent {
        let capture: StudioMuxCapture
        private let output: Output
        fileprivate init(capture: StudioMuxCapture, output: Output) {
            self.capture = capture; self.output = output
        }
        func checkedSource() throws -> (URL, Manifest) {
            _ = try output.checkedURLs()
            guard output.manifest.visualComponentProof == capture.proof else { throw ExportError.outputUnavailable }
            return (output.movieURL, output.manifest)
        }
        func cleanup() throws { try output.cleanup() }
    }

    func exportVisualComponent(capture: StudioMuxCapture, outputParent: URL,
                               progress: (Progress) throws -> Void = { _ in }) async throws -> VisualComponent {
        let output = try await exportCore(snapshot: capture.snapshot, outputParent: outputParent,
                                          background: .white, componentProof: capture.proof, progress: progress)
        return VisualComponent(capture: capture, output: output)
    }

    /// Captured before publication, then carried across the same-parent rename.
    /// All deletion is descriptor-relative, no-follow, and nonrecursive. MainActor
    /// serializes API callers; no awaits or caller callbacks occur in cleanup.
    /// Carries identities captured from our original open descriptors across
    /// the encoding-to-returned-output boundary. Matching bytes alone cannot
    /// transfer cleanup ownership to a replacement inode.
    fileprivate struct CreatedIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        let links: nlink_t
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino
            kind = value.st_mode & mode_t(S_IFMT); links = value.st_nlink
        }
    }
    fileprivate struct PublicationIdentity {
        let parent: CreatedIdentity
        let directory: CreatedIdentity
        let files: [String: CreatedIdentity]
    }

    @MainActor fileprivate final class OutputOwnership {
        private struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
            init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
        }
        private struct FileRecord {
            let fd: Int32
            let identity: Identity
            let bytes: Int64
            let digest: SHA256.Digest
        }
        private let parentURL: URL
        private var name: String
        private let parentIdentity: Identity
        private let directoryIdentity: Identity
        private var parentFD: Int32
        private var directoryFD: Int32
        private var files: [String: FileRecord] = [:]
        fileprivate private(set) var cleaned = false
        fileprivate var cancelled = false
        private var currentURL: URL { parentURL.appendingPathComponent(name, isDirectory: true) }

        init(parent: URL, staging: URL, movieDigest: SHA256.Digest,
             movieBytes: Int, manifestData: Data, original: PublicationIdentity) throws {
            guard Set(original.files.keys) == Set(["animation.mp4", "manifest.json"]) else { throw ExportError.unsafeDestination }
            parentURL = parent; name = staging.lastPathComponent
            var parentInfo = stat()
            guard lstat(parent.path, &parentInfo) == 0, Self.directory(parentInfo) else { throw ExportError.unsafeDestination }
            let openedParent = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard openedParent >= 0 else { throw ExportError.unsafeDestination }
            var parentOpenedInfo = stat()
            guard fstat(openedParent, &parentOpenedInfo) == 0, Self.directory(parentOpenedInfo),
                  Identity(parentInfo) == Identity(parentOpenedInfo), CreatedIdentity(parentOpenedInfo) == original.parent else {
                _ = Darwin.close(openedParent); throw ExportError.unsafeDestination
            }
            let openedDirectory = openat(openedParent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var directoryInfo = stat()
            guard openedDirectory >= 0, fstat(openedDirectory, &directoryInfo) == 0, Self.directory(directoryInfo),
                  CreatedIdentity(directoryInfo) == original.directory else {
                if openedDirectory >= 0 { _ = Darwin.close(openedDirectory) }
                _ = Darwin.close(openedParent); throw ExportError.unsafeDestination
            }
            parentFD = openedParent; directoryFD = openedDirectory
            parentIdentity = Identity(parentOpenedInfo); directoryIdentity = Identity(directoryInfo)
            do {
                let expected: [(String, Int64, SHA256.Digest)] = [
                    ("animation.mp4", Int64(movieBytes), movieDigest),
                    ("manifest.json", Int64(manifestData.count), SHA256.hash(data: manifestData))
                ]
                for (filename, size, digest) in expected {
                    let fd = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard fd >= 0 else { throw ExportError.unsafeDestination }
                    var info = stat()
                    guard fstat(fd, &info) == 0, Self.regular(info), info.st_nlink == 1, info.st_size == size,
                          CreatedIdentity(info) == original.files[filename] else {
                        _ = Darwin.close(fd); throw ExportError.unsafeDestination
                    }
                    files[filename] = FileRecord(fd: fd, identity: Identity(info), bytes: size, digest: digest)
                }
                try validateFiles(allowMissing: false)
            } catch {
                closeDescriptors()
                throw error
            }
        }

        func publish(to destination: URL) throws {
            guard destination.deletingLastPathComponent().standardizedFileURL == parentURL,
                  destination.lastPathComponent != name else { throw ExportError.unsafeDestination }
            try validateFiles(allowMissing: false)
            // RENAME_EXCL refuses both an existing file and an existing empty
            // directory; publication never overwrites a collision.
            guard renameatx_np(parentFD, name, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                throw ExportError.unsafeDestination
            }
            name = destination.lastPathComponent
            try validateFiles(allowMissing: false)
        }
        func validateForUse() throws {
            guard !cleaned, !cancelled else { throw ExportError.outputUnavailable }
            do { try validateFiles(allowMissing: false) }
            catch { throw ExportError.outputUnavailable }
        }
        func cleanup() throws {
            guard !cleaned else { return }
            do {
                // Validate the entire two-file set before deleting either file.
                // An unexpected nested item leaves everything intact. Already
                // missing owned files are allowed so partial cleanup is retryable.
                try validateFiles(allowMissing: true)
                for filename in ["animation.mp4", "manifest.json"] {
                    try confirmDirectories()
                    guard let record = files[filename] else { throw ExportError.unsafeDestination }
                    if try fileStillOwned(filename, record: record, allowMissing: true) {
                        guard unlinkat(directoryFD, filename, 0) == 0 else { throw ExportError.unsafeDestination }
                    }
                }
                try confirmDirectories()
                guard try entries().isEmpty else { throw ExportError.unsafeDestination }
                guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw ExportError.unsafeDestination }
                cleaned = true; closeDescriptors()
            } catch { throw ExportError.cleanupFailed(currentURL) }
        }
        private func confirmDirectories() throws {
            var pathParent = stat(), parent = stat(), pathDirectory = stat(), directory = stat()
            guard parentFD >= 0, directoryFD >= 0,
                  lstat(parentURL.path, &pathParent) == 0, Self.directory(pathParent), Identity(pathParent) == parentIdentity,
                  fstat(parentFD, &parent) == 0, Identity(parent) == parentIdentity,
                  fstatat(parentFD, name, &pathDirectory, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.directory(pathDirectory), Identity(pathDirectory) == directoryIdentity,
                  fstat(directoryFD, &directory) == 0, Identity(directory) == directoryIdentity else {
                throw ExportError.unsafeDestination
            }
        }
        private func validateFiles(allowMissing: Bool) throws {
            try confirmDirectories()
            let names = try entries()
            guard names.isSubset(of: Set(files.keys)), allowMissing || names == Set(files.keys) else { throw ExportError.unsafeDestination }
            for (filename, record) in files {
                _ = try fileStillOwned(filename, record: record, allowMissing: allowMissing)
            }
            try confirmDirectories()
        }
        private func entries() throws -> Set<String> {
            let duplicate = dup(directoryFD)
            guard duplicate >= 0 else { throw ExportError.unsafeDestination }
            guard let stream = fdopendir(duplicate) else { _ = Darwin.close(duplicate); throw ExportError.unsafeDestination }
            defer { closedir(stream) }
            rewinddir(stream)
            var result = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw ExportError.unsafeDestination }
                    return result
                }
                let filename = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if filename == "." || filename == ".." { continue }
                guard result.count < 2, files[filename] != nil else { throw ExportError.unsafeDestination }
                result.insert(filename)
            }
        }
        private func fileStillOwned(_ name: String, record: FileRecord, allowMissing: Bool) throws -> Bool {
            var pathInfo = stat()
            if fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                if allowMissing && errno == ENOENT { return false }
                throw ExportError.unsafeDestination
            }
            var before = stat()
            guard Self.regular(pathInfo), pathInfo.st_nlink == 1, Identity(pathInfo) == record.identity,
                  pathInfo.st_size == record.bytes, fstat(record.fd, &before) == 0,
                  Identity(before) == record.identity, before.st_size == record.bytes else { throw ExportError.unsafeDestination }
            var digest = SHA256(), offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while offset < record.bytes {
                let amount = min(buffer.count, Int(record.bytes - offset))
                let count = buffer.withUnsafeMutableBytes { pread(record.fd, $0.baseAddress, amount, off_t(offset)) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ExportError.unsafeDestination }
                digest.update(data: Data(buffer.prefix(count))); offset += Int64(count)
            }
            var after = stat(), pathAfter = stat()
            guard fstat(record.fd, &after) == 0, fstatat(directoryFD, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.regular(pathAfter), pathAfter.st_nlink == 1, Identity(after) == record.identity,
                  Identity(pathAfter) == record.identity, after.st_size == record.bytes, pathAfter.st_size == record.bytes,
                  Self.sameTimes(before, after), Self.sameTimes(after, pathAfter), digest.finalize() == record.digest else {
                throw ExportError.unsafeDestination
            }
            return true
        }
        private func closeDescriptors() {
            for record in files.values { _ = Darwin.close(record.fd) }
            files.removeAll()
            if directoryFD >= 0 { _ = Darwin.close(directoryFD); directoryFD = -1 }
            if parentFD >= 0 { _ = Darwin.close(parentFD); parentFD = -1 }
        }
        deinit {
            // Returned files survive loss of the handle, as in the original API.
            // The app must explicitly clean after its consumers have completed.
            for record in files.values { _ = Darwin.close(record.fd) }
            if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
            if parentFD >= 0 { _ = Darwin.close(parentFD) }
        }
        private static func directory(_ info: stat) -> Bool { info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
        private static func regular(_ info: stat) -> Bool { info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
        private static func sameTimes(_ a: stat, _ b: stat) -> Bool {
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
                && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
    }

    /// Records only outputs created by a successful writer start or our own
    /// exclusive open. Directory enumeration never grants file ownership.
    /// AVFoundation owns its opaque sidecars; we never identify or unlink them.
    @MainActor private final class EncodingOwnership {
        private struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
            init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
        }
        private struct FileRecord { let fd: Int32; let identity: Identity }
        private let parentURL: URL
        private let stagingURL: URL
        private let parentIdentity: Identity
        private let directoryIdentity: Identity
        private let parentFD: Int32
        private let directoryFD: Int32
        private var files: [String: FileRecord] = [:]

        init(parent: URL, staging: URL) throws {
            parentURL = parent; stagingURL = staging
            let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var parentInfo = stat()
            guard parentFD >= 0, fstat(parentFD, &parentInfo) == 0 else {
                if parentFD >= 0 { _ = Darwin.close(parentFD) }
                throw ExportError.cleanupFailed(staging)
            }
            let directoryFD = openat(parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var directoryInfo = stat()
            guard directoryFD >= 0, fstat(directoryFD, &directoryInfo) == 0 else {
                if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
                _ = Darwin.close(parentFD)
                throw ExportError.cleanupFailed(staging)
            }
            self.parentFD = parentFD; self.directoryFD = directoryFD
            parentIdentity = Identity(parentInfo); directoryIdentity = Identity(directoryInfo)
            try confirmDirectories()
        }
        deinit {
            for record in files.values { _ = Darwin.close(record.fd) }
            _ = Darwin.close(directoryFD); _ = Darwin.close(parentFD)
        }
        /// Call immediately after startWriting succeeds, before any await,
        /// render or user callback. Only that explicit output is captured.
        func captureStartedMovie() throws {
            try confirmDirectories()
            let fd = openat(directoryFD, "animation.mp4", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            try retainCreatedFile(fd, name: "animation.mp4")
        }
        func writeManifest(_ data: Data) throws {
            try confirmDirectories()
            let fd = openat(directoryFD, "manifest.json", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            try retainCreatedFile(fd, name: "manifest.json")
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ExportError.writerFailed }
                    offset += count
                }
            }
        }
        private func retainCreatedFile(_ fd: Int32, name: String) throws {
            var info = stat()
            guard fd >= 0, files[name] == nil, fstat(fd, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                if fd >= 0 { _ = Darwin.close(fd) }
                throw ExportError.cleanupFailed(stagingURL)
            }
            files[name] = FileRecord(fd: fd, identity: Identity(info))
        }
        private func confirmDirectories() throws {
            var parent = stat(), openedParent = stat(), directory = stat(), openedDirectory = stat()
            guard lstat(parentURL.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
                  Identity(parent) == parentIdentity,
                  fstat(parentFD, &openedParent) == 0, Identity(openedParent) == parentIdentity,
                  fstatat(parentFD, stagingURL.lastPathComponent, &directory, AT_SYMLINK_NOFOLLOW) == 0,
                  directory.st_mode & S_IFMT == S_IFDIR, Identity(directory) == directoryIdentity,
                  fstat(directoryFD, &openedDirectory) == 0, Identity(openedDirectory) == directoryIdentity else {
                throw ExportError.cleanupFailed(stagingURL)
            }
        }
        private func presentAndOwned(_ name: String, record: FileRecord) throws -> Bool {
            var current = stat(), opened = stat()
            if fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return false }
                throw ExportError.cleanupFailed(stagingURL)
            }
            guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  Identity(current) == record.identity, fstat(record.fd, &opened) == 0,
                  Identity(opened) == record.identity else { throw ExportError.cleanupFailed(stagingURL) }
            return true
        }
        private func hasUnknownEntry() throws -> Bool {
            let duplicate = dup(directoryFD)
            guard duplicate >= 0 else { throw ExportError.cleanupFailed(stagingURL) }
            guard let stream = fdopendir(duplicate) else {
                _ = Darwin.close(duplicate); throw ExportError.cleanupFailed(stagingURL)
            }
            defer { closedir(stream) }
            rewinddir(stream)
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw ExportError.cleanupFailed(stagingURL) }
                    return false
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                // At most two known names can be visited before the first
                // unknown entry. Its spelling cannot authorize its deletion.
                if files[name] == nil { return true }
            }
        }
        /// Validate paths against the descriptors retained at writer start and
        /// exclusive manifest creation, then carry those same identities into
        /// the final owner's reopened descriptors. No callback or suspension
        /// occurs during this transfer, and the constructor rechecks identity.
        func publicationIdentity() throws -> PublicationIdentity {
            try confirmDirectories()
            guard Set(files.keys) == Set(["animation.mp4", "manifest.json"]) else { throw ExportError.cleanupFailed(stagingURL) }
            var parent = stat(), directory = stat()
            guard fstat(parentFD, &parent) == 0, Identity(parent) == parentIdentity,
                  fstat(directoryFD, &directory) == 0, Identity(directory) == directoryIdentity else { throw ExportError.cleanupFailed(stagingURL) }
            var captured: [String: CreatedIdentity] = [:]
            for (name, record) in files {
                guard try presentAndOwned(name, record: record) else { throw ExportError.cleanupFailed(stagingURL) }
                var info = stat()
                guard fstat(record.fd, &info) == 0, Identity(info) == record.identity,
                      info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw ExportError.cleanupFailed(stagingURL) }
                captured[name] = CreatedIdentity(info)
            }
            try confirmDirectories()
            return PublicationIdentity(parent: CreatedIdentity(parent), directory: CreatedIdentity(directory), files: captured)
        }

        /// The caller releases AVAssetWriter first. Its opaque files may settle
        /// asynchronously. The wait ignores caller cancellation so owned cleanup
        /// still runs; a persistent unknown entry preserves the complete set.
        func cleanupAfterWriterRelease() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while true {
                try confirmDirectories()
                for (name, record) in files { _ = try presentAndOwned(name, record: record) }
                if try !hasUnknownEntry() { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ExportError.cleanupFailed(stagingURL) }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
                }
            }
            // Whole-set validation precedes the first deletion. No suspension or
            // caller callback occurs between this check and descriptor cleanup.
            try confirmDirectories()
            for (name, record) in files { _ = try presentAndOwned(name, record: record) }
            guard try !hasUnknownEntry() else { throw ExportError.cleanupFailed(stagingURL) }
            for name in files.keys.sorted() {
                try confirmDirectories()
                if try presentAndOwned(name, record: files[name]!) {
                    guard unlinkat(directoryFD, name, 0) == 0 else { throw ExportError.cleanupFailed(stagingURL) }
                }
            }
            try confirmDirectories()
            guard try !hasUnknownEntry(), unlinkat(parentFD, stagingURL.lastPathComponent, AT_REMOVEDIR) == 0 else {
                throw ExportError.cleanupFailed(stagingURL)
            }
        }
    }

    struct Limits {
        var maximumFrames = 240
        var maximumFramePixels = 4_194_304
        var maximumTotalPixels = 134_217_728
        var maximumOutputBytes = 64 * 1024 * 1024
        var maximumRasterBytes = 64 * 1024 * 1024
        var maximumRasterPixels = 16_777_216
        var readinessTimeout: TimeInterval = 30
        var operationTimeout: TimeInterval = 300
    }
    // This lease covers movie encoders only; the existing PNG service has its
    // own lease. There is one rendered CGImage and at most three pool buffers,
    // not an array of rendered frames. Apple owns additional codec buffers.
    private static var movieInProgress = false
    private let limits: Limits
    init(limits: Limits = Limits()) { self.limits = limits }

    /// Path spelling alone does not prove cleanup ownership after an await or
    /// caller callback. Keep the identity of both directories that were used.
    private struct DirectoryIdentity {
        let url: URL
        let device: UInt64
        let inode: UInt64
        init(_ url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeDirectory,
                  let device = values[.systemNumber] as? NSNumber,
                  let inode = values[.systemFileNumber] as? NSNumber else { throw ExportError.unsafeDestination }
            self.url = url; self.device = device.uint64Value; self.inode = inode.uint64Value
        }
        func stillMatches() -> Bool {
            guard let current = try? DirectoryIdentity(url) else { return false }
            return current.device == device && current.inode == inode
        }
    }

    /// outputParent must be an existing app-owned cache/temporary directory.
    /// Background is required: H.264 cannot represent the transparent option.
    /// Progress is factual intermediate work, not a save/export success receipt.
    func export(snapshot: Snapshot, outputParent: URL, background: Background,
                progress: (Progress) throws -> Void = { _ in }) async throws -> Output {
        try await exportCore(snapshot: snapshot, outputParent: outputParent, background: background,
                             componentProof: nil, progress: progress)
    }

    private func exportCore(snapshot: Snapshot, outputParent: URL, background: Background,
                            componentProof: StudioMuxCapture.Proof?, progress: (Progress) throws -> Void) async throws -> Output {
        try Task.checkCancellation()
        guard !Self.movieInProgress else { throw ExportError.alreadyExporting }
        Self.movieInProgress = true
        defer { Self.movieInProgress = false }
        let started = ProcessInfo.processInfo.systemUptime
        try validate(snapshot, background: background, componentProof: componentProof)
        try checkpoint(started)
        let document = snapshot.document
        let fm = FileManager.default
        guard outputParent.isFileURL else { throw ExportError.unsafeDestination }
        let parent = outputParent.standardizedFileURL
        let attributes = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ExportError.unsafeDestination }
        let parentIdentity = try DirectoryIdentity(parent)
        let identifier = UUID().uuidString
        let staging = parent.appendingPathComponent(".sdi-movie-" + identifier + ".partial", isDirectory: true)
        let destination = parent.appendingPathComponent("SDI-Movie-" + document.id.uuidString + "-" + identifier, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var writer: AVAssetWriter?
        var stagingIdentity: DirectoryIdentity?
        var outputOwnership: OutputOwnership?
        var capturingOutputOwnership = false
        var encodingOwnership: EncodingOwnership?
        do {
            let identity = try DirectoryIdentity(staging)
            stagingIdentity = identity
            encodingOwnership = try EncodingOwnership(parent: parent, staging: staging)
            func confirmOwnership() throws {
                guard parentIdentity.stillMatches(), identity.stillMatches() else { throw ExportError.unsafeDestination }
            }
            try confirmOwnership()
            let movie = staging.appendingPathComponent("animation.mp4")
            writer = try AVAssetWriter(outputURL: movie, fileType: .mp4)
            writer!.movieTimeScale = CMTimeScale(document.fps * 600)
            writer!.shouldOptimizeForNetworkUse = true
            let bitrate = min(12_000_000, max(2_000_000, document.width * document.height * document.fps * 2))
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: document.width, AVVideoHeightKey: document.height,
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: document.fps, AVVideoAllowFrameReorderingKey: false,
                    // Independent animation frames avoid the measured solid-color
                    // drift on abrupt inter-frame transitions and allow seeking.
                    AVVideoMaxKeyFrameIntervalKey: 1,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
            ]
            guard writer!.canApply(outputSettings: settings, forMediaType: .video) else { throw ExportError.codecUnavailable }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            input.mediaTimeScale = CMTimeScale(document.fps * 600)
            let bufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: document.width, kCVPixelBufferHeightKey as String: document.height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: bufferAttributes)
            guard writer!.canAdd(input) else { throw ExportError.codecUnavailable }
            writer!.add(input)
            guard writer!.startWriting() else { throw ExportError.writerFailed }
            try encodingOwnership!.captureStartedMovie()
            writer!.startSession(atSourceTime: .zero)
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.codecUnavailable }
            var formatDescription: CMVideoFormatDescription?
            for (index, frame) in document.frames.enumerated() {
                try await waitUntilReady(input, writer: writer!, movie: movie, started: started)
                let buffer = try await pixelBuffer(pool, writer: writer!, movie: movie, started: started)
                try confirmOwnership()
                try autoreleasepool {
                    try checkpoint(started)
                    let image = try render(frame, document: document, raster: frame.rasterAssetID.flatMap { snapshot.rasterDataByID[$0] })
                    try draw(image, into: buffer)
                    if formatDescription == nil {
                        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                            formatDescriptionOut: &formatDescription) == noErr else { throw ExportError.renderFailed }
                    }
                    guard let formatDescription else { throw ExportError.renderFailed }
                    // The adaptor supplies the bounded pool. Append an explicit
                    // sample duration: its convenience append(buffer, PTS) API
                    // leaves a one-frame movie's duration to codec inference.
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(document.fps)),
                        presentationTimeStamp: CMTime(value: Int64(index), timescale: CMTimeScale(document.fps)), decodeTimeStamp: .invalid)
                    var sample: CMSampleBuffer?
                    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                        formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
                        let sample, input.append(sample) else {
                        throw ExportError.writerFailed
                    }
                }
                try checkOutputSize(movie)
                try progress(Progress(phase: .rendering, completedFrames: index + 1, totalFrames: document.frames.count))
                try confirmOwnership()
                await Task.yield()
            }
            try checkpoint(started)
            try progress(Progress(phase: .finalizing, completedFrames: document.frames.count, totalFrames: document.frames.count))
            try confirmOwnership()
            try checkpoint(started)
            // The end time includes the full last frame, even for one-frame or
            // 1 FPS movies; nothing is duplicated to manufacture that duration.
            writer!.endSession(atSourceTime: CMTime(value: Int64(document.frames.count), timescale: CMTimeScale(document.fps)))
            input.markAsFinished()
            writer!.finishWriting {}
            while writer!.status == .writing {
                try checkpoint(started)
                try checkOutputSize(movie)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard writer!.status == .completed else { throw ExportError.writerFailed }
            try checkpoint(started)
            // Seal the encoder-completed bytes before a caller callback can
            // replace their contents with different but otherwise valid media.
            // The post-verification/publication comparison must match this seal.
            let verifiedBytes = try fingerprint(movie, started: started)
            try progress(Progress(phase: .verifying, completedFrames: document.frames.count, totalFrames: document.frames.count))
            try confirmOwnership()
            try await verify(movie, document: document, started: started)
            try confirmOwnership()
            let bytes = try checkOutputSize(movie, requireNonempty: true)
            var manifest = Manifest(version: 1, projectID: document.id, documentRevision: document.revision,
                frameIDs: document.frames.map(\.id), fps: document.fps, width: document.width, height: document.height,
                durationNumerator: document.frames.count, durationDenominator: document.fps, codec: "H.264",
                background: .white, audioIncluded: false, editorGuidesIncluded: false, encodedBytes: bytes)
            manifest.visualComponentProof = componentProof
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let manifestData = try encoder.encode(manifest)
            try encodingOwnership!.writeManifest(manifestData)
            try progress(Progress(phase: .publishing, completedFrames: document.frames.count, totalFrames: document.frames.count))
            try confirmOwnership()
            try checkpoint(started)
            // Bind the verification to these exact bytes even if a caller's
            // progress callback or another app task changed its cache contents.
            guard try fingerprint(movie, started: started) == verifiedBytes else { throw ExportError.verificationFailed }
            // Byte verification is insufficient if a caller replaced a file
            // with an identical clone. The final owner must inherit the actual
            // encoder/manifest descriptor identities before it may clean them.
            let originalIdentity = try encodingOwnership!.publicationIdentity()
            capturingOutputOwnership = true
            let ownership = try OutputOwnership(parent: parent, staging: staging,
                movieDigest: verifiedBytes, movieBytes: bytes, manifestData: manifestData, original: originalIdentity)
            outputOwnership = ownership
            try ownership.publish(to: destination)
            try checkpoint(started)
            return Output(directory: destination, movieURL: destination.appendingPathComponent("animation.mp4"),
                manifestURL: destination.appendingPathComponent("manifest.json"), manifest: manifest, ownership: ownership)
        } catch {
            if capturingOutputOwnership {
                // A failed ownership capture may have found a foreign entry.
                // Retain it and surface cleanup instead of falling through to
                // the earlier encoding-stage directory cleanup.
                guard let ownership = outputOwnership else { throw ExportError.cleanupFailed(staging) }
                do { try ownership.cleanup() } catch { throw error }
                throw error
            }
            // Releasing the writer lets AVFoundation release its own opaque
            // sidecars. Do not call cancelWriting on a possibly replaced URL,
            // and never adopt sidecars or unrelated directory entries.
            writer = nil
            guard parentIdentity.stillMatches(), stagingIdentity?.stillMatches() == true,
                  let encodingOwnership else { throw ExportError.cleanupFailed(staging) }
            try await encodingOwnership.cleanupAfterWriterRelease()
            throw error
        }
    }

    private func validate(_ snapshot: Snapshot, background: Background, componentProof: StudioMuxCapture.Proof?) throws {
        let hard = Limits()
        guard (1...hard.maximumFrames).contains(limits.maximumFrames),
              (1...hard.maximumFramePixels).contains(limits.maximumFramePixels),
              (1...hard.maximumTotalPixels).contains(limits.maximumTotalPixels),
              (1...hard.maximumOutputBytes).contains(limits.maximumOutputBytes),
              (1...hard.maximumRasterBytes).contains(limits.maximumRasterBytes),
              (1...hard.maximumRasterPixels).contains(limits.maximumRasterPixels),
              limits.readinessTimeout.isFinite, limits.readinessTimeout > 0, limits.readinessTimeout <= 30,
              limits.operationTimeout.isFinite, limits.operationTimeout > 0, limits.operationTimeout <= 300 else { throw ExportError.limitExceeded }
        guard background == .white else { throw ExportError.transparentUnsupported }
        if let componentProof {
            guard try StudioMuxCapture.proofFor(snapshot) == componentProof else { throw ExportError.unsupportedContent }
        } else {
            guard snapshot.document.audioClips.isEmpty, snapshot.retainedAudioTracks.isEmpty else { throw ExportError.audioUnsupported }
        }
        let document = snapshot.document
        try document.validate()
        guard document.width.isMultiple(of: 2), document.height.isMultiple(of: 2) else { throw ExportError.oddDimensions }
        let pixels = document.width * document.height
        guard document.frames.count <= limits.maximumFrames, pixels <= limits.maximumFramePixels,
              pixels * document.frames.count <= limits.maximumTotalPixels else { throw ExportError.limitExceeded }
        let tools: Set<DrawingTool> = [.pencil, .pen, .brush, .marker, .crayon, .eraser, .line, .rectangle, .circle, .text]
        let blends: Set<String> = ["normal", "multiply", "screen", "overlay", "darken", "lighten"]
        func colorValid(_ value: String) -> Bool {
            let hex = value.hasPrefix("#") ? value.dropFirst() : value[...]
            return hex.utf8.count == 6 && hex.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        }
        let visible = document.layers.filter { $0.visible && $0.opacity > 0 }
        let visibleIDs = Set(visible.map(\.id))
        for layer in visible {
            guard blends.contains(layer.blendMode.lowercased()),
                  !layer.glowEnabled || layer.glowColor.map(colorValid) != false else { throw ExportError.unsupportedContent }
        }
        for frame in document.frames {
            try Task.checkCancellation()
            for element in frame.elements where element.opacity > 0 && element.layerID.map(visibleIDs.contains) == true {
                guard tools.contains(element.tool), colorValid(element.color) else { throw ExportError.unsupportedContent }
                if element.tool == .text {
                    guard let text = element.fillColor, !text.isEmpty, text.utf8.count <= 4096 else { throw ExportError.unsupportedContent }
                }
            }
        }
        let references = Set(document.frames.compactMap(\.rasterAssetID))
        guard snapshot.rasterDataByID.count <= limits.maximumFrames else { throw ExportError.limitExceeded }
        var bytes = 0
        for (id, data) in snapshot.rasterDataByID {
            guard !id.isEmpty, id.utf8.count <= 1024, data.count <= limits.maximumRasterBytes - bytes else { throw ExportError.limitExceeded }
            bytes += data.count
        }
        // Even a hidden referenced raster must exist and decode; exporting must
        // never turn a lost original into an apparently successful empty layer.
        for id in references {
            try Task.checkCancellation()
            guard let data = snapshot.rasterDataByID[id] else { throw ExportError.missingRaster }
            try autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 8192, height <= 8192 else { throw ExportError.invalidRaster }
                guard width * height <= limits.maximumRasterPixels else { throw ExportError.limitExceeded }
                guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
                      CGImageSourceGetStatus(source) == .statusComplete,
                      CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                      UIImage(data: data) != nil else { throw ExportError.invalidRaster }
            }
        }
    }

    private func render(_ frame: AnimationFrame, document: StudioDocument, raster: Data?) throws -> CGImage {
        let size = CGSize(width: document.width, height: document.height)
        let brushes = try StudioFrameRenderer.prepare(frame: frame)
        var failure: Error?
        let canvas = Canvas { context, actual in
            context.fill(Path(CGRect(origin: .zero, size: actual)), with: .color(.white))
            failure = StudioFrameRenderer.draw(context: &context, frame: frame, layers: document.layers,
                canvasSize: size, size: actual, rasterData: raster, preparedBrushes: brushes)
        }.frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas); renderer.scale = 1; renderer.isOpaque = true
        guard let image = renderer.cgImage, image.width == document.width, image.height == document.height else { throw ExportError.renderFailed }
        if let failure { throw failure }
        return image
    }

    private func draw(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ExportError.renderFailed }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: address, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw ExportError.renderFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private func checkpoint(_ started: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - started < limits.operationTimeout else { throw ExportError.timedOut }
    }
    @discardableResult private func checkOutputSize(_ url: URL, requireNonempty: Bool = false) throws -> Int {
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ExportError.unsafeDestination }
        let size = attributes.fileSize ?? 0
        guard size <= limits.maximumOutputBytes else { throw ExportError.limitExceeded }
        if requireNonempty && size == 0 { throw ExportError.writerFailed }
        return size
    }
    private func fingerprint(_ url: URL, started: TimeInterval) throws -> SHA256.Digest {
        let expectedBytes = try checkOutputSize(url, requireNonempty: true)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), count = 0
        while true {
            try checkpoint(started)
            let data = try file.read(upToCount: 64 * 1024) ?? Data()
            if data.isEmpty { break }
            guard data.count <= limits.maximumOutputBytes - count else { throw ExportError.limitExceeded }
            count += data.count; digest.update(data: data)
        }
        guard count == expectedBytes else { throw ExportError.verificationFailed }
        return digest.finalize()
    }
    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter, movie: URL, started: TimeInterval) async throws {
        let waitStarted = ProcessInfo.processInfo.systemUptime
        while !input.isReadyForMoreMediaData {
            try checkpoint(started); try checkOutputSize(movie)
            guard writer.status == .writing else { throw ExportError.writerFailed }
            guard ProcessInfo.processInfo.systemUptime - waitStarted < limits.readinessTimeout else { throw ExportError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try checkpoint(started)
        guard writer.status == .writing else { throw ExportError.writerFailed }
    }
    private func pixelBuffer(_ pool: CVPixelBufferPool, writer: AVAssetWriter, movie: URL, started: TimeInterval) async throws -> CVPixelBuffer {
        let waitStarted = ProcessInfo.processInfo.systemUptime
        while true {
            try checkpoint(started); try checkOutputSize(movie)
            guard writer.status == .writing else { throw ExportError.writerFailed }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &buffer)
            if status == kCVReturnSuccess, let buffer { return buffer }
            guard status == kCVReturnWouldExceedAllocationThreshold else { throw ExportError.renderFailed }
            guard ProcessInfo.processInfo.systemUptime - waitStarted < limits.readinessTimeout else { throw ExportError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func verify(_ movie: URL, document: StudioDocument, started: TimeInterval) async throws {
        try checkpoint(started)
        let asset = AVURLAsset(url: movie)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, try await asset.loadTracks(withMediaType: .audio).isEmpty else { throw ExportError.verificationFailed }
        let track = tracks[0]
        let descriptions = try await track.load(.formatDescriptions)
        guard descriptions.count == 1, CMFormatDescriptionGetMediaSubType(descriptions[0]) == kCMVideoCodecType_H264 else { throw ExportError.verificationFailed }
        let size = CMVideoFormatDescriptionGetDimensions(descriptions[0])
        let expectedEnd = CMTime(value: Int64(document.frames.count), timescale: CMTimeScale(document.fps))
        let duration = try await asset.load(.duration)
        let range = try await track.load(.timeRange)
        guard size.width == document.width, size.height == document.height,
              CMTimeCompare(duration, expectedEnd) == 0, CMTimeCompare(range.start, .zero) == 0,
              CMTimeCompare(range.duration, expectedEnd) == 0 else { throw ExportError.verificationFailed }
        // The decompressor legitimately returns invalid sample durations on
        // macOS. Verify encoded sample durations separately, then decode every
        // picture. Zero-sample AVFoundation boundary markers are not frames.
        let timingReader = try AVAssetReader(asset: asset)
        let timingOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        timingOutput.alwaysCopiesSampleData = false
        guard timingReader.canAdd(timingOutput) else { throw ExportError.verificationFailed }
        timingReader.add(timingOutput)
        guard timingReader.startReading() else { throw ExportError.verificationFailed }
        defer { if timingReader.status == .reading { timingReader.cancelReading() } }
        var timedFrames = 0, markers = 0
        while true {
            try checkpoint(started)
            let exists = try autoreleasepool { () throws -> Bool in
                guard let sample = timingOutput.copyNextSampleBuffer() else { return false }
                if CMSampleBufferGetNumSamples(sample) == 0 {
                    markers += 1
                    guard markers <= document.frames.count * 4 + 16 else { throw ExportError.verificationFailed }
                    return true
                }
                guard CMSampleBufferGetNumSamples(sample) == 1, timedFrames < document.frames.count,
                      CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(timedFrames), timescale: CMTimeScale(document.fps))) == 0,
                      CMTimeCompare(CMSampleBufferGetDuration(sample), CMTime(value: 1, timescale: CMTimeScale(document.fps))) == 0 else { throw ExportError.verificationFailed }
                timedFrames += 1
                return true
            }
            if !exists { break }
            await Task.yield()
        }
        guard timingReader.status == .completed, timedFrames == document.frames.count else { throw ExportError.verificationFailed }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.verificationFailed }
        reader.add(output)
        guard reader.startReading() else { throw ExportError.verificationFailed }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var count = 0
        while true {
            try checkpoint(started)
            let exists = try autoreleasepool { () throws -> Bool in
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard count < document.frames.count, let buffer = CMSampleBufferGetImageBuffer(sample),
                      CVPixelBufferGetWidth(buffer) == document.width, CVPixelBufferGetHeight(buffer) == document.height,
                      CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: Int64(count), timescale: CMTimeScale(document.fps))) == 0 else { throw ExportError.verificationFailed }
                count += 1
                return true
            }
            if !exists { break }
            await Task.yield()
        }
        guard reader.status == .completed, count == document.frames.count else { throw ExportError.verificationFailed }
        try checkpoint(started)
    }

    enum ExportError: LocalizedError {
        case alreadyExporting, limitExceeded, unsafeDestination, transparentUnsupported, audioUnsupported, oddDimensions
        case missingRaster, invalidRaster, unsupportedContent, codecUnavailable, renderFailed, writerFailed, verificationFailed, timedOut, outputUnavailable
        case cleanupFailed(URL)
        var errorDescription: String? {
            switch self {
            case .alreadyExporting: return "A movie export is already running. Wait for it or cancel it."
            case .limitExceeded: return "This movie exceeds the current safe frame, pixel, raster or output limit. No movie was published."
            case .unsafeDestination: return "Movie export requires an existing app-owned directory without symbolic links."
            case .transparentUnsupported: return "H.264 MP4 cannot retain transparency. Explicitly choose the white background to export."
            case .audioUnsupported: return "This project contains audio. MP4 audio mixing is not available yet; no silent movie was exported."
            case .oddDimensions: return "This H.264 exporter requires even canvas dimensions. The canvas has not been resized."
            case .missingRaster: return "An original project image is missing. No movie was exported."
            case .invalidRaster: return "An original project image is corrupt, incomplete or contains multiple images. No movie was exported."
            case .unsupportedContent: return "A visible tool, color, text or blend effect cannot be faithfully rendered by this movie exporter yet."
            case .codecUnavailable: return "The H.264 encoder is unavailable for these project settings on this device."
            case .renderFailed: return "Studio could not render the complete movie frame. No movie was published."
            case .writerFailed: return "The MP4 encoder could not complete this movie. No movie was published."
            case .verificationFailed: return "The encoded movie did not pass its frame, timing or decoding checks. No movie was published."
            case .timedOut: return "The movie exporter exceeded its processing limit. No movie was published."
            case .outputUnavailable: return "These movie files are no longer available at their verified location. They were cancelled, removed or changed."
            case .cleanupFailed: return "Movie files could not be safely removed. Their location or contents may have changed; cleanup can be retried after the conflict is resolved."
            }
        }
    }
}
