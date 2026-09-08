import Foundation
import CoreData
import CryptoKit

/// Device-first storage architecture for StickDeath ∞
/// All user data (animations, messages, videos, calls, media) stored on-device.
/// Server only handles: auth tokens, challenge metadata, matchmaking, leaderboards.
///
/// Storage hierarchy:
///   ~/Documents/Animations/       — .sdi animation project bundles
///   ~/Documents/Media/            — photos, videos, audio files
///   ~/Documents/Messages/         — encrypted message archives (SQLite)
///   ~/Library/Caches/AI/          — Spatter AI cached responses
///   ~/Library/Caches/Thumbnails/  — generated thumbnails
///   Core Data store               — projects metadata, frame data, layer data, user prefs
///
/// Sync strategy: Device → server only sends:
///   - User profile (handle, avatar, plan)
///   - Challenge entries (animation thumbnail + metadata, not full project)
///   - Leaderboard scores
///   - Presence/online status for collab rooms

class DeviceStorageManager {
    static let shared = DeviceStorageManager()
    private let suppliedDocumentsDirectory: URL?
    private let suppliedCachesDirectory: URL?

    init(documentsDirectory: URL? = nil, cachesDirectory: URL? = nil) {
        suppliedDocumentsDirectory = documentsDirectory
        suppliedCachesDirectory = cachesDirectory
    }
    
    // MARK: - Directory paths
    
    var animationsDir: URL {
        documentsDir.appendingPathComponent("Animations", isDirectory: true)
    }
    
    var mediaDir: URL {
        documentsDir.appendingPathComponent("Media", isDirectory: true)
    }
    
    var messagesDir: URL {
        documentsDir.appendingPathComponent("Messages", isDirectory: true)
    }
    
    var aiCacheDir: URL {
        cachesDir.appendingPathComponent("AI", isDirectory: true)
    }
    
    var thumbnailsDir: URL {
        cachesDir.appendingPathComponent("Thumbnails", isDirectory: true)
    }
    
    private var documentsDir: URL {
        suppliedDocumentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private var cachesDir: URL {
        suppliedCachesDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }
    
    // MARK: - Initialization
    
    func setupDirectories() {
        let dirs = [animationsDir, mediaDir, messagesDir, aiCacheDir, thumbnailsDir]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Storage metrics
    
    func deviceStorageUsed() -> Int64 {
        let dirs = [animationsDir, mediaDir, messagesDir]
        var total: Int64 = 0
        for dir in dirs {
            total += directorySize(url: dir)
        }
        return total
    }
    
    func deviceStorageAvailable() -> Int64 {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }
    
    func formattedStorageUsed() -> String {
        let bytes = deviceStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func directorySize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
    
    // MARK: - Animation Projects (on-device)

    private static let maximumSnapshotBytes = 64 * 1024 * 1024
    private static let maximumPayloadBytes = 40 * 1024 * 1024
    private static let maximumAssetBytes = 32 * 1024 * 1024
    private static let storageMarker = Data("SDI-ANIMATION-REVISIONS-1\n".utf8)
    // Serializes all instances in this process, including read/list against a
    // commit. Callers still own edit-generation ordering and save acknowledgments.
    private static let operationLock = NSRecursiveLock()

    private struct Revision: Codable {
        let version: Int
        let project: AnimationProject
    }

    private struct CurrentRevision: Codable {
        let version: Int
        let revision: UUID
    }

    /// Existing raster/audio files are immutable research/user inputs. New saves
    /// write a complete revision, then atomically select it. An interrupted save
    /// can leave an unselected revision, but never a partially selected document.
    func saveAnimation(_ project: AnimationProject) throws {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        try validate(project, exactFrameCount: true)
        let data = try JSONEncoder().encode(Revision(version: 1, project: project))
        guard data.count <= Self.maximumSnapshotBytes else { throw AnimationStorageError.limitExceeded }
        try checkedDirectory(animationsDir, create: true)
        let projectDir = animationsDir.appendingPathComponent(project.id.uuidString, isDirectory: true)
        if itemExists(projectDir) {
            try checkedDirectory(projectDir)
            let contents = try FileManager.default.contentsOfDirectory(atPath: projectDir.path)
            if !contents.isEmpty {
                // Validate an existing identity/legacy collision before selecting
                // a new revision over it; do not silently adopt another bundle.
                let storage = projectDir.appendingPathComponent(".sdi", isDirectory: true)
                if itemExists(storage), !itemExists(storage.appendingPathComponent("current.json")) {
                    // Retry using the caller's complete in-memory document after
                    // first-save or legacy-migration pointer publication failed.
                    // Reads remain fail-closed when unselected revisions exist.
                    _ = try revisionDirectory(projectDir, create: false)
                    if contents != [".sdi"] {
                        _ = try loadLegacyAnimation(id: project.id, directory: projectDir)
                    }
                } else {
                    _ = try loadAnimation(id: project.id)
                }
            }
        }
        try checkedDirectory(projectDir, create: true)
        let storage = try revisionDirectory(projectDir, create: true)
        let revisions = storage.appendingPathComponent("revisions", isDirectory: true)
        let revision = UUID()
        let destination = revisions.appendingPathComponent(revision.uuidString + ".json")
        try data.write(to: destination, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: destination)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let pointer = storage.appendingPathComponent("current.json")
        if itemExists(pointer) { _ = try checkedFile(pointer, maximumBytes: 1024) }
        let current = try JSONEncoder().encode(CurrentRevision(version: 1, revision: revision))
        try commitCurrentRevision(current, to: pointer)
    }

    /// Filesystem failure seam for production-store tests. The default commit
    /// uses Foundation's atomic replacement; no document mutation follows it.
    func commitCurrentRevision(_ data: Data, to pointer: URL) throws {
        try data.write(to: pointer, options: .atomic)
    }

    func loadAnimation(id: UUID) throws -> AnimationProject? {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        guard itemExists(animationsDir) else { return nil }
        try checkedDirectory(animationsDir)
        let directory = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard itemExists(directory) else { return nil }
        try checkedDirectory(directory)
        let storage = directory.appendingPathComponent(".sdi", isDirectory: true)
        if itemExists(storage) {
            _ = try revisionDirectory(directory, create: false)
            let pointer = storage.appendingPathComponent("current.json")
            if itemExists(pointer) {
                let current = try JSONDecoder().decode(CurrentRevision.self, from: checkedFile(pointer, maximumBytes: 1024))
                guard current.version == 1 else { throw AnimationStorageError.unsupportedVersion }
                let file = storage.appendingPathComponent("revisions/" + current.revision.uuidString + ".json")
                let revision = try JSONDecoder().decode(Revision.self, from: checkedFile(file, maximumBytes: Self.maximumSnapshotBytes))
                guard revision.version == 1 else { throw AnimationStorageError.unsupportedVersion }
                guard revision.project.id == id else { throw AnimationStorageError.identityMismatch }
                try validate(revision.project, exactFrameCount: true)
                return revision.project
            }
            let revisions = storage.appendingPathComponent("revisions", isDirectory: true)
            guard try FileManager.default.contentsOfDirectory(atPath: revisions.path).isEmpty else {
                throw AnimationStorageError.missingRevisionSelector
            }
        }
        return try loadLegacyAnimation(id: id, directory: directory)
    }

    private func loadLegacyAnimation(id: UUID, directory: URL) throws -> AnimationProject {
        let metadata = try JSONDecoder().decode(AnimationMetadata.self, from: checkedFile(directory.appendingPathComponent("metadata.json"), maximumBytes: Self.maximumSnapshotBytes))
        guard metadata.id == id else { throw AnimationStorageError.identityMismatch }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.count <= 20_000 else { throw AnimationStorageError.limitExceeded }
        var frameFiles: [Int: URL] = [:]
        var audioFiles: [Int: URL] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("frame_"), name.hasSuffix(".png") {
                let index = try legacyIndex(String(name.dropFirst(6).dropLast(4)))
                guard frameFiles.updateValue(entry, forKey: index) == nil else { throw AnimationStorageError.legacyIndexCollision }
            } else if name.hasPrefix("audio_") {
                let stem = entry.deletingPathExtension().lastPathComponent
                let index = try legacyIndex(String(stem.dropFirst(6)))
                guard validFormat(entry.pathExtension), audioFiles.updateValue(entry, forKey: index) == nil else { throw AnimationStorageError.legacyIndexCollision }
            }
        }
        var payloadBytes = 0
        func readAsset(_ url: URL) throws -> Data {
            let data = try checkedFile(url, maximumBytes: Self.maximumAssetBytes)
            guard data.count <= Self.maximumPayloadBytes - payloadBytes else { throw AnimationStorageError.limitExceeded }
            payloadBytes += data.count
            return data
        }
        let frames = try frameFiles.keys.sorted().map { index in
            StoredAnimationFrame(imageData: try readAsset(frameFiles[index]!), legacyFrameIndex: index)
        }
        let tracks = try audioFiles.keys.sorted().map { index -> AudioTrack in
            let file = audioFiles[index]!
            return AudioTrack(id: legacyAssetID(projectID: id, filename: file.lastPathComponent), name: "Legacy audio \(index)", format: file.pathExtension, audioData: try readAsset(file), startTime: 0, duration: 0, legacySourceFilename: file.lastPathComponent)
        }
        let project = AnimationProject(id: id, metadata: metadata, frames: frames, audioTracks: tracks)
        try validate(project, exactFrameCount: false)
        return project
    }

    /// Compatibility list. New callers should use the reporting API so damaged
    /// or ambiguous legacy bundles remain visible as recoverable failures.
    func listAnimations() -> [AnimationMetadata] {
        (try? listAnimationsReportingFailures().animations) ?? []
    }

    func listAnimationsReportingFailures() throws -> AnimationStorageListing {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        guard itemExists(animationsDir) else { return AnimationStorageListing() }
        try checkedDirectory(animationsDir)
        let contents = try FileManager.default.contentsOfDirectory(at: animationsDir, includingPropertiesForKeys: nil)
        guard contents.count <= 20_000 else { throw AnimationStorageError.limitExceeded }
        var result = AnimationStorageListing()
        for directory in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                if let project = try loadAnimation(id: id) { result.animations.append(project.metadata) }
            } catch {
                result.failures.append(AnimationStorageFailure(id: id, error: error))
            }
        }
        return result
    }

    func deleteAnimation(id: UUID) throws {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        try checkedDirectory(animationsDir)
        let projectDir = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try checkedDirectory(projectDir)
        try FileManager.default.removeItem(at: projectDir)
    }

    private func revisionDirectory(_ projectDir: URL, create: Bool) throws -> URL {
        let storage = projectDir.appendingPathComponent(".sdi", isDirectory: true)
        if !itemExists(storage), create {
            // Prepare the namespace before adopting it. Unknown .sdi folders are
            // collisions, never overwritten or assumed to belong to this store.
            // A failed preparation lives outside the project namespace so a
            // later first-save retry can proceed without deleting that evidence.
            let staging = animationsDir.appendingPathComponent(".sdi-initializing-" + projectDir.lastPathComponent + "-" + UUID().uuidString, isDirectory: true)
            try checkedDirectory(staging, create: true)
            try checkedDirectory(staging.appendingPathComponent("revisions", isDirectory: true), create: true)
            try Self.storageMarker.write(to: staging.appendingPathComponent("format"), options: .withoutOverwriting)
            try FileManager.default.moveItem(at: staging, to: storage)
        }
        try checkedDirectory(storage)
        guard try checkedFile(storage.appendingPathComponent("format"), maximumBytes: 64) == Self.storageMarker else { throw AnimationStorageError.storageCollision }
        try checkedDirectory(storage.appendingPathComponent("revisions", isDirectory: true))
        return storage
    }

    private func itemExists(_ url: URL) -> Bool {
        // lstat-style attributes include dangling symlinks, unlike fileExists.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func checkedDirectory(_ url: URL, create: Bool = false) throws {
        if !itemExists(url), create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw AnimationStorageError.unsafeFile }
    }

    private func checkedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw AnimationStorageError.unsafeFile }
        guard let size = values.fileSize, size >= 0, size <= maximumBytes else { throw AnimationStorageError.limitExceeded }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw AnimationStorageError.limitExceeded }
        return data
    }

    private func legacyIndex(_ value: String) throws -> Int {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let index = Int(value), index <= 1_000_000 else { throw AnimationStorageError.invalidLegacyFilename }
        return index
    }

    private func validFormat(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }

    private func legacyAssetID(projectID: UUID, filename: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((projectID.uuidString + "/" + filename).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func validate(_ project: AnimationProject, exactFrameCount: Bool) throws {
        let metadata = project.metadata
        guard metadata.id == project.id else { throw AnimationStorageError.identityMismatch }
        guard (1...16_384).contains(metadata.canvasWidth), (1...16_384).contains(metadata.canvasHeight), (1...240).contains(metadata.fps), (0...10_000).contains(metadata.frameCount), (0...1024).contains(metadata.layerCount), project.frames.count <= 10_000, project.audioTracks.count <= 128, !exactFrameCount || metadata.frameCount == project.frames.count else { throw AnimationStorageError.invalidDocument }
        var budget = 0
        func account(_ bytes: Int) throws {
            guard bytes <= Self.maximumPayloadBytes - budget else { throw AnimationStorageError.limitExceeded }
            budget += bytes
        }
        func text(_ value: String) throws {
            guard value.utf8.count <= 4096 else { throw AnimationStorageError.limitExceeded }
            try account(value.utf8.count)
        }
        func asset(_ value: Data?) throws {
            guard let value else { return }
            guard value.count <= Self.maximumAssetBytes else { throw AnimationStorageError.limitExceeded }
            try account(value.count)
        }
        try text(metadata.title)
        try asset(metadata.thumbnailData)
        try asset(project.editableDocumentData)
        for frame in project.frames {
            try account(64)
            try asset(frame.imageData)
            guard frame.legacyFrameIndex.map({ (0...1_000_000).contains($0) }) ?? true else { throw AnimationStorageError.invalidDocument }
            let layers = frame.layerData ?? []
            guard layers.count <= 1024, Set(layers.map(\.id)).count == layers.count else { throw AnimationStorageError.invalidDocument }
            for layer in layers {
                guard layer.opacity.isFinite, (0...1).contains(layer.opacity) else { throw AnimationStorageError.invalidDocument }
                try account(128); try text(layer.name); try text(layer.blendMode)
            }
        }
        guard Set(project.audioTracks.map(\.id)).count == project.audioTracks.count else { throw AnimationStorageError.invalidDocument }
        for track in project.audioTracks {
            guard validFormat(track.format), track.startTime.isFinite, track.startTime >= 0, track.duration.isFinite, track.duration >= 0 else { throw AnimationStorageError.invalidDocument }
            try account(128); try text(track.name); try asset(track.audioData)
            if let source = track.legacySourceFilename { try text(source) }
        }
    }
    
    // MARK: - Messages (on-device encrypted SQLite)
    
    func saveMessage(_ message: ChatMessage) {
        // Messages stored in local SQLite via Core Data
        // Encrypted at rest using iOS Data Protection
        // No server sync — peer-to-peer delivery via LiveKit data channels
    }
    
    // MARK: - Media files (on-device)
    
    func saveMedia(data: Data, type: MediaType, filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else { throw AnimationStorageError.unsafeFile }
        try checkedDirectory(mediaDir, create: true)
        let typeDir = mediaDir.appendingPathComponent(type.rawValue, isDirectory: true)
        try checkedDirectory(typeDir, create: true)
        let fileURL = typeDir.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .withoutOverwriting)
        return fileURL
    }
    
    func clearCache() throws {
        try? FileManager.default.removeItem(at: aiCacheDir)
        try? FileManager.default.removeItem(at: thumbnailsDir)
        setupDirectories()
    }
}

// MARK: - Data models

struct AnimationProject: Codable {
    let id: UUID
    var metadata: AnimationMetadata
    var frames: [StoredAnimationFrame]
    var audioTracks: [AudioTrack]
    /// Owned and validated by the Studio document model, stored without reinterpretation.
    var editableDocumentData: Data? = nil
}

struct AnimationMetadata: Codable {
    let id: UUID
    var title: String
    var fps: Int
    var canvasWidth: Int
    var canvasHeight: Int
    var frameCount: Int
    var layerCount: Int
    var createdAt: Date
    var modifiedAt: Date
    var thumbnailData: Data?
}

struct StoredAnimationFrame: Codable {
    var imageData: Data?
    var layerData: [LayerData]?
    /// Original numeric position when reading a legacy directory with gaps.
    var legacyFrameIndex: Int? = nil
}

struct LayerData: Codable {
    let id: UUID
    var name: String
    var opacity: Double
    var blendMode: String
    var locked: Bool
    var visible: Bool
}

struct AudioTrack: Codable {
    let id: UUID
    var name: String
    var format: String
    var audioData: Data?
    var startTime: Double
    var duration: Double
    /// Legacy files contain no original track ID/timing/name metadata. A stable
    /// derived ID and this filename preserve provenance without inventing timing.
    var legacySourceFilename: String? = nil
}

struct AnimationStorageFailure {
    let id: UUID
    let error: Error
}

struct AnimationStorageListing {
    var animations: [AnimationMetadata] = []
    var failures: [AnimationStorageFailure] = []
}

enum AnimationStorageError: Error, LocalizedError {
    case identityMismatch, invalidDocument, limitExceeded, unsafeFile
    case unsupportedVersion, storageCollision, legacyIndexCollision, invalidLegacyFilename, missingRevisionSelector

    var errorDescription: String? {
        switch self {
        case .identityMismatch: return "The project identity does not match its folder. Its original files were preserved."
        case .invalidDocument: return "The animation contains invalid or inconsistent document data."
        case .limitExceeded: return "The animation exceeds this storage version's safe size or count limits."
        case .unsafeFile: return "The animation contains an unexpected file or symbolic link. Its original files were preserved."
        case .unsupportedVersion: return "This animation requires a different storage version."
        case .storageCollision: return "The animation's revision folder is not recognized. Its original files were preserved."
        case .legacyIndexCollision: return "More than one legacy asset has the same numeric position. Resolve the conflict before saving."
        case .invalidLegacyFilename: return "A legacy asset has an invalid numeric filename. Its original files were preserved."
        case .missingRevisionSelector: return "The animation has saved revision data but no current revision selector. Recovery is required; its files were preserved."
        }
    }
}

struct StoredChatMessage: Codable {
    let id: UUID
    let senderId: String
    let recipientId: String
    let text: String
    let timestamp: Date
    let mediaURL: String?
    // Stored on-device only, not synced to server
}

enum MediaType: String {
    case photo = "photos"
    case video = "videos"
    case audio = "audio"
    case animation = "animations"
}
