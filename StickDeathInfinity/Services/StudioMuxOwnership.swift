import Foundation
import CryptoKit
import AVFoundation
import Darwin

// Complete descriptor ownership implementations derive from the frozen private
// movie identity-transfer correction. Names/access/error namespace are adapted;
// mux adds only callback/await validation for its currently captured file set.
    struct StudioMuxCreatedIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
        let links: nlink_t
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino
            kind = value.st_mode & mode_t(S_IFMT); links = value.st_nlink
        }
    }
    struct StudioMuxPublicationIdentity {
        let parent: StudioMuxCreatedIdentity
        let directory: StudioMuxCreatedIdentity
        let files: [String: StudioMuxCreatedIdentity]
    }

    @MainActor final class StudioMuxOutputOwnership {
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
             movieBytes: Int, manifestData: Data, original: StudioMuxPublicationIdentity) throws {
            guard Set(original.files.keys) == Set(["animation.mp4", "manifest.json"]) else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            parentURL = parent; name = staging.lastPathComponent
            var parentInfo = stat()
            guard lstat(parent.path, &parentInfo) == 0, Self.directory(parentInfo) else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            let openedParent = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard openedParent >= 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            var parentOpenedInfo = stat()
            guard fstat(openedParent, &parentOpenedInfo) == 0, Self.directory(parentOpenedInfo),
                  Identity(parentInfo) == Identity(parentOpenedInfo), StudioMuxCreatedIdentity(parentOpenedInfo) == original.parent else {
                _ = Darwin.close(openedParent); throw StudioAudioVideoMuxService.MuxError.unsafeDestination
            }
            let openedDirectory = openat(openedParent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var directoryInfo = stat()
            guard openedDirectory >= 0, fstat(openedDirectory, &directoryInfo) == 0, Self.directory(directoryInfo),
                  StudioMuxCreatedIdentity(directoryInfo) == original.directory else {
                if openedDirectory >= 0 { _ = Darwin.close(openedDirectory) }
                _ = Darwin.close(openedParent); throw StudioAudioVideoMuxService.MuxError.unsafeDestination
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
                    guard fd >= 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                    var info = stat()
                    guard fstat(fd, &info) == 0, Self.regular(info), info.st_nlink == 1, info.st_size == size,
                          StudioMuxCreatedIdentity(info) == original.files[filename] else {
                        _ = Darwin.close(fd); throw StudioAudioVideoMuxService.MuxError.unsafeDestination
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
                  destination.lastPathComponent != name else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            try validateFiles(allowMissing: false)
            // RENAME_EXCL refuses both an existing file and an existing empty
            // directory; publication never overwrites a collision.
            guard renameatx_np(parentFD, name, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                throw StudioAudioVideoMuxService.MuxError.unsafeDestination
            }
            name = destination.lastPathComponent
            try validateFiles(allowMissing: false)
        }
        func validateForUse() throws {
            guard !cleaned, !cancelled else { throw StudioAudioVideoMuxService.MuxError.outputUnavailable }
            do { try validateFiles(allowMissing: false) }
            catch { throw StudioAudioVideoMuxService.MuxError.outputUnavailable }
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
                    guard let record = files[filename] else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                    if try fileStillOwned(filename, record: record, allowMissing: true) {
                        guard unlinkat(directoryFD, filename, 0) == 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                    }
                }
                try confirmDirectories()
                guard try entries().isEmpty else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                cleaned = true; closeDescriptors()
            } catch { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(currentURL) }
        }
        private func confirmDirectories() throws {
            var pathParent = stat(), parent = stat(), pathDirectory = stat(), directory = stat()
            guard parentFD >= 0, directoryFD >= 0,
                  lstat(parentURL.path, &pathParent) == 0, Self.directory(pathParent), Identity(pathParent) == parentIdentity,
                  fstat(parentFD, &parent) == 0, Identity(parent) == parentIdentity,
                  fstatat(parentFD, name, &pathDirectory, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.directory(pathDirectory), Identity(pathDirectory) == directoryIdentity,
                  fstat(directoryFD, &directory) == 0, Identity(directory) == directoryIdentity else {
                throw StudioAudioVideoMuxService.MuxError.unsafeDestination
            }
        }
        private func validateFiles(allowMissing: Bool) throws {
            try confirmDirectories()
            let names = try entries()
            guard names.isSubset(of: Set(files.keys)), allowMissing || names == Set(files.keys) else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            for (filename, record) in files {
                _ = try fileStillOwned(filename, record: record, allowMissing: allowMissing)
            }
            try confirmDirectories()
        }
        private func entries() throws -> Set<String> {
            let duplicate = dup(directoryFD)
            guard duplicate >= 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            guard let stream = fdopendir(duplicate) else { _ = Darwin.close(duplicate); throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            defer { closedir(stream) }
            rewinddir(stream)
            var result = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                    return result
                }
                let filename = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if filename == "." || filename == ".." { continue }
                guard result.count < 2, files[filename] != nil else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                result.insert(filename)
            }
        }
        private func fileStillOwned(_ name: String, record: FileRecord, allowMissing: Bool) throws -> Bool {
            var pathInfo = stat()
            if fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                if allowMissing && errno == ENOENT { return false }
                throw StudioAudioVideoMuxService.MuxError.unsafeDestination
            }
            var before = stat()
            guard Self.regular(pathInfo), pathInfo.st_nlink == 1, Identity(pathInfo) == record.identity,
                  pathInfo.st_size == record.bytes, fstat(record.fd, &before) == 0,
                  Identity(before) == record.identity, before.st_size == record.bytes else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
            var digest = SHA256(), offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while offset < record.bytes {
                let amount = min(buffer.count, Int(record.bytes - offset))
                let count = buffer.withUnsafeMutableBytes { pread(record.fd, $0.baseAddress, amount, off_t(offset)) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StudioAudioVideoMuxService.MuxError.unsafeDestination }
                digest.update(data: Data(buffer.prefix(count))); offset += Int64(count)
            }
            var after = stat(), pathAfter = stat()
            guard fstat(record.fd, &after) == 0, fstatat(directoryFD, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.regular(pathAfter), pathAfter.st_nlink == 1, Identity(after) == record.identity,
                  Identity(pathAfter) == record.identity, after.st_size == record.bytes, pathAfter.st_size == record.bytes,
                  Self.sameTimes(before, after), Self.sameTimes(after, pathAfter), digest.finalize() == record.digest else {
                throw StudioAudioVideoMuxService.MuxError.unsafeDestination
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
    @MainActor final class StudioMuxEncodingOwnership {
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
                throw StudioAudioVideoMuxService.MuxError.cleanupFailed(staging)
            }
            let directoryFD = openat(parentFD, staging.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var directoryInfo = stat()
            guard directoryFD >= 0, fstat(directoryFD, &directoryInfo) == 0 else {
                if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
                _ = Darwin.close(parentFD)
                throw StudioAudioVideoMuxService.MuxError.cleanupFailed(staging)
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
                    guard count > 0 else { throw StudioAudioVideoMuxService.MuxError.writerFailed }
                    offset += count
                }
            }
        }
        private func retainCreatedFile(_ fd: Int32, name: String) throws {
            var info = stat()
            guard fd >= 0, files[name] == nil, fstat(fd, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                if fd >= 0 { _ = Darwin.close(fd) }
                throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL)
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
                throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL)
            }
        }
        private func presentAndOwned(_ name: String, record: FileRecord) throws -> Bool {
            var current = stat(), opened = stat()
            if fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return false }
                throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL)
            }
            guard current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                  Identity(current) == record.identity, fstat(record.fd, &opened) == 0,
                  Identity(opened) == record.identity else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
            return true
        }
        private func hasUnknownEntry() throws -> Bool {
            let duplicate = dup(directoryFD)
            guard duplicate >= 0 else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
            guard let stream = fdopendir(duplicate) else {
                _ = Darwin.close(duplicate); throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL)
            }
            defer { closedir(stream) }
            rewinddir(stream)
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
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
        /// Check every currently captured file after callbacks/awaits during
        /// muxing; final publication additionally transfers these identities.
        func validateKnownFiles() throws {
            try confirmDirectories()
            for (name, record) in files {
                guard try presentAndOwned(name, record: record) else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
            }
        }

        /// Validate paths against the descriptors retained at writer start and
        /// exclusive manifest creation, then carry those same identities into
        /// the final owner's reopened descriptors. No callback or suspension
        /// occurs during this transfer, and the constructor rechecks identity.
        func publicationIdentity() throws -> StudioMuxPublicationIdentity {
            try confirmDirectories()
            guard Set(files.keys) == Set(["animation.mp4", "manifest.json"]) else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
            var parent = stat(), directory = stat()
            guard fstat(parentFD, &parent) == 0, Identity(parent) == parentIdentity,
                  fstat(directoryFD, &directory) == 0, Identity(directory) == directoryIdentity else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
            var captured: [String: StudioMuxCreatedIdentity] = [:]
            for (name, record) in files {
                guard try presentAndOwned(name, record: record) else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
                var info = stat()
                guard fstat(record.fd, &info) == 0, Identity(info) == record.identity,
                      info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
                captured[name] = StudioMuxCreatedIdentity(info)
            }
            try confirmDirectories()
            return StudioMuxPublicationIdentity(parent: StudioMuxCreatedIdentity(parent), directory: StudioMuxCreatedIdentity(directory), files: captured)
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
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
                }
            }
            // Whole-set validation precedes the first deletion. No suspension or
            // caller callback occurs between this check and descriptor cleanup.
            try confirmDirectories()
            for (name, record) in files { _ = try presentAndOwned(name, record: record) }
            guard try !hasUnknownEntry() else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
            for name in files.keys.sorted() {
                try confirmDirectories()
                if try presentAndOwned(name, record: files[name]!) {
                    guard unlinkat(directoryFD, name, 0) == 0 else { throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL) }
                }
            }
            try confirmDirectories()
            guard try !hasUnknownEntry(), unlinkat(parentFD, stagingURL.lastPathComponent, AT_REMOVEDIR) == 0 else {
                throw StudioAudioVideoMuxService.MuxError.cleanupFailed(stagingURL)
            }
        }
    }
