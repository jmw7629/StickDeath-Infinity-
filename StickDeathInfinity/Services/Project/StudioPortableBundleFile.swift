import Foundation
import Darwin

/// Bounded read of a backup chosen in Files, without following links (#170).
/// Same rules as the Studio import path: a local regular file, at most
/// `DeviceStorageManager.maximumPortableBundleBytes`, unchanged while read,
/// cancellable between chunks. Reading never modifies the source file.
enum StudioPortableBundleFile {
    enum Failure: LocalizedError, Equatable {
        case notLocal, unavailable, notRegularOrTooLarge, incomplete, changed
        var errorDescription: String? {
            switch self {
            case .notLocal: return "Choose a local project backup file."
            case .unavailable: return "The project file is unavailable or is a link."
            case .notRegularOrTooLarge: return "The backup must be a regular file within the project size limit."
            case .incomplete: return "The project file changed or could not be read completely."
            case .changed: return "The project file changed during transfer. Select it again."
            }
        }
    }

    static func read(_ url: URL, maximumBytes: Int = DeviceStorageManager.maximumPortableBundleBytes,
                     checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Data {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw Failure.notLocal }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= Int64(maximumBytes) else { throw Failure.notRegularOrTooLarge }
        let size = Int(before.st_size)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        data.reserveCapacity(size)
        while data.count < size {
            try checkCancellation()
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, size - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.incomplete }
            data.append(buffer, count: count)
        }
        var after = stat(), extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0, fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw Failure.changed
        }
        try checkCancellation()
        return data
    }
}
