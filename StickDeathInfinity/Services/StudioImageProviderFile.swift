import Foundation
import Darwin

/// Owns a bounded copy made synchronously inside an NSItemProvider file callback.
/// The provider may remove its URL as soon as that callback returns. Hold this
/// handle until the asynchronous image import finishes, then call cleanup().
/// This copies bytes; only StudioImageImportService validates image content.
final class StudioImageProviderFile: @unchecked Sendable {
    static let maximumEncodedBytes = StudioImageImportService.maximumEncodedBytes
    static let copyChunkBytes = 64 * 1024

    let displayName: String
    let fileExtension: String?
    private let directoryURL: URL
    private let parentURL: URL
    private let directoryName: String
    private let filename: String
    private let parentIdentity: Identity
    private let directoryIdentity: Identity
    private var fileIdentity: Identity?
    private var parentFD: Int32
    private var directoryFD: Int32
    private var cleaned = false
    private var cancelled = false
    private let lock = NSLock()
    private let abandonedCleanupFailure: @Sendable (Error) -> Void

    struct CopyProgress { let completed: Int64; let total: Int64 }
    enum Failure: LocalizedError {
        case unsafeSource, sourceChanged, invalidName, invalidExtension, limitExceeded
        case temporaryStorage, copyFailed, unavailable, cleanupFailed
        case operationAndCleanupFailed(operation: Error)
        var errorDescription: String? {
            switch self {
            case .unsafeSource: return "The selected image must be an accessible regular file. Links cannot be copied."
            case .sourceChanged: return "The selected image changed during transfer. Select the completed file again."
            case .invalidName: return "The image name must contain 1 to 120 characters without path separators or control characters."
            case .invalidExtension: return "The image filename extension is invalid."
            case .limitExceeded: return "The selected image must contain between 1 byte and 16 MB of encoded data."
            case .temporaryStorage: return "Private temporary image storage is unavailable."
            case .copyFailed: return "The image could not be copied completely. No image was added."
            case .unavailable: return "This temporary image transfer is no longer available."
            case .cleanupFailed: return "The owned temporary image could not be safely removed. Cleanup needs attention."
            case .operationAndCleanupFailed: return "The image transfer failed and its owned temporary copy could not be safely removed. Cleanup needs attention."
            }
        }
    }

    /// `isCancelled` can combine the returned NSProgress.isCancelled with the
    /// import session's cancellation flag. It is checked between bounded reads,
    /// writes and completion, including after the final progress callback.
    static func materialize(from sourceURL: URL, suggestedName: String? = nil,
                            fileExtension: String? = nil,
                            scratchParent: URL = FileManager.default.temporaryDirectory,
                            isCancelled: () -> Bool = { Task.isCancelled },
                            progress: (CopyProgress) throws -> Void = { _ in },
                            abandonedCleanupFailure: @escaping @Sendable (Error) -> Void = {
                                NSLog("StickDeath image transfer cleanup requires attention: %@", $0.localizedDescription)
                            }) throws -> StudioImageProviderFile {
        func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
        try checkCancellation()
        guard safeURL(sourceURL) else { throw Failure.unsafeSource }
        let name = (suggestedName ?? sourceURL.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, name.utf8.count <= 480, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalidName }
        let suffix = fileExtension ?? sourceURL.pathExtension
        guard suffix.utf8.count <= 12, suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw Failure.invalidExtension
        }
        let normalizedExtension = suffix.isEmpty ? nil : suffix.lowercased()
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let sourceFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard sourceFD >= 0 else { throw Failure.unsafeSource }
        defer { _ = Darwin.close(sourceFD) }
        var before = stat()
        guard fstat(sourceFD, &before) == 0, isRegular(before) else { throw Failure.unsafeSource }
        guard before.st_size > 0, before.st_size <= maximumEncodedBytes else { throw Failure.limitExceeded }
        try checkCancellation()
        let owned = try create(scratchParent: scratchParent, displayName: name,
                               fileExtension: normalizedExtension, abandonedCleanupFailure: abandonedCleanupFailure)
        do {
            let outputFD = openat(owned.directoryFD, owned.filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw Failure.temporaryStorage }
            defer { _ = Darwin.close(outputFD) }
            var outputStat = stat()
            guard fstat(outputFD, &outputStat) == 0, isRegular(outputStat) else { throw Failure.temporaryStorage }
            owned.fileIdentity = Identity(outputStat)
            var buffer = [UInt8](repeating: 0, count: copyChunkBytes)
            var copied = 0
            while true {
                try checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw Failure.copyFailed }
                if count == 0 { break }
                guard count <= maximumEncodedBytes - copied else { throw Failure.limitExceeded }
                var written = 0
                while written < count {
                    try checkCancellation()
                    let amount = buffer.withUnsafeBytes { Darwin.write(outputFD, $0.baseAddress!.advanced(by: written), count - written) }
                    if amount < 0 { if errno == EINTR { continue }; throw Failure.copyFailed }
                    guard amount > 0 else { throw Failure.copyFailed }
                    written += amount
                }
                copied += count
                try progress(CopyProgress(completed: Int64(copied), total: before.st_size))
            }
            try checkCancellation()
            var after = stat(), pathAfter = stat(), outputAfter = stat()
            guard fstat(sourceFD, &after) == 0, lstat(sourceURL.path, &pathAfter) == 0,
                  isRegular(pathAfter), Identity(before) == Identity(after), Identity(before) == Identity(pathAfter),
                  before.st_size == after.st_size, before.st_size == pathAfter.st_size, copied == before.st_size,
                  unchangedTimes(before, after), unchangedTimes(before, pathAfter) else { throw Failure.sourceChanged }
            guard fsync(outputFD) == 0, fstat(outputFD, &outputAfter) == 0,
                  Identity(outputAfter) == owned.fileIdentity, outputAfter.st_size == copied else { throw Failure.copyFailed }
            try checkCancellation()
            _ = try owned.url()
            return owned
        } catch {
            let operation = error
            do { try owned.cleanup() }
            catch { throw Failure.operationAndCleanupFailed(operation: operation) }
            throw operation
        }
    }

    /// Checked at each handoff. Do not cancel/clean while a consumer still needs
    /// the URL: cancel its task first and await that task before normal cleanup.
    func url() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !cleaned else { throw Failure.unavailable }
        var parent = stat(), file = stat()
        guard lstat(parentURL.path, &parent) == 0, Identity(parent) == parentIdentity,
              try directoryStillOwned(),
              fstatat(directoryFD, filename, &file, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isRegular(file), Identity(file) == fileIdentity else { throw Failure.unavailable }
        return directoryURL.appendingPathComponent(filename)
    }

    /// Idempotent on success; failed cleanup is retryable. Never recursively
    /// removes a directory, follows a replaced file, or removes an unknown entry.
    func cleanup() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cleaned else { return }
        guard try directoryStillOwned() else { throw Failure.cleanupFailed }
        var file = stat()
        let present = fstatat(directoryFD, filename, &file, AT_SYMLINK_NOFOLLOW)
        if present == 0 {
            guard Self.isRegular(file), let expected = fileIdentity, Identity(file) == expected else { throw Failure.cleanupFailed }
            guard unlinkat(directoryFD, filename, 0) == 0 else { throw Failure.cleanupFailed }
        } else if errno != ENOENT { throw Failure.cleanupFailed }
        guard unlinkat(parentFD, directoryName, AT_REMOVEDIR) == 0 else { throw Failure.cleanupFailed }
        cleaned = true
        _ = Darwin.close(directoryFD); directoryFD = -1
        _ = Darwin.close(parentFD); parentFD = -1
    }

    /// Marks the handle unavailable and attempts the same safe owned cleanup.
    /// The caller must also cancel any active image-decoder task.
    func cancel() throws {
        lock.lock(); cancelled = true; lock.unlock()
        try cleanup()
    }

    private func directoryStillOwned() throws -> Bool {
        var child = stat(), descriptor = stat()
        guard parentFD >= 0, directoryFD >= 0,
              fstatat(parentFD, directoryName, &child, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(directoryFD, &descriptor) == 0,
              Self.isDirectory(child), Identity(child) == directoryIdentity,
              Identity(descriptor) == directoryIdentity else { throw Failure.cleanupFailed }
        return true
    }

    private static func create(scratchParent: URL, displayName: String, fileExtension: String?,
                               abandonedCleanupFailure: @escaping @Sendable (Error) -> Void) throws -> StudioImageProviderFile {
        guard safeURL(scratchParent) else { throw Failure.temporaryStorage }
        var parent = stat()
        guard lstat(scratchParent.path, &parent) == 0, isDirectory(parent) else { throw Failure.temporaryStorage }
        let canonical = scratchParent.resolvingSymlinksInPath().standardizedFileURL
        let parentFD = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw Failure.temporaryStorage }
        var openedParent = stat()
        guard fstat(parentFD, &openedParent) == 0, Identity(parent) == Identity(openedParent) else {
            _ = Darwin.close(parentFD); throw Failure.temporaryStorage
        }
        let directoryName = ".sdi-provider-image-" + UUID().uuidString
        guard mkdirat(parentFD, directoryName, 0o700) == 0 else { _ = Darwin.close(parentFD); throw Failure.temporaryStorage }
        let directoryFD = openat(parentFD, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var directory = stat()
        guard directoryFD >= 0, fstat(directoryFD, &directory) == 0, isDirectory(directory) else {
            if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
            // We cannot prove ownership without the opened directory identity;
            // leave the fresh entry alone and surface the cleanup obligation.
            _ = Darwin.close(parentFD); throw Failure.operationAndCleanupFailed(operation: Failure.temporaryStorage)
        }
        return StudioImageProviderFile(parentFD: parentFD, directoryFD: directoryFD,
            parentURL: canonical, parentIdentity: Identity(openedParent), directoryIdentity: Identity(directory),
            directoryName: directoryName, displayName: displayName, fileExtension: fileExtension,
            abandonedCleanupFailure: abandonedCleanupFailure)
    }

    private init(parentFD: Int32, directoryFD: Int32, parentURL: URL, parentIdentity: Identity,
                 directoryIdentity: Identity, directoryName: String, displayName: String, fileExtension: String?,
                 abandonedCleanupFailure: @escaping @Sendable (Error) -> Void) {
        self.parentFD = parentFD; self.directoryFD = directoryFD; self.parentURL = parentURL
        self.parentIdentity = parentIdentity; self.directoryIdentity = directoryIdentity
        self.directoryName = directoryName; directoryURL = parentURL.appendingPathComponent(directoryName, isDirectory: true)
        self.displayName = displayName; self.fileExtension = fileExtension
        filename = "image" + (fileExtension.map { "." + $0 } ?? "")
        self.abandonedCleanupFailure = abandonedCleanupFailure
    }

    deinit {
        do { try cleanup() } catch { abandonedCleanupFailure(error) }
        if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
        if parentFD >= 0 { _ = Darwin.close(parentFD) }
    }

    private struct Identity: Equatable {
        let device: dev_t; let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    private static func safeURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "localhost") && url.query == nil
            && url.fragment == nil && !url.path.utf8.contains(0)
    }
    private static func isRegular(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    private static func isDirectory(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    private static func unchangedTimes(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
