import Foundation
import CryptoKit
import Darwin

@MainActor
final class StudioGIFExportService {
    enum Failure: LocalizedError {
        case destination, write, unavailable, cleanup(URL)
        var errorDescription: String? {
            switch self {
            case .destination: return "GIF needs an existing app-owned export folder without symbolic links."
            case .write: return "The GIF files could not be saved. No completed export was returned."
            case .unavailable: return "The GIF files changed or are unavailable. Create the export again before sharing."
            case .cleanup: return "Temporary GIF files need recovery. Conflicting files were preserved."
            }
        }
    }

    func export(_ snapshot: StudioGIFEncoder.Snapshot, outputParent: URL,
                progress: (StudioGIFEncoder.Progress) throws -> Void = { _ in }) async throws -> Output {
        let encoded = try await StudioGIFEncoder().encode(snapshot, progress: progress)
        try Task.checkCancellation()
        let output = try Output(encoded: encoded, parent: outputParent)
        do { try Task.checkCancellation(); return output }
        catch { try output.cleanup(); throw error }
    }

    /// Retain through the complete consumer lifetime. The handle never deletes
    /// files on deinit; explicit cleanup is serialized by the calling session.
    /// A naked URL alone is not an ownership or integrity guarantee.
    @MainActor final class Output {
        private struct Identity: Equatable {
            let device: dev_t; let inode: ino_t
            init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
        }
        private struct File {
            let descriptor: Int32
            let identity: Identity
            var bytes: Int
            var digest: SHA256.Digest
        }
        let receipt: StudioGIFEncoder.Receipt
        let parent: URL
        private var name: String
        private var parentFD: Int32 = -1
        private var directoryFD: Int32 = -1
        private var parentIdentity: Identity?
        private var directoryIdentity: Identity?
        private var files: [String: File] = [:]
        private(set) var isCleaned = false
        var directory: URL { parent.appendingPathComponent(name, isDirectory: true) }
        var gifURL: URL { directory.appendingPathComponent("animation.gif") }
        var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

        fileprivate init(encoded: StudioGIFEncoder.Encoded, parent: URL) throws {
            self.parent = parent.standardizedFileURL
            receipt = encoded.receipt
            let id = UUID().uuidString
            name = ".sdi-gif-" + id + ".partial"
            guard parent.isFileURL, !parent.path.utf8.contains(0) else { throw Failure.destination }
            var info = stat(), opened = stat()
            guard lstat(self.parent.path, &info) == 0, Self.isDirectory(info) else { throw Failure.destination }
            parentFD = Darwin.open(self.parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0, fstat(parentFD, &opened) == 0, Self.isDirectory(opened),
                  Identity(info) == Identity(opened) else { closeDescriptors(); throw Failure.destination }
            parentIdentity = Identity(opened)
            guard mkdirat(parentFD, name, 0o700) == 0 else { closeDescriptors(); throw Failure.destination }
            directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0, fstat(directoryFD, &opened) == 0, Self.isDirectory(opened) else {
                closeDescriptors(); throw Failure.cleanup(directory)
            }
            directoryIdentity = Identity(opened)
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let manifest = try encoder.encode(receipt)
                guard manifest.count <= 128 * 1024, !encoded.data.isEmpty,
                      encoded.data.count == receipt.encodedBytes,
                      encoded.data.count <= StudioGIFEncoder.maximumBytes else { throw Failure.write }
                try create("animation.gif", data: encoded.data)
                try create("manifest.json", data: manifest)
                try validate(allowMissing: false)
                let published = "SDI-GIF-" + receipt.projectID.uuidString + "-" + id
                guard renameatx_np(parentFD, name, parentFD, published, UInt32(RENAME_EXCL)) == 0 else { throw Failure.write }
                name = published
                try validate(allowMissing: false)
            } catch {
                let original = error
                do { try cleanup() } catch { throw Failure.cleanup(directory) }
                throw original
            }
        }

        func checkedURLs() throws -> [URL] {
            guard !isCleaned else { throw Failure.unavailable }
            try validate(allowMissing: false)
            return [gifURL, manifestURL]
        }

        func cleanup() throws {
            guard !isCleaned else { return }
            do {
                // Validate the whole set before removing any file. Unknown
                // entries, changed bytes, aliases or moved directories block it.
                try validate(allowMissing: true)
                for filename in files.keys.sorted() {
                    try confirmDirectory()
                    guard let file = files[filename] else { throw Failure.unavailable }
                    if try validateFile(filename, file: file, allowMissing: true) {
                        guard unlinkat(directoryFD, filename, 0) == 0 else { throw Failure.unavailable }
                    }
                }
                try confirmDirectory()
                guard try entries().isEmpty, unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw Failure.unavailable }
                isCleaned = true; closeDescriptors()
            } catch { throw Failure.cleanup(directory) }
        }

        private func create(_ filename: String, data: Data) throws {
            try confirmDirectory()
            let descriptor = openat(directoryFD, filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw Failure.write }
            var info = stat()
            guard fstat(descriptor, &info) == 0, Self.isRegular(info), info.st_nlink == 1, info.st_size == 0 else {
                _ = Darwin.close(descriptor); throw Failure.write
            }
            var record = File(descriptor: descriptor, identity: Identity(info), bytes: 0, digest: SHA256.hash(data: Data()))
            // On a short/failed write, ownership covers exactly the prefix this
            // invocation wrote; cleanup cannot adopt unexpected appended bytes.
            files[filename] = record
            defer { files[filename] = record }
            var hasher = SHA256()
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { throw Failure.write }
                while record.bytes < data.count {
                    let count = min(65_536, data.count - record.bytes)
                    let wrote = Darwin.write(descriptor, base.advanced(by: record.bytes), count)
                    if wrote < 0 && errno == EINTR { continue }
                    guard wrote > 0, wrote <= count else { throw Failure.write }
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: record.bytes), count: wrote))
                    record.bytes += wrote; record.digest = hasher.finalize()
                }
            }
            guard fsync(descriptor) == 0 else { throw Failure.write }
        }

        private func confirmDirectory() throws {
            var parentInfo = stat(), openParent = stat(), directoryInfo = stat(), openDirectory = stat()
            guard parentFD >= 0, directoryFD >= 0,
                  lstat(parent.path, &parentInfo) == 0, Self.isDirectory(parentInfo), Identity(parentInfo) == parentIdentity,
                  fstat(parentFD, &openParent) == 0, Identity(openParent) == parentIdentity,
                  fstatat(parentFD, name, &directoryInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.isDirectory(directoryInfo), Identity(directoryInfo) == directoryIdentity,
                  fstat(directoryFD, &openDirectory) == 0, Identity(openDirectory) == directoryIdentity else { throw Failure.unavailable }
        }
        private func entries() throws -> Set<String> {
            let duplicate = dup(directoryFD)
            guard duplicate >= 0 else { throw Failure.unavailable }
            guard let stream = fdopendir(duplicate) else { _ = Darwin.close(duplicate); throw Failure.unavailable }
            defer { closedir(stream) }
            rewinddir(stream)
            var names = Set<String>()
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Failure.unavailable }; return names
                }
                let filename = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if filename == "." || filename == ".." { continue }
                guard names.count < 2, files[filename] != nil else { throw Failure.unavailable }
                names.insert(filename)
            }
        }
        private func validate(allowMissing: Bool) throws {
            try confirmDirectory()
            let names = try entries()
            guard allowMissing || names == Set(files.keys) && files.count == 2 else { throw Failure.unavailable }
            for (name, file) in files { _ = try validateFile(name, file: file, allowMissing: allowMissing) }
            try confirmDirectory()
        }
        private func validateFile(_ name: String, file: File, allowMissing: Bool) throws -> Bool {
            var pathInfo = stat(), openInfo = stat()
            if fstatat(directoryFD, name, &pathInfo, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT && allowMissing { return false }
                throw Failure.unavailable
            }
            guard fstat(file.descriptor, &openInfo) == 0,
                  Self.isRegular(pathInfo), Self.isRegular(openInfo), pathInfo.st_nlink == 1, openInfo.st_nlink == 1,
                  Identity(pathInfo) == file.identity, Identity(openInfo) == file.identity,
                  pathInfo.st_size == file.bytes, openInfo.st_size == file.bytes else { throw Failure.unavailable }
            var hasher = SHA256(), offset = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while offset < file.bytes {
                let count = min(buffer.count, file.bytes - offset)
                let read = buffer.withUnsafeMutableBytes { pread(file.descriptor, $0.baseAddress, count, off_t(offset)) }
                if read < 0 && errno == EINTR { continue }
                guard read > 0, read <= count else { throw Failure.unavailable }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<read])) }
                offset += read
            }
            guard hasher.finalize() == file.digest else { throw Failure.unavailable }
            return true
        }
        private static func isDirectory(_ info: stat) -> Bool { info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
        private static func isRegular(_ info: stat) -> Bool { info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
        private func closeDescriptors() {
            for file in files.values { _ = Darwin.close(file.descriptor) }
            files.removeAll()
            if directoryFD >= 0 { _ = Darwin.close(directoryFD); directoryFD = -1 }
            if parentFD >= 0 { _ = Darwin.close(parentFD); parentFD = -1 }
        }
        deinit {
            for file in files.values { _ = Darwin.close(file.descriptor) }
            if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
            if parentFD >= 0 { _ = Darwin.close(parentFD) }
        }
    }
}
