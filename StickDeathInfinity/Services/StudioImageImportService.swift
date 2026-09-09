import Foundation
import CoreGraphics
import ImageIO
import Darwin

/// A Files-image decoding foundation, not a picker or a document mutation.
/// Callers obtain an authorized materialized URL, then recheck their project and
/// revision before attaching the returned bytes. The source URL is not retained.
actor StudioImageImportService {
    static let shared = StudioImageImportService()
    static let maximumEncodedBytes = 16 * 1024 * 1024
    static let maximumPixels = 16_777_216
    static let maximumDimension = 8192
    static let maximumNormalizedBytes = 40 * 1024 * 1024
    static let maximumContainerChunks = 4096
    private static let copyChunkBytes = 64 * 1024

    enum Container: String, Codable, Sendable { case jpeg, png, heif }
    struct Progress: Sendable {
        enum Phase: Sendable { case reading, validating, decoding, encoding }
        let phase: Phase
        let completed: Int64
        let total: Int64
    }
    struct ImportedImage: Sendable {
        let id: UUID
        let name: String
        let container: Container
        let originalData: Data
        let originalWidth: Int
        let originalHeight: Int
        let originalOrientation: Int
        let width: Int
        let height: Int
        /// Full-resolution, orientation-up, sRGB 8-bit PNG with alpha. HDR,
        /// auxiliary depth/gain maps and source metadata remain in originalData;
        /// they are not reproduced in this editable SDR raster.
        let normalizedPNG: Data
    }

    /// One process-wide lease covers encoded bytes, ImageIO decode and bounded
    /// PNG output, including across independent service instances. A 16 MP
    /// raster can occupy 64 MiB per RGBA buffer; ImageIO may also retain its own
    /// intermediate buffers. No work runs on MainActor and no source is resized.
    /// Cancellation is cooperative between phases/copy chunks/output callbacks;
    /// a synchronous ImageIO decode cannot be forcibly interrupted.
    func importImage(from sourceURL: URL, name: String? = nil,
                     scratchParent: URL = FileManager.default.temporaryDirectory,
                     progress: @Sendable (Progress) async throws -> Void = { _ in }) async throws -> ImportedImage {
        try Task.checkCancellation()
        try await StudioImageImportLease.shared.acquire()
        let result: ImportedImage
        do {
            result = try await performImport(sourceURL, name: name, scratchParent: scratchParent, progress: progress)
            try Task.checkCancellation()
        } catch {
            await StudioImageImportLease.shared.release()
            throw error
        }
        await StudioImageImportLease.shared.release()
        try Task.checkCancellation()
        return result
    }

    private func performImport(_ sourceURL: URL, name: String?, scratchParent: URL,
                               progress: @Sendable (Progress) async throws -> Void) async throws -> ImportedImage {
        guard safeFileURL(sourceURL) else { throw ImportError.unsafeSource }
        let title = (name ?? sourceURL.deletingPathExtension().lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ImportError.invalidName }
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        guard safeFileURL(scratchParent) else { throw ImportError.temporaryStorage }
        let scratch = try StudioImageImportScratch.create(in: scratchParent)
        do {
            let original = try await copySource(sourceURL, scratch: scratch, progress: progress)
            try await progress(.init(phase: .validating, completed: 0, total: 1))
            try Task.checkCancellation()
            try scratch.verify()
            let description = try inspect(original)
            try await progress(.init(phase: .decoding, completed: 0, total: 1))
            try Task.checkCancellation()
            try scratch.verify()
            let image = try decode(original, description: description)
            try await progress(.init(phase: .encoding, completed: 0, total: 1))
            try Task.checkCancellation()
            try scratch.verify()
            let png = try normalizedPNG(image)
            try Task.checkCancellation()
            let result = ImportedImage(id: UUID(), name: title, container: description.container,
                originalData: original, originalWidth: description.width, originalHeight: description.height,
                originalOrientation: description.orientation, width: image.width, height: image.height, normalizedPNG: png)
            try scratch.cleanup()
            return result
        } catch {
            let operationError = error
            do { try scratch.cleanup() }
            catch { throw ImportError.cleanupFailed(directory: scratch.directoryURL) }
            throw operationError
        }
    }

    private func safeFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "localhost") && url.query == nil
            && url.fragment == nil && !url.path.utf8.contains(0)
    }

    private func copySource(_ source: URL, scratch: StudioImageImportScratch,
                            progress: @Sendable (Progress) async throws -> Void) async throws -> Data {
        let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY)
        guard inputFD >= 0 else { throw ImportError.unsafeSource }
        defer { _ = Darwin.close(inputFD) }
        var before = stat()
        guard fstat(inputFD, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw ImportError.unsafeSource }
        guard before.st_size > 0 else { throw ImportError.invalidImage }
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
            try output.write(contentsOf: chunk); data.append(chunk)
            try await progress(.init(phase: .reading, completed: Int64(data.count), total: before.st_size))
            try scratch.verify()
            await Task.yield()
        }
        var after = stat()
        guard fstat(inputFD, &after) == 0, after.st_size == before.st_size, data.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw ImportError.sourceChanged }
        try Task.checkCancellation()
        return data
    }

    private struct Description { let container: Container; let width: Int; let height: Int; let orientation: Int }
    private func inspect(_ data: Data) throws -> Description {
        // Check common container extents before asking ImageIO to enumerate
        // metadata, keeping crafted chunk lists under the same explicit limit.
        var validated: Container?
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            try validatePNG(data); validated = .png
        } else if data.starts(with: [255, 216]) {
            try validateJPEG(data); validated = .jpeg
        } else if data.count >= 8, String(decoding: data[4..<8], as: UTF8.self) == "ftyp" {
            try validateHEIF(data); validated = .heif
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else { throw ImportError.invalidImage }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ImportError.invalidImage }
        guard count == 1 else { throw ImportError.multipleImages }
        let container: Container
        switch type {
        case "public.jpeg": container = .jpeg; if validated != .jpeg { try validateJPEG(data) }
        case "public.png": container = .png; if validated != .png { try validatePNG(data) }
        case "public.heic", "public.heif": container = .heif; if validated != .heif { try validateHEIF(data) }
        default: throw ImportError.unsupportedContainer
        }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw ImportError.invalidImage }
        func integer(_ key: CFString, fallback: Int? = nil) throws -> Int {
            if properties[key] == nil, let fallback { return fallback }
            guard let n = properties[key] as? NSNumber else { throw ImportError.invalidImage }
            let value = n.doubleValue
            guard value.isFinite, value >= 1, value <= Double(Int32.max), value.rounded() == value else { throw ImportError.invalidImage }
            return Int(value)
        }
        let width = try integer(kCGImagePropertyPixelWidth), height = try integer(kCGImagePropertyPixelHeight)
        let orientation = try integer(kCGImagePropertyOrientation, fallback: 1)
        guard (1...8).contains(orientation) else { throw ImportError.invalidImage }
        guard width <= Self.maximumDimension, height <= Self.maximumDimension,
              width <= Self.maximumPixels / height else { throw ImportError.limitExceeded }
        return .init(container: container, width: width, height: height, orientation: orientation)
    }

    private func decode(_ data: Data, description: Description) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(description.width, description.height),
                kCGImageSourceShouldAllowFloat: false,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ImportError.invalidImage }
        let swap = description.orientation >= 5
        guard image.width == (swap ? description.height : description.width),
              image.height == (swap ? description.width : description.height) else { throw ImportError.unsupportedGeometry }
        try Task.checkCancellation()
        return image
    }

    private func normalizedPNG(_ image: CGImage) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImportError.invalidImage }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else { throw ImportError.invalidImage }
        try Task.checkCancellation()
        let buffer = StudioImagePNGBuffer(limit: Self.maximumNormalizedBytes)
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            let buffer = Unmanaged<StudioImagePNGBuffer>.fromOpaque(info).takeUnretainedValue()
            if Task.isCancelled { buffer.cancelled = true; return 0 }
            guard count <= buffer.limit - buffer.data.count else { buffer.exceeded = true; return 0 }
            buffer.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(buffer).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, "public.png" as CFString, 1, nil) else { throw ImportError.invalidImage }
        CGImageDestinationAddImage(destination, normalized, [kCGImagePropertyOrientation: 1] as CFDictionary)
        let completed = CGImageDestinationFinalize(destination)
        if buffer.cancelled { throw CancellationError() }
        if buffer.exceeded { throw ImportError.limitExceeded }
        try Task.checkCancellation()
        guard completed, !buffer.data.isEmpty else { throw ImportError.invalidImage }
        return buffer.data
    }

    /// ImageIO can recover partial images. Reject damaged declared extents and
    /// PNG checksums before decoding, and never flatten APNG into its first frame.
    private func validatePNG(_ data: Data) throws {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw ImportError.invalidImage }
        var offset = 8, chunks = 0, sawData = false, ended = false
        while offset < data.count {
            try Task.checkCancellation(); chunks += 1
            guard chunks <= Self.maximumContainerChunks else { throw ImportError.limitExceeded }
            guard data.count - offset >= 12 else { throw ImportError.invalidImage }
            let length = big32(data, offset), body = offset + 4
            guard length <= data.count - offset - 12 else { throw ImportError.invalidImage }
            let type = String(decoding: data[body..<(body + 4)], as: UTF8.self)
            if ["acTL", "fcTL", "fdAT"].contains(type) { throw ImportError.multipleImages }
            guard chunks == 1 ? (type == "IHDR" && length == 13) : type != "IHDR" else { throw ImportError.invalidImage }
            var crc = UInt32.max
            for index in body..<(body + 4 + length) {
                if index % Self.copyChunkBytes == 0 { try Task.checkCancellation() }
                crc = Self.crcTable[Int((crc ^ UInt32(data[index])) & 255)] ^ (crc >> 8)
            }
            guard Int(crc ^ UInt32.max) == big32(data, body + 4 + length) else { throw ImportError.invalidImage }
            if type == "IDAT" { sawData = true }
            offset += length + 12
            if type == "IEND" {
                guard length == 0, offset == data.count, sawData else { throw ImportError.invalidImage }
                ended = true; break
            }
        }
        guard ended else { throw ImportError.invalidImage }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private func big32(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
    }

    private func validateJPEG(_ data: Data) throws {
        guard data.starts(with: [255, 216]) else { throw ImportError.invalidImage }
        var offset = 2, markers = 0, inScan = false, sawScan = false
        while offset < data.count {
            if offset % Self.copyChunkBytes == 0 { try Task.checkCancellation() }
            if inScan && data[offset] != 255 { offset += 1; continue }
            guard data[offset] == 255 else { throw ImportError.invalidImage }
            repeat { offset += 1 } while offset < data.count && data[offset] == 255
            guard offset < data.count else { throw ImportError.invalidImage }
            let marker = data[offset]; offset += 1
            if inScan && (marker == 0 || (208...215).contains(marker)) { continue }
            inScan = false; markers += 1
            guard markers <= Self.maximumContainerChunks else { throw ImportError.limitExceeded }
            if marker == 217 {
                guard sawScan, offset == data.count else { throw ImportError.invalidImage }
                return
            }
            guard marker != 0, marker != 216, !(208...215).contains(marker), data.count - offset >= 2 else { throw ImportError.invalidImage }
            let length = Int(data[offset]) * 256 + Int(data[offset + 1])
            guard length >= 2, length <= data.count - offset else { throw ImportError.invalidImage }
            offset += length
            if marker == 218 { inScan = true; sawScan = true }
        }
        throw ImportError.invalidImage
    }

    private func validateHEIF(_ data: Data) throws {
        var offset = 0, boxes = 0, sawType = false
        while offset < data.count {
            try Task.checkCancellation(); boxes += 1
            guard boxes <= Self.maximumContainerChunks else { throw ImportError.limitExceeded }
            guard data.count - offset >= 8 else { throw ImportError.invalidImage }
            var length = big32(data, offset), header = 8
            if length == 1 {
                guard data.count - offset >= 16, big32(data, offset + 8) == 0 else { throw ImportError.invalidImage }
                length = big32(data, offset + 12); header = 16
            } else if length == 0 { length = data.count - offset }
            guard length >= header, length <= data.count - offset else { throw ImportError.invalidImage }
            if String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self) == "ftyp" { sawType = true }
            offset += length
        }
        guard sawType else { throw ImportError.invalidImage }
    }

    enum ImportError: LocalizedError {
        case unsafeSource, sourceChanged, invalidName, invalidImage, unsupportedContainer, unsupportedGeometry
        case multipleImages, limitExceeded, busy, temporaryStorage, cleanupFailed(directory: URL)
        var errorDescription: String? {
            switch self {
            case .unsafeSource: return "Choose an accessible regular image file from Files. Links and remote URLs cannot be imported."
            case .sourceChanged: return "The image changed while being read. Select the finished file and try again."
            case .invalidName: return "Use an image name from 1 to 120 characters without control characters."
            case .invalidImage: return "This file could not be decoded completely as an image. No image was added."
            case .unsupportedContainer: return "Choose a still JPEG, PNG or HEIF image. This image format is not supported."
            case .unsupportedGeometry: return "This image's pixel geometry cannot be preserved by the current importer. No image was added."
            case .multipleImages: return "This file contains multiple images or animation. Importing only its first image would lose content, so no image was added."
            case .limitExceeded: return "Image import supports up to 16 MB encoded, 16,777,216 pixels, 8,192 pixels per side and 40 MB normalized PNG. No image was added."
            case .busy: return "Another image import is running. Wait for it to finish or cancel it."
            case .temporaryStorage: return "Temporary image storage is unavailable. No image was added."
            case .cleanupFailed: return "The temporary image copy could not be removed. No image was added; cleanup needs attention."
            }
        }
    }
}

/// Scoped to one actor operation. File descriptors bind cleanup to the directory
/// we created, even across asynchronous progress callbacks. Unknown entries and
/// replaced paths are never recursively removed; failure leaves them for review.
private final class StudioImageImportScratch {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }
    let directoryURL: URL
    private let parentURL: URL
    private let directoryName: String
    private let parentIdentity: Identity
    private let directoryIdentity: Identity
    private let parentFD: Int32
    private let directoryFD: Int32
    private var sourceIdentity: Identity?
    private var cleaned = false
    private static let filename = "source.image"

    static func create(in parentURL: URL) throws -> StudioImageImportScratch {
        var parent = stat()
        guard lstat(parentURL.path, &parent) == 0, isDirectory(parent) else {
            throw StudioImageImportService.ImportError.temporaryStorage
        }
        let canonical = parentURL.resolvingSymlinksInPath().standardizedFileURL
        let parentFD = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw StudioImageImportService.ImportError.temporaryStorage }
        var openedParent = stat()
        guard fstat(parentFD, &openedParent) == 0, Identity(parent) == Identity(openedParent) else {
            _ = Darwin.close(parentFD); throw StudioImageImportService.ImportError.temporaryStorage
        }
        let name = ".sdi-image-import-" + UUID().uuidString
        let directoryURL = canonical.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(parentFD, name, 0o700) == 0 else {
            _ = Darwin.close(parentFD); throw StudioImageImportService.ImportError.temporaryStorage
        }
        let directoryFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var directory = stat()
        guard directoryFD >= 0, fstat(directoryFD, &directory) == 0, isDirectory(directory) else {
            if directoryFD >= 0 { _ = Darwin.close(directoryFD) }
            _ = Darwin.close(parentFD)
            // Without an opened identity we cannot safely remove the new entry.
            throw StudioImageImportService.ImportError.cleanupFailed(directory: directoryURL)
        }
        return StudioImageImportScratch(parentURL: canonical, directoryName: name,
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
        guard sourceIdentity == nil else { throw StudioImageImportService.ImportError.temporaryStorage }
        let fd = openat(directoryFD, Self.filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StudioImageImportService.ImportError.temporaryStorage }
        var file = stat()
        guard fstat(fd, &file) == 0, Self.isRegular(file) else {
            _ = Darwin.close(fd); throw StudioImageImportService.ImportError.temporaryStorage
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
    private var failure: StudioImageImportService.ImportError { .cleanupFailed(directory: directoryURL) }
    private static func isDirectory(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    private static func isRegular(_ value: stat) -> Bool { value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    deinit { _ = Darwin.close(directoryFD); _ = Darwin.close(parentFD) }
}

private final class StudioImagePNGBuffer {
    let limit: Int
    var data = Data()
    var exceeded = false
    var cancelled = false
    init(limit: Int) { self.limit = limit }
}

private actor StudioImageImportLease {
    static let shared = StudioImageImportLease()
    private var busy = false
    func acquire() throws {
        guard !busy else { throw StudioImageImportService.ImportError.busy }
        busy = true
    }
    func release() { busy = false }
}
