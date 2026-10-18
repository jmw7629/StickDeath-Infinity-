import Foundation
import CoreData
import CryptoKit
import Darwin

/// Device-first storage architecture for StickDeath ∞
/// Editable projects, originals and imported media stay on this device. The
/// server keeps only identity, access, vote, consent, billing and job metadata.
/// User-to-user messaging and calls are retired: there is no message store.
///
/// Storage hierarchy:
///   ~/Documents/Animations/<uuid>/            — project bundle (legacy files kept byte-identical)
///   ~/Documents/Animations/<uuid>/.sdi/       — immutable revisions, lineage receipts, current.json,
///                                               migration.json manifest for migrated legacy bundles
///   ~/Documents/.sdi-recently-deleted/        — recoverable deletions and migration rollbacks
///   ~/Documents/Media/                        — imported photos, videos, audio files
///   ~/Library/Caches/AI/, Thumbnails/         — regenerable caches (never evicted by inference)
///
/// Protection: every directory and file this manager creates uses
/// FileProtectionType.completeUntilFirstUserAuthentication (see docs/LOCAL_DATA_POLICY.md).
/// Diagnostics and user-facing messages never include filesystem paths.

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
        let dirs = [animationsDir, mediaDir, aiCacheDir, thumbnailsDir]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.applyFileProtection(dir)
        }
    }

    // MARK: - File protection

    /// Readable after the first unlock so background saves and relaunch-before-
    /// unlock restoration work; unreadable on a locked device before that.
    static let fileProtection = "completeUntilFirstUserAuthentication"
    static func applyFileProtection(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func protectedWriteOptions(_ options: Data.WritingOptions) -> Data.WritingOptions {
        #if os(iOS)
        return options.union(.completeFileProtectionUntilFirstUserAuthentication)
        #else
        return options
        #endif
    }
    private static func writeProtected(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: protectedWriteOptions(options))
    }
    
    // MARK: - Storage metrics
    
    var storageScanRequest: StudioStorageScanRequest {
        StudioStorageScanRequest(documents: documentsDir, caches: cachesDir)
    }

    func deviceStorageUsed() throws -> Int64 { try storageScanRequest.scan().totalFileBytes }

    func deviceStorageAvailable() throws -> Int64? {
        try documentsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    func formattedStorageUsed() throws -> String {
        ByteCountFormatter.string(fromByteCount: try deviceStorageUsed(), countStyle: .file)
    }

    // MARK: - Animation Projects (on-device)

    private static let maximumSnapshotBytes = 64 * 1024 * 1024
    private static let maximumPayloadBytes = 40 * 1024 * 1024
    private static let maximumAssetBytes = 32 * 1024 * 1024
    private static let storageMarker = Data("SDI-ANIMATION-REVISIONS-1\n".utf8)
    // Serializes all instances in this process, including read/list against a
    // commit. Callers still own edit-generation ordering and save acknowledgments.
    private static let operationLock = NSRecursiveLock()
    private struct EncodedFrameEntry {
        let frame: StoredAnimationFrame
        let data: Data
        let cost: Int
        var used: UInt64
    }
    static let maximumSnapshotFrameCacheBytes = 96 * 1024 * 1024
    private static var encodedFrames: [UUID: EncodedFrameEntry] = [:]
    private static var encodedFrameBytes = 0
    private static var encodingClock: UInt64 = 0
    static var snapshotEncodingCacheFootprint: (entries: Int, bytes: Int) {
        operationLock.lock(); defer { operationLock.unlock() }
        return (encodedFrames.count, encodedFrameBytes)
    }

    private struct Revision: Codable {
        let version: Int
        let project: AnimationProject
    }

    private struct CurrentRevision: Codable {
        let version: Int
        let revision: UUID
        var lineageSHA256: String? = nil
    }

    /// Existing raster/audio files are immutable research/user inputs. New saves
    /// write a complete revision, then atomically select it. An interrupted save
    /// can leave an unselected revision, but never a partially selected document.
    func saveAnimation(_ project: AnimationProject) throws {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        let data = try validatedSnapshotData(project)
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
        // A legacy bundle (files outside .sdi, no selected revision yet) is about
        // to be migrated. Record the originals before the first revision is
        // selected so rollback can prove they are still byte-identical. Hashing
        // happens only on that first (or retried first) save, never afterwards.
        let existingStorage = projectDir.appendingPathComponent(".sdi", isDirectory: true)
        let needsManifest = itemExists(projectDir) && (!itemExists(existingStorage) ||
            (!itemExists(existingStorage.appendingPathComponent("migration.json")) && !itemExists(existingStorage.appendingPathComponent("current.json"))))
        let legacyEntries = needsManifest ? try legacyOriginalEntries(projectDir) : []
        try checkedDirectory(projectDir, create: true)
        let storage = try revisionDirectory(projectDir, create: true)
        let ownership = try revisionMutationLock(storage)
        defer { flock(ownership, LOCK_UN); close(ownership) }
        let manifestURL = storage.appendingPathComponent("migration.json")
        if !legacyEntries.isEmpty, !itemExists(manifestURL) {
            let manifest = MigrationManifest(version: 1, project: project.id, migratedAt: Date(),
                                             protection: Self.fileProtection, originals: legacyEntries)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let bytes = try encoder.encode(manifest)
            try writeRevisionFile(bytes, to: manifestURL, stage: .migrationManifest)
            try synchronizeRevisionFile(manifestURL, stage: .migrationManifest)
        }
        let revisions = storage.appendingPathComponent("revisions", isDirectory: true)
        let revision = UUID()
        let destination = revisions.appendingPathComponent(revision.uuidString + ".json")
        try writeRevisionFile(data, to: destination, stage: .payload)
        try synchronizeRevisionFile(destination, stage: .payload)
        let pointer = storage.appendingPathComponent("current.json")
        if itemExists(pointer) { _ = try checkedFile(pointer, maximumBytes: 1024) }
        // Only prospective successfully selected ancestry is eligible for explicit
        // cleanup. Old revisions and failed-save orphans are never inferred.
        var parent: LineageReference?
        if itemExists(pointer) {
            let previous = try JSONDecoder().decode(CurrentRevision.self, from: checkedFile(pointer, maximumBytes: 1024))
            guard previous.version == 1 else { throw AnimationStorageError.unsupportedVersion }
            if let digest = previous.lineageSHA256 {
                _ = try lineageReceipt(previous.revision, digest: digest, in: revisions, project: project.id)
                parent = LineageReference(revision: previous.revision, sha256: digest)
            }
        }
        let receipt = LineageReceipt(version: 1, project: project.id, revision: revision,
            payloadSHA256: Self.digest(data), payloadBytes: data.count, parent: parent)
        let lineage = try lineageDirectory(storage, create: true)
        let receiptData = try JSONEncoder().encode(receipt)
        let receiptURL = lineage.appendingPathComponent(revision.uuidString + ".json")
        try writeRevisionFile(receiptData, to: receiptURL, stage: .lineageReceipt)
        try synchronizeRevisionFile(receiptURL, stage: .lineageReceipt)
        // Both the payload and its ancestry directory entries must be durable
        // before current.json can select them. File fsync alone is insufficient.
        try synchronizeRevisionDirectory(revisions)
        try synchronizeRevisionDirectory(lineage)
        try synchronizeRevisionDirectory(storage)
        let current = try JSONEncoder().encode(CurrentRevision(version: 1, revision: revision, lineageSHA256: Self.digest(receiptData)))
        try commitCurrentRevision(current, to: pointer)
    }

    enum RevisionWriteStage { case payload, lineageReceipt, migrationManifest }
    /// Narrow filesystem seams: default behavior and publication ordering are unchanged.
    /// Failure leaves unselected recovery data intact and never selects partial content.
    func writeRevisionFile(_ data: Data, to url: URL, stage: RevisionWriteStage) throws {
        try Self.writeProtected(data, to: url, options: .withoutOverwriting)
    }
    func synchronizeRevisionFile(_ url: URL, stage: RevisionWriteStage) throws {
        let handle = try FileHandle(forWritingTo: url)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
    }

    /// Filesystem failure seam for production-store tests. The default commit
    /// uses Foundation's atomic replacement; no document mutation follows it.
    func commitCurrentRevision(_ data: Data, to pointer: URL) throws {
        try Self.writeProtected(data, to: pointer, options: .atomic)
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
                let revisions = storage.appendingPathComponent("revisions", isDirectory: true)
                return try selectedRevisionProject(current.revision, lineageSHA256: current.lineageSHA256,
                                                   revisions: revisions, project: id)
            }
            let revisions = storage.appendingPathComponent("revisions", isDirectory: true)
            guard try FileManager.default.contentsOfDirectory(atPath: revisions.path).isEmpty else {
                throw AnimationStorageError.missingRevisionSelector
            }
        }
        return try loadLegacyAnimation(id: id, directory: directory)
    }

    /// Reads one revision payload. When the selector carries a lineage digest,
    /// the payload bytes must match the receipt's SHA-256 and byte count; a
    /// mismatch is corruption or tampering and is reported, never opened.
    private func selectedRevisionProject(_ revisionID: UUID, lineageSHA256: String?, revisions: URL, project id: UUID) throws -> AnimationProject {
        let file = revisions.appendingPathComponent(revisionID.uuidString + ".json")
        let data = try checkedFile(file, maximumBytes: Self.maximumSnapshotBytes)
        if let digest = lineageSHA256 {
            let receipt = try readOnlyLineageReceipt(revisionID, digest: digest, storage: revisions.deletingLastPathComponent(), project: id)
            guard data.count == receipt.payloadBytes, Self.digest(data) == receipt.payloadSHA256 else {
                throw AnimationStorageError.payloadIntegrity
            }
        }
        let revision = try JSONDecoder().decode(Revision.self, from: data)
        guard revision.version == 1 else { throw AnimationStorageError.unsupportedVersion }
        guard revision.project.id == id else { throw AnimationStorageError.identityMismatch }
        try validate(revision.project, exactFrameCount: true)
        return revision.project
    }

    /// Receipt lookup for reads. Uses the same symlink/size-checked file reads
    /// as the rest of the load path (not the cleanup descriptor walk), so an
    /// open never depends on cleanup-only machinery; cleanup keeps its own.
    private func readOnlyLineageReceipt(_ revisionID: UUID, digest: String, storage: URL, project id: UUID) throws -> LineageReceipt {
        let lineage = storage.appendingPathComponent("lineage-v1", isDirectory: true)
        try checkedDirectory(lineage)
        guard try checkedFile(lineage.appendingPathComponent("format"), maximumBytes: 64) == Self.lineageMarker else {
            throw AnimationStorageError.storageCollision
        }
        let bytes = try checkedFile(lineage.appendingPathComponent(revisionID.uuidString + ".json"), maximumBytes: 2048)
        guard Self.digest(bytes) == digest else { throw AnimationStorageError.payloadIntegrity }
        let receipt = try JSONDecoder().decode(LineageReceipt.self, from: bytes)
        guard receipt.version == 1, receipt.project == id, receipt.revision == revisionID,
              receipt.payloadBytes > 0, receipt.payloadBytes <= Self.maximumSnapshotBytes,
              receipt.payloadSHA256.count == 64 else { throw AnimationStorageError.payloadIntegrity }
        return receipt
    }

    /// The revision selected immediately before the current one, verified
    /// through its lineage receipt. Nil when no selected ancestor exists or its
    /// payload was explicitly cleaned up. Read-only: current.json is unchanged.
    func loadPreviousRevision(id: UUID) throws -> AnimationProject? {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        let directory = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard itemExists(directory) else { return nil }
        try checkedDirectory(directory)
        let storage = try revisionDirectory(directory, create: false)
        let pointer = storage.appendingPathComponent("current.json")
        guard itemExists(pointer) else { throw AnimationStorageError.missingRevisionSelector }
        let current = try JSONDecoder().decode(CurrentRevision.self, from: checkedFile(pointer, maximumBytes: 1024))
        guard current.version == 1 else { throw AnimationStorageError.unsupportedVersion }
        guard let digest = current.lineageSHA256 else { return nil } // Pre-lineage document: no verified ancestry.
        let revisions = storage.appendingPathComponent("revisions", isDirectory: true)
        let receipt = try readOnlyLineageReceipt(current.revision, digest: digest, storage: storage, project: id)
        guard let parent = receipt.parent else { return nil }
        guard itemExists(revisions.appendingPathComponent(parent.revision.uuidString + ".json")) else { return nil }
        return try selectedRevisionProject(parent.revision, lineageSHA256: parent.sha256, revisions: revisions, project: id)
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
            let name = directory.lastPathComponent
            guard let id = UUID(uuidString: name) else {
                // Hidden entries are this store's own staging namespace or system
                // files. Anything else is a bundle this version cannot identify;
                // it is reported, never opened, renamed or removed.
                if name.hasPrefix(".") { continue }
                result.failures.append(AnimationStorageFailure(id: nil, entryName: name, error: AnimationStorageError.unrecognizedEntry))
                continue
            }
            do {
                if let project = try loadAnimation(id: id) { result.animations.append(project.metadata) }
            } catch {
                result.failures.append(AnimationStorageFailure(id: id, entryName: name, error: error))
            }
        }
        return result
    }

    // MARK: - Legacy migration manifest and rollback

    struct MigrationOriginal: Codable, Equatable {
        let name: String
        let size: Int
        /// Nil only when the file exceeded the hashing limit; size is still recorded.
        let sha256: String?
    }
    struct MigrationManifest: Codable {
        let version: Int
        let project: UUID
        let migratedAt: Date
        let protection: String
        let originals: [MigrationOriginal]
    }
    /// Regular files at the bundle's top level, excluding the `.sdi` store.
    private func legacyOriginalEntries(_ projectDir: URL) throws -> [MigrationOriginal] {
        guard itemExists(projectDir) else { return [] }
        try checkedDirectory(projectDir)
        let entries = try FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard entries.count <= 20_000 else { throw AnimationStorageError.limitExceeded }
        var result: [MigrationOriginal] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            if name == ".sdi" { continue }
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AnimationStorageError.unsafeFile }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { continue }
            let digest = size <= Self.maximumAssetBytes ? Self.digest(try checkedFile(entry, maximumBytes: Self.maximumAssetBytes)) : nil
            result.append(MigrationOriginal(name: name, size: size, sha256: digest))
        }
        return result
    }
    func migrationManifest(id: UUID) throws -> MigrationManifest? {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        let projectDir = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard itemExists(projectDir.appendingPathComponent(".sdi")) else { return nil }
        let storage = try revisionDirectory(projectDir, create: false)
        let url = storage.appendingPathComponent("migration.json")
        guard itemExists(url) else { return nil }
        let manifest = try JSONDecoder().decode(MigrationManifest.self, from: checkedFile(url, maximumBytes: 4 * 1024 * 1024))
        guard manifest.version == 1, manifest.project == id else { throw AnimationStorageError.invalidDocument }
        return manifest
    }
    /// Undo a legacy migration: every original listed in the manifest must still
    /// exist byte-identical, then the whole `.sdi` store (all revisions, lineage,
    /// manifest) moves to Recently Deleted. Nothing is deleted and the legacy
    /// files are not touched; the bundle reopens through the legacy reader.
    func rollbackMigration(id: UUID) throws {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        try checkedDirectory(animationsDir)
        let projectDir = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try checkedDirectory(projectDir)
        guard let manifest = try migrationManifest(id: id) else { throw AnimationStorageError.migrationManifestMissing }
        let storage = try revisionDirectory(projectDir, create: false)
        let ownership = try revisionMutationLock(storage)
        defer { flock(ownership, LOCK_UN); close(ownership) }
        let current = try legacyOriginalEntries(projectDir)
        for original in manifest.originals {
            guard let live = current.first(where: { $0.name == original.name }), live.size == original.size,
                  original.sha256 == nil || live.sha256 == original.sha256 else {
                throw AnimationStorageError.migrationOriginalsChanged
            }
        }
        guard !manifest.originals.isEmpty else { throw AnimationStorageError.migrationOriginalsChanged }
        // The legacy reader must accept the originals before the store is set aside.
        _ = try loadLegacyAnimation(id: id, directory: projectDir)
        guard let recovery = try recoveryStore(create: true) else { throw AnimationStorageError.storageCollision }
        let rollbacks = recovery.documentsRoot.appendingPathComponent(".migration-rollbacks", isDirectory: true)
        try checkedDirectory(rollbacks, create: true)
        let destination = rollbacks.appendingPathComponent(id.uuidString + "-" + UUID().uuidString, isDirectory: true)
        try checkedDirectory(destination, create: true)
        try FileManager.default.moveItem(at: storage, to: destination.appendingPathComponent(".sdi", isDirectory: true))
    }
    /// Root the recovery store is based on; exposed so rollback can place
    /// migration stores beside, not inside, recoverable project bundles.
    fileprivate var documentsRoot: URL { documentsDir }

    func deleteAnimation(id: UUID) throws {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        try checkedDirectory(animationsDir)
        let projectDir = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try checkedDirectory(projectDir)
        let ownership = try optionalProjectMutationLock(projectDir)
        defer { if let ownership { flock(ownership, LOCK_UN); close(ownership) } }
        try FileManager.default.removeItem(at: projectDir)
    }

    // Recoverable deletion moves the entire bundle, including historical files.
    // There is deliberately no automatic expiry or permanent-delete UI.
    private func recoveryStore(create: Bool) throws -> DeviceStorageManager? {
        let root = documentsDir.appendingPathComponent(".sdi-recently-deleted", isDirectory: true)
        let marker = Data("SDI-PROJECT-RECOVERY-1\n".utf8)
        if !itemExists(root) {
            guard create else { return nil }
            try checkedDirectory(documentsDir, create: true)
            let staging = documentsDir.appendingPathComponent(".sdi-recovery-init-" + UUID().uuidString, isDirectory: true)
            try checkedDirectory(staging, create: true)
            try Self.writeProtected(marker, to: staging.appendingPathComponent("format"), options: .withoutOverwriting)
            try FileManager.default.moveItem(at: staging, to: root)
        }
        try checkedDirectory(root)
        guard try checkedFile(root.appendingPathComponent("format"), maximumBytes: 64) == marker else {
            throw AnimationStorageError.storageCollision
        }
        let store = DeviceStorageManager(documentsDirectory: root, cachesDirectory: suppliedCachesDirectory)
        if create { try checkedDirectory(store.animationsDir, create: true) }
        return store
    }

    // MARK: - Portable device-first project bundles

    // A fixed binary header bounds the payload before JSON decoding. Everything
    // is embedded in the existing Revision; there are no archive entry paths,
    // external asset URLs, scripts, or extraction destinations to trust.
    static let maximumPortableBundleBytes = maximumSnapshotBytes + 80
    private static let portableMagic = Data("SDIPROJECT000001\n".utf8)

    func portableBundle(for project: AnimationProject,
                        checkCancellation: () throws -> Void = {}) throws -> Data {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        try checkCancellation()
        let payload = try validatedSnapshotData(project)
        try checkCancellation()
        let digest = Data(SHA256.hash(data: payload))
        var result = Self.portableMagic
        var count = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
        result.append(digest)
        result.append(payload)
        try checkCancellation()
        return result
    }

    /// Decode only. The caller must validate editable document/asset references
    /// and allocate a fresh identity before committing an imported project.
    /// Merely opening an untrusted bundle never modifies the project library.
    func projectFromPortableBundle(_ input: Data,
                                   checkCancellation: () throws -> Void = {}) throws -> AnimationProject {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        try checkCancellation()
        guard input.count <= Self.maximumPortableBundleBytes else { throw AnimationStorageError.limitExceeded }
        // Data subsequences may retain a nonzero startIndex. Normalize before
        // applying the fixed offsets; reject oversize input before copying.
        let data = Data(input)
        let prefix = Self.portableMagic.count
        let header = prefix + 8 + 32
        guard data.count >= header, data.count <= Self.maximumPortableBundleBytes,
              data.prefix(prefix) == Self.portableMagic else {
            throw AnimationStorageError.invalidDocument
        }
        let count = data[prefix..<(prefix + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard count <= UInt64(Self.maximumSnapshotBytes), count == UInt64(data.count - header) else {
            throw AnimationStorageError.limitExceeded
        }
        let payload = data.subdata(in: header..<data.count)
        guard Data(SHA256.hash(data: payload)) == data.subdata(in: (prefix + 8)..<header) else {
            throw AnimationStorageError.invalidDocument
        }
        try checkCancellation()
        let revision = try JSONDecoder().decode(Revision.self, from: payload)
        guard revision.version == 1 else { throw AnimationStorageError.unsupportedVersion }
        try validate(revision.project, exactFrameCount: true)
        try checkCancellation()
        return revision.project
    }

    func saveNewAnimation(_ project: AnimationProject) throws {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        try checkedDirectory(animationsDir, create: true)
        guard !itemExists(animationsDir.appendingPathComponent(project.id.uuidString)) else {
            throw AnimationStorageError.storageCollision
        }
        try saveAnimation(project)
    }

    func recoverableDeleteAnimation(id: UUID) throws {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        try checkedDirectory(animationsDir)
        let source = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try checkedDirectory(source)
        let ownership = try optionalProjectMutationLock(source)
        defer { if let ownership { flock(ownership, LOCK_UN); close(ownership) } }
        guard let recovery = try recoveryStore(create: true) else { throw AnimationStorageError.storageCollision }
        let destination = recovery.animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !itemExists(destination) else { throw AnimationStorageError.storageCollision }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func listRecoverableAnimations() throws -> AnimationStorageListing {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        return try recoveryStore(create: false)?.listAnimationsReportingFailures() ?? AnimationStorageListing()
    }

    func restoreAnimation(id: UUID) throws {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        guard let recovery = try recoveryStore(create: false) else { throw AnimationStorageError.storageCollision }
        try checkedDirectory(recovery.animationsDir)
        let source = recovery.animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try checkedDirectory(source)
        let ownership = try optionalProjectMutationLock(source)
        defer { if let ownership { flock(ownership, LOCK_UN); close(ownership) } }
        try checkedDirectory(animationsDir, create: true)
        let destination = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !itemExists(destination) else { throw AnimationStorageError.storageCollision }
        try FileManager.default.moveItem(at: source, to: destination)
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
            try Self.writeProtected(Self.storageMarker, to: staging.appendingPathComponent("format"), options: .withoutOverwriting)
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
            Self.applyFileProtection(url)
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

    /// Uses exactly the same validator and encoding as save, without any disk mutation.
    func preflightAnimation(_ project: AnimationProject) throws {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        _ = try validatedSnapshotData(project)
    }
    private func validatedSnapshotData(_ project: AnimationProject) throws -> Data {
        try validate(project, exactFrameCount: true)
        // Encode the real Revision and real StoredAnimationFrame values. Only
        // immutable managed-frame fragments are reused; no mirror size model or
        // hand-written metadata serializer can disagree with an actual save.
        // The normal JSONDecoder still reads precisely the existing v1 format.
        var structure = project; structure.frames = []
        let scalar = try JSONEncoder().encode(Revision(version: 1, project: structure))
        let marker = Data("\"frames\":[]".utf8)
        guard let range = scalar.range(of: marker), scalar.range(of: marker, in: range.upperBound..<scalar.endIndex) == nil else {
            throw AnimationStorageError.invalidDocument
        }
        var encoded: [Data] = [], total = scalar.count
        for (index, frame) in project.frames.enumerated() {
            let value = try encodedFrame(frame)
            let additional = value.count + (index > 0 ? 1 : 0)
            guard additional <= Self.maximumSnapshotBytes - total else { throw AnimationStorageError.limitExceeded }
            total += additional; encoded.append(value)
        }
        guard total <= Self.maximumSnapshotBytes else { throw AnimationStorageError.limitExceeded }
        let valueStart = scalar.index(range.upperBound, offsetBy: -2)
        var data = Data(); data.reserveCapacity(total)
        data.append(scalar[..<valueStart]); data.append(91)
        for (index, value) in encoded.enumerated() { if index > 0 { data.append(44) }; data.append(value) }
        data.append(93); data.append(scalar[range.upperBound...])
        guard data.count == total else { throw AnimationStorageError.invalidDocument }
        return data
    }
    private func encodedFrame(_ frame: StoredAnimationFrame) throws -> Data {
        guard let id = frame.sourceImage?.id else { return try JSONEncoder().encode(frame) }
        Self.encodingClock &+= 1
        if var hit = Self.encodedFrames[id], hit.frame == frame {
            hit.used = Self.encodingClock; Self.encodedFrames[id] = hit; return hit.data
        }
        let data = try JSONEncoder().encode(frame)
        let textBytes = (frame.layerData ?? []).reduce(0) { $0 + $1.name.utf8.count + $1.blendMode.utf8.count + 512 }
        let attributionBytes = (frame.sourceImage?.catalogueAttribution ?? [:]).reduce(0) {
            $0 + $1.key.utf8.count + $1.value.utf8.count + 128
        }
        var cost = data.count + textBytes + attributionBytes + 16_384
        cost += frame.imageData?.count ?? 0
        cost += frame.sourceImage?.originalData.count ?? 0
        if let old = Self.encodedFrames.removeValue(forKey: id) { Self.encodedFrameBytes -= old.cost }
        guard cost <= Self.maximumSnapshotFrameCacheBytes else { return data }
        while !Self.encodedFrames.isEmpty && (Self.encodedFrameBytes + cost > Self.maximumSnapshotFrameCacheBytes || Self.encodedFrames.count >= 32) {
            guard let key = Self.encodedFrames.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = Self.encodedFrames.removeValue(forKey: key) else { break }
            Self.encodedFrameBytes -= removed.cost
        }
        Self.encodedFrames[id] = EncodedFrameEntry(frame: frame, data: data, cost: cost, used: Self.encodingClock)
        Self.encodedFrameBytes += cost
        return data
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
        let additional = project.additionalImageAssets ?? [:]
        guard additional.count <= 256 else { throw AnimationStorageError.limitExceeded }
        for (key, record) in additional {
            guard let source = record.sourceImage, key == "image-" + source.id.uuidString,
                  record.layerData == nil, record.legacyFrameIndex == nil,
                  record.imageData?.isEmpty == false else { throw AnimationStorageError.invalidDocument }
            try text(key)
        }
        var imageSources: [UUID: (source: StoredImageSource, normalized: Data)] = [:]
        // Both collections share the exact payload budget and source-identity
        // checks. Additional sources never manufacture timeline frame records.
        for frame in project.frames + Array(additional.values) {
            try account(64)
            try asset(frame.imageData)
            if let source = frame.sourceImage {
                try source.validate()
                guard let normalized = frame.imageData, !normalized.isEmpty else { throw AnimationStorageError.invalidDocument }
                if let previous = imageSources[source.id], previous.source != source || previous.normalized != normalized { throw AnimationStorageError.identityMismatch }
                imageSources[source.id] = (source, normalized)
                try account(128); try text(source.name); try text(source.container); try asset(source.originalData)
                for (key, value) in source.catalogueAttribution ?? [:] { try text(key); try text(value) }
            }
            guard frame.legacyFrameIndex.map({ (0...1_000_000).contains($0) }) ?? true else { throw AnimationStorageError.invalidDocument }
            let layers = frame.layerData ?? []
            guard layers.count <= 1024, Set(layers.map(\.id)).count == layers.count else { throw AnimationStorageError.invalidDocument }
            for layer in layers {
                guard layer.opacity.isFinite, (0...1).contains(layer.opacity) else { throw AnimationStorageError.invalidDocument }
                try account(128); try text(layer.name); try text(layer.blendMode)
            }
        }
        if !additional.isEmpty {
            var decodedPixels = 0
            for record in imageSources.values {
                let pixels = record.source.normalizedWidth * record.source.normalizedHeight
                guard pixels <= 32 * 1024 * 1024 - decodedPixels else { throw AnimationStorageError.limitExceeded }
                decodedPixels += pixels
            }
        }
        let videos = project.videoSources ?? []
        guard videos.count <= 8, Set(videos.map(\.id)).count == videos.count else { throw AnimationStorageError.invalidDocument }
        for video in videos {
            try video.validate()
            try account(128); try text(video.name); try asset(video.data)
        }
        guard Set(project.audioTracks.map(\.id)).count == project.audioTracks.count else { throw AnimationStorageError.invalidDocument }
        for track in project.audioTracks {
            guard validFormat(track.format), track.startTime.isFinite, track.startTime >= 0, track.duration.isFinite, track.duration >= 0 else { throw AnimationStorageError.invalidDocument }
            try account(128); try text(track.name); try asset(track.audioData)
            if let source = track.legacySourceFilename { try text(source) }
        }
    }
    
    // MARK: - Media files (on-device)

    func saveMedia(data: Data, type: MediaType, filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else { throw AnimationStorageError.unsafeFile }
        try checkedDirectory(mediaDir, create: true)
        let typeDir = mediaDir.appendingPathComponent(type.rawValue, isDirectory: true)
        try checkedDirectory(typeDir, create: true)
        let fileURL = typeDir.appendingPathComponent(filename)
        try Self.writeProtected(data, to: fileURL, options: .withoutOverwriting)
        return fileURL
    }

    // MARK: - User-facing failure text

    /// Fixed, path-free messages. Raw `localizedDescription` values can embed
    /// filesystem paths or account data, so callers show this instead.
    static func userMessage(for error: Error) -> String {
        if let storage = error as? AnimationStorageError { return storage.errorDescription ?? "Project storage failed. Original files were preserved." }
        if let cleanup = error as? RevisionCleanupFailure { return cleanup.errorDescription ?? "Project storage failed. Original files were preserved." }
        if let scan = error as? StudioStorageScanRequest.Failure { return scan.errorDescription ?? "Storage could not be measured." }
        if error is CancellationError { return "The storage operation was cancelled. Nothing was changed." }
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue) ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return "Not enough free space to save. The last saved revision is unchanged; free up space and try again."
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileWriteNoPermission.rawValue {
            return "This project's files could not be written. The last saved revision is unchanged."
        }
        if nsError.domain == NSCocoaErrorDomain && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(nsError.code) {
            return "A project file is missing. Its remaining original files were preserved."
        }
        if error is DecodingError { return "A project file could not be decoded. Its original files were preserved." }
        return "Project storage failed. Original files were preserved."
    }
    
    struct CacheClearReceipt: Sendable {
        let entries: Int
        /// Conservative encoder accounting cost, not measured process resident memory.
        let releasedMemoryBytes: Int
    }
    /// This is the only cache currently produced with explicit ownership and
    /// regeneration semantics. Legacy AI/Thumbnails files have no manifest or
    /// producer, so clearing them by directory name could erase historical data.
    @discardableResult
    func clearCache(checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> CacheClearReceipt {
        try checkCancellation()
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        try checkCancellation()
        let receipt = CacheClearReceipt(entries: Self.encodedFrames.count, releasedMemoryBytes: Self.encodedFrameBytes)
        Self.encodedFrames.removeAll(keepingCapacity: false)
        Self.encodedFrameBytes = 0
        return receipt
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
    /// Additional managed sources, independent of the historical one-record-per-frame layout.
    /// Nil decodes every existing project without changing its original frame records.
    var additionalImageAssets: [String: StoredAnimationFrame]? = nil
    /// Movies retained as managed project media (#199). Nil decodes every
    /// existing project; removing the project removes these copies too.
    var videoSources: [StoredVideoSource]? = nil
}

/// The exact bytes of an imported movie, owned by one project. The user's
/// original file is never referenced or changed after import.
struct StoredVideoSource: Codable, Equatable {
    static let maximumBytes = 16 * 1024 * 1024
    let id: UUID
    let name: String
    let container: String
    let data: Data

    func validate() throws {
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["mp4", "mov"].contains(container), !data.isEmpty, data.count <= Self.maximumBytes else {
            throw AnimationStorageError.invalidDocument
        }
    }
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

struct StoredAnimationFrame: Codable, Equatable {
    var imageData: Data?
    var layerData: [LayerData]?
    /// Original numeric position when reading a legacy directory with gaps.
    var legacyFrameIndex: Int? = nil
    /// Nil for all historical records. Original bytes never replace normalized pixels.
    var sourceImage: StoredImageSource? = nil
}

struct StoredImageSource: Codable, Equatable {
    let id: UUID
    let name: String
    let container: String
    let originalData: Data
    let originalWidth: Int
    let originalHeight: Int
    let originalOrientation: Int
    let normalizedWidth: Int
    let normalizedHeight: Int
    var catalogueAttribution: [String: String]? = nil

    func validate() throws {
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ["jpeg", "png", "heif"].contains(container), !originalData.isEmpty, originalData.count <= 16 * 1024 * 1024,
              (1...8192).contains(originalWidth), (1...8192).contains(originalHeight),
              originalWidth * originalHeight <= 16_777_216, (1...8).contains(originalOrientation),
              (1...8192).contains(normalizedWidth), (1...8192).contains(normalizedHeight),
              normalizedWidth * normalizedHeight <= 16_777_216 else { throw AnimationStorageError.invalidDocument }
        if let origin = catalogueAttribution {
            let keys: Set<String> = ["assetID", "author", "sourceURL", "license", "licenseURL",
                                     "attribution", "originalSHA256", "sourceArchiveSHA256"]
            func isDigest(_ text: String?) -> Bool {
                guard let text else { return false }
                return text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
            guard Set(origin.keys) == keys,
                  origin.values.allSatisfy({ !$0.isEmpty && $0.count <= 600 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                  origin["license"] == "CC0-1.0",
                  origin["licenseURL"] == "https://creativecommons.org/publicdomain/zero/1.0/",
                  isDigest(origin["originalSHA256"]), isDigest(origin["sourceArchiveSHA256"]),
                  let source = origin["sourceURL"].flatMap(URL.init(string:)), source.scheme == "https", source.host == "kenney.nl",
                  source.user == nil, source.password == nil, source.port == nil, source.query == nil, source.fragment == nil,
                  source.path.hasPrefix("/assets/"),
                  SHA256.hash(data: originalData).map({ String(format: "%02x", $0) }).joined() == origin["originalSHA256"]
            else { throw AnimationStorageError.invalidDocument }
        }
        let rotated = (5...8).contains(originalOrientation)
        guard normalizedWidth == (rotated ? originalHeight : originalWidth),
              normalizedHeight == (rotated ? originalWidth : originalHeight) else { throw AnimationStorageError.invalidDocument }
    }
}

struct LayerData: Codable, Equatable {
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
    /// Nil for a bundle whose folder name is not a project identity.
    let id: UUID?
    /// Folder name as listed; only an identifier, never a full path.
    let entryName: String
    let error: Error
    init(id: UUID?, entryName: String? = nil, error: Error) {
        self.id = id; self.entryName = entryName ?? id?.uuidString ?? "?"; self.error = error
    }
    /// Row text for the library: the original is always left in place.
    var message: String {
        "Can't open: \(id?.uuidString.lowercased() ?? entryName), original preserved — \(DeviceStorageManager.userMessage(for: error))"
    }
}

struct AnimationStorageListing {
    var animations: [AnimationMetadata] = []
    var failures: [AnimationStorageFailure] = []
    var unreadableProjectIDs: [UUID] { failures.compactMap(\.id) }
}

enum AnimationStorageError: Error, LocalizedError {
    case identityMismatch, invalidDocument, limitExceeded, unsafeFile
    case unsupportedVersion, storageCollision, legacyIndexCollision, invalidLegacyFilename, missingRevisionSelector
    case payloadIntegrity, unrecognizedEntry, migrationManifestMissing, migrationOriginalsChanged

    var errorDescription: String? {
        switch self {
        case .payloadIntegrity: return "The selected revision does not match its integrity receipt. It was not opened; its files were preserved for recovery."
        case .unrecognizedEntry: return "A folder in the project library is not a recognized project. It was left untouched."
        case .migrationManifestMissing: return "This project has no migration record, so there is nothing to roll back."
        case .migrationOriginalsChanged: return "The original legacy files no longer match the migration record. Rollback was not performed; nothing was changed."
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

enum MediaType: String {
    case photo = "photos"
    case video = "videos"
    case audio = "audio"
    case animation = "animations"
}

// Logical file bytes, not allocated filesystem blocks or the entire device.
// Unknown cache files are measured, never assumed disposable by their path.
struct StudioStorageUsage: Sendable {
    struct Bucket: Sendable {
        var files = 0
        var bytes: Int64 = 0
    }
    var projects = Bucket()
    /// Revision files other than each project's selected revision: interrupted
    /// saves and earlier history ("Recoverable unsaved data" in the storage
    /// sheet). Kept for recovery; only explicit cleanup may remove any of it.
    var recoverableUnsavedData = Bucket()
    var recentlyDeleted = Bucket()
    var media = Bucket()
    var otherDocuments = Bucket()
    var preservedCaches = Bucket()
    var skippedLinksAndSpecialFiles = 0
    var totalFileBytes: Int64 {
        projects.bytes + recoverableUnsavedData.bytes + recentlyDeleted.bytes + media.bytes + otherDocuments.bytes + preservedCaches.bytes
    }
}

struct StudioStorageScanRequest: Sendable {
    let documents: URL
    let caches: URL
    enum Failure: LocalizedError {
        case unreadable, changed, limit, invalidRoots
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Storage could not be read. No complete usage total is available."
            case .changed: return "Storage changed during the scan. Refresh to measure it again."
            case .limit: return "Storage scan exceeded its safety limit. No complete usage total is available."
            case .invalidRoots: return "Storage directories overlap. No usage total is available."
            }
        }
    }
    func scan(maximumEntries: Int = 100_000, maximumDepth: Int = 32,
              checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StudioStorageUsage {
        let documentPath = documents.standardizedFileURL.path
        let cachePath = caches.standardizedFileURL.path
        guard documentPath != cachePath, !documentPath.hasPrefix(cachePath + "/"),
              !cachePath.hasPrefix(documentPath + "/") else { throw Failure.invalidRoots }
        guard maximumEntries > 0, maximumDepth > 0 else { throw Failure.limit }
        var usage = StudioStorageUsage(), visited = 0
        var total: Int64 = 0
        // Selected revision name inside a project's `.sdi` store, read without
        // following links and bounded to the selector's maximum size.
        func selectedRevision(_ sdiDescriptor: Int32) -> String? {
            let fd = openat(sdiDescriptor, "current.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1024 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0, let object = try? JSONSerialization.jsonObject(with: Data(buffer[0..<count])) as? [String: Any],
                  let revision = object["revision"] as? String, let id = UUID(uuidString: revision) else { return nil }
            return id.uuidString + ".json"
        }
        struct RevisionContext { let sdiDescriptor: Int32; let selected: String?; let inRevisions: Bool }
        func walk(_ descriptor: Int32, depth: Int, category: String?, cache: Bool, context: RevisionContext? = nil) throws {
            try checkCancellation()
            guard depth <= maximumDepth else { throw Failure.limit }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw Failure.unreadable }
            let copied = dup(descriptor)
            guard copied >= 0 else { throw Failure.unreadable }
            guard let stream = fdopendir(copied) else { close(copied); throw Failure.unreadable }
            defer { closedir(stream) }
            while true {
                try checkCancellation()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw Failure.unreadable }
                    break
                }
                let nameLength = Int(entry.pointee.d_namlen) + 1
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: nameLength) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1
                guard visited <= maximumEntries else { throw Failure.limit }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.changed }
                let type = info.st_mode & S_IFMT
                let bucket = category ?? name
                if type == S_IFDIR {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Failure.changed }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev,
                          opened.st_ino == info.st_ino else { throw Failure.changed }
                    var next: RevisionContext?
                    // Documents(0) › Animations(1) › <uuid>(2) › .sdi(3) › revisions(4)
                    if !cache && bucket == "Animations" {
                        if depth == 2 && name == ".sdi" {
                            next = RevisionContext(sdiDescriptor: child, selected: selectedRevision(child), inRevisions: false)
                        } else if let context, depth == 3, name == "revisions", !context.inRevisions {
                            next = RevisionContext(sdiDescriptor: context.sdiDescriptor, selected: context.selected, inRevisions: true)
                        }
                    }
                    try walk(child, depth: depth + 1, category: bucket, cache: cache, context: next)
                } else if type == S_IFREG {
                    guard info.st_size >= 0 else { throw Failure.unreadable }
                    let sum = total.addingReportingOverflow(Int64(info.st_size))
                    guard !sum.overflow else { throw Failure.limit }
                    total = sum.partialValue
                    func add(_ target: inout StudioStorageUsage.Bucket) {
                        target.files += 1; target.bytes += Int64(info.st_size)
                    }
                    // Inside `.sdi/revisions`: only the selected payload is the
                    // project's current data. Every other revision file (an
                    // interrupted save or earlier history) is recoverable and
                    // measured separately; nothing here decides to remove it.
                    let unselectedRevision = context?.inRevisions == true && name.hasSuffix(".json") && name != context?.selected
                    if cache { add(&usage.preservedCaches) }
                    else if unselectedRevision { add(&usage.recoverableUnsavedData) }
                    else {
                        switch bucket {
                        case "Animations": add(&usage.projects)
                        case ".sdi-recently-deleted": add(&usage.recentlyDeleted)
                        case "Media": add(&usage.media)
                        default: add(&usage.otherDocuments)
                        }
                    }
                } else { usage.skippedLinksAndSpecialFiles += 1 }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.changed }
        }
        for (url, cache) in [(documents, false), (caches, true)] {
            try checkCancellation()
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ENOENT { continue }
                throw Failure.unreadable
            }
            defer { close(descriptor) }
            try walk(descriptor, depth: 0, category: nil, cache: cache)
        }
        try checkCancellation()
        return usage
    }
}

// Immutable selection ancestry is metadata, never guessed from modification dates.
// Existing v1 documents remain readable; snapshots before the first ancestry
// receipt and failed-save orphans are intentionally not cleanup candidates.
extension DeviceStorageManager {
    fileprivate struct LineageReference: Codable { let revision: UUID; let sha256: String }
    fileprivate struct LineageReceipt: Codable {
        let version: Int
        let project: UUID
        let revision: UUID
        let payloadSHA256: String
        let payloadBytes: Int
        let parent: LineageReference?
    }
    struct RevisionCleanupPreview: Sendable {
        let projectID: UUID
        let selectedRevision: UUID
        let confirmationToken: String
        let candidates: Int
        let removableFileBytes: Int64
        let retainedRevisions: Int
        let moreBatchesAvailable: Bool
    }
    struct RevisionCleanupResult: Sendable {
        var removedRevisions = 0
        /// Logical bytes removed, not a promise about APFS free-space allocation.
        var removedFileBytes: Int64 = 0
        var stoppedReason: String?
    }
    enum RevisionCleanupFailure: LocalizedError {
        case changed, busy, limit, invalid
        var errorDescription: String? {
            switch self {
            case .changed: return "Project storage changed. Nothing further was removed; refresh before trying again."
            case .busy: return "Another operation owns project storage. Try again after it finishes."
            case .limit: return "This cleanup exceeds its safe scan or byte limit. No cleanup was started."
            case .invalid: return "Revision ownership or recovery data could not be verified. No cleanup was started."
            }
        }
    }
    private struct RemovalJournal: Codable {
        let version: Int
        let project: UUID
        let revision: UUID
        let payloadSHA256: String
        let payloadBytes: Int
        let selectedRevision: UUID
        let device: Int64
        let inode: UInt64
    }
    fileprivate struct CleanupCandidate {
        let receipt: LineageReceipt
        let info: stat
        let alreadyStaged: Bool
    }
    fileprivate struct CleanupPlan {
        let preview: RevisionCleanupPreview
        let storage: URL
        let revisions: URL
        let lineage: URL?
        let candidates: [CleanupCandidate]
        let pointerData: Data
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static let lineageMarker = Data("SDI-SELECTED-REVISION-LINEAGE-1\n".utf8)
    private func lineageDirectory(_ storage: URL, create: Bool) throws -> URL {
        let directory = storage.appendingPathComponent("lineage-v1", isDirectory: true)
        let marker = Self.lineageMarker
        if !itemExists(directory), create {
            let staging = storage.appendingPathComponent(".lineage-init-" + UUID().uuidString)
            try checkedDirectory(staging, create: true)
            let markerPath = staging.appendingPathComponent("format")
            try Self.writeProtected(marker, to: markerPath, options: .withoutOverwriting)
            let markerHandle = try FileHandle(forWritingTo: markerPath)
            do { try markerHandle.synchronize(); try markerHandle.close() }
            catch { try? markerHandle.close(); throw error }
            try synchronizeRevisionDirectory(staging)
            try FileManager.default.moveItem(at: staging, to: directory)
            try synchronizeRevisionDirectory(storage)
        }
        try checkedDirectory(directory)
        guard try safeRevisionRead(directory.appendingPathComponent("format"), maximum: 64).data == marker else {
            throw RevisionCleanupFailure.invalid
        }
        return directory
    }
    // Cooperative, cross-instance/process ownership; an existing nonempty file or
    // symlink is a collision, never adopted. The lock is never removed/replaced.
    private func optionalProjectMutationLock(_ project: URL) throws -> Int32? {
        guard itemExists(project.appendingPathComponent(".sdi")) else { return nil }
        return try revisionMutationLock(revisionDirectory(project, create: false))
    }
    private func revisionMutationLock(_ storage: URL) throws -> Int32 {
        let url = storage.appendingPathComponent(".revision-mutation-lock-v1")
        let directory = try revisionDirectoryDescriptor(storage)
        defer { close(directory) }
        let fd = openat(directory, url.lastPathComponent, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw RevisionCleanupFailure.invalid }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size == 0 else { close(fd); throw RevisionCleanupFailure.invalid }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RevisionCleanupFailure.busy }
        var named = stat()
        guard fstatat(directory, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameRevisionFile(info, named) else { flock(fd, LOCK_UN); close(fd); throw RevisionCleanupFailure.changed }
        return fd
    }
    // Opens every ancestor without following links, then uses descriptor-relative
    // reads. A FIFO cannot block, and replacement/modification fails verification.
    private func safeRevisionRead(_ url: URL, maximum: Int) throws -> (data: Data, info: stat) {
        let parent = try revisionDirectoryDescriptor(url.deletingLastPathComponent())
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RevisionCleanupFailure.changed }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum else { throw RevisionCleanupFailure.invalid }
        var data = Data(count: Int(before.st_size)), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
            }
            guard count > 0 else { throw RevisionCleanupFailure.changed }
            offset += count
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0,
              fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameRevisionFile(before, after), sameRevisionFile(before, named) else { throw RevisionCleanupFailure.changed }
        return (data, before)
    }
    private func revisionDirectoryDescriptor(_ url: URL) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RevisionCleanupFailure.invalid }
        var components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
        // Apple exposes /var and /tmp through fixed system aliases. Expand only
        // their exact system destinations; arbitrary data-directory links remain
        // forbidden. iOS sandbox URLs and macOS temporary fixtures use /var.
        if let first = components.first, first == "var" || first == "tmp" {
            var link = [CChar](repeating: 0, count: 256)
            let count = readlink("/" + first, &link, link.count - 1)
            if count >= 0 {
                let target = String(cString: link)
                guard target == "private/" + first || target == "/private/" + first else {
                    close(fd); throw RevisionCleanupFailure.changed
                }
                components.insert("private", at: 0)
            } else if errno != EINVAL { close(fd); throw RevisionCleanupFailure.changed }
        }
        for component in components {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw RevisionCleanupFailure.changed }
            fd = next
        }
        return fd
    }
    private func synchronizeRevisionDirectory(_ url: URL) throws {
        let fd = try revisionDirectoryDescriptor(url)
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RevisionCleanupFailure.changed }
    }
    private func sameRevisionFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_nlink == b.st_nlink &&
        a.st_mode == b.st_mode && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func lineageReceipt(_ id: UUID, digest: String, in revisions: URL, project: UUID) throws -> LineageReceipt {
        let lineage = try lineageDirectory(revisions.deletingLastPathComponent(), create: false)
        let bytes = try safeRevisionRead(lineage.appendingPathComponent(id.uuidString + ".json"), maximum: 2048).data
        guard Self.digest(bytes) == digest else { throw RevisionCleanupFailure.invalid }
        let value = try JSONDecoder().decode(LineageReceipt.self, from: bytes)
        guard value.version == 1, value.project == project, value.revision == id,
              value.payloadBytes > 0, value.payloadBytes <= Self.maximumSnapshotBytes,
              value.payloadSHA256.count == 64 else { throw RevisionCleanupFailure.invalid }
        return value
    }
    private func verifiedSnapshot(_ url: URL, receipt: LineageReceipt) throws -> stat {
        let value = try safeRevisionRead(url, maximum: Self.maximumSnapshotBytes)
        guard value.data.count == receipt.payloadBytes, Self.digest(value.data) == receipt.payloadSHA256 else {
            throw RevisionCleanupFailure.changed
        }
        let snapshot = try JSONDecoder().decode(Revision.self, from: value.data)
        guard snapshot.version == 1, snapshot.project.id == receipt.project else { throw RevisionCleanupFailure.invalid }
        try validate(snapshot.project, exactFrameCount: true)
        return value.info
    }
    private func removalJournal(_ receipt: LineageReceipt, lineage: URL) throws -> RemovalJournal? {
        let path = lineage.appendingPathComponent(receipt.revision.uuidString + ".cleanup-v1.json")
        guard itemExists(path) else { return nil }
        let journal = try JSONDecoder().decode(RemovalJournal.self, from: safeRevisionRead(path, maximum: 2048).data)
        guard journal.version == 1, journal.project == receipt.project, journal.revision == receipt.revision,
              journal.payloadSHA256 == receipt.payloadSHA256, journal.payloadBytes == receipt.payloadBytes,
              journal.selectedRevision != receipt.revision else { throw RevisionCleanupFailure.invalid }
        return journal
    }
    struct RevisionCleanupScanProgress: Sendable {
        let scannedRevisions: Int
        let preview: RevisionCleanupPreview?
    }
    /// Process-owned cursor. No disk cursor is trusted after cancellation or process death.
    final class RevisionCleanupScan: @unchecked Sendable {
        let id = UUID()
        let projectID: UUID
        fileprivate weak var owner: DeviceStorageManager?
        fileprivate let storage: URL
        fileprivate let revisions: URL
        fileprivate let lineage: URL?
        fileprivate let pointerData: Data
        fileprivate let selectedRevision: UUID
        fileprivate var next: LineageReference?
        fileprivate var cycleAnchor: UUID?
        fileprivate var cyclePower = 1, cycleDistance = 0
        fileprivate var depth = 0, readBudget = 512 * 1024 * 1024
        fileprivate var candidates: [CleanupCandidate] = []
        fileprivate var protected: [CleanupCandidate] = []
        fileprivate var bytes: Int64 = 0
        fileprivate var more = false
        fileprivate var plan: CleanupPlan?
        fileprivate var lockFD: Int32
        fileprivate var storageFD: Int32
        fileprivate var revisionsFD: Int32
        fileprivate var lineageFD: Int32
        private let lifecycleLock = NSLock()
        private var cancelled = false, operations = 0
        fileprivate let idleTimeout: TimeInterval
        fileprivate var expiry: TimeInterval = 0
        fileprivate var timer: DispatchSourceTimer?
        fileprivate init(owner: DeviceStorageManager, projectID: UUID, storage: URL, revisions: URL,
                         lineage: URL?, pointerData: Data, selectedRevision: UUID, next: LineageReference?,
                         lockFD: Int32, storageFD: Int32, revisionsFD: Int32, lineageFD: Int32, idleTimeout: TimeInterval) {
            self.owner = owner; self.projectID = projectID; self.storage = storage; self.revisions = revisions
            self.lineage = lineage; self.pointerData = pointerData; self.selectedRevision = selectedRevision
            self.next = next; self.lockFD = lockFD; self.storageFD = storageFD; self.idleTimeout = idleTimeout
            self.revisionsFD = revisionsFD; self.lineageFD = lineageFD
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.setEventHandler { [weak self] in _ = self?.isActive() }
            self.timer = timer; touch(); timer.resume()
        }
        fileprivate func touch() {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            guard !cancelled else { return }
            expiry = ProcessInfo.processInfo.systemUptime + idleTimeout
            timer?.schedule(deadline: .now() + idleTimeout)
        }
        private func closeOwnedDescriptors() {
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
            if storageFD >= 0 { close(storageFD); storageFD = -1 }
            if revisionsFD >= 0 { close(revisionsFD); revisionsFD = -1 }
            if lineageFD >= 0 { close(lineageFD); lineageFD = -1 }
        }
        private func cancelLocked() {
            cancelled = true; timer?.cancel(); timer = nil
            if operations == 0 { closeOwnedDescriptors() }
        }
        func cancel() {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            cancelLocked()
        }
        func isActive() -> Bool {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            if !cancelled && ProcessInfo.processInfo.systemUptime >= expiry { cancelLocked() }
            return !cancelled && lockFD >= 0
        }
        fileprivate func beginOperation() throws {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            if !cancelled && ProcessInfo.processInfo.systemUptime >= expiry { cancelLocked() }
            guard !cancelled && lockFD >= 0 else { throw RevisionCleanupFailure.changed }
            operations += 1
        }
        fileprivate func endOperation() {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            operations -= 1
            if operations == 0 && cancelled { closeOwnedDescriptors() }
        }
        deinit { timer?.cancel(); closeOwnedDescriptors() }

    }
    func beginRevisionCleanupScan(id: UUID, idleTimeout: TimeInterval = 120) throws -> RevisionCleanupScan {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        guard idleTimeout.isFinite, (0.01...120).contains(idleTimeout) else { throw RevisionCleanupFailure.limit }
        let storage = try revisionDirectory(animationsDir.appendingPathComponent(id.uuidString), create: false)
        let lock = try revisionMutationLock(storage)
        var directory: Int32 = -1, revisionsFD: Int32 = -1, lineageFD: Int32 = -1
        var transferred = false
        defer { if !transferred { flock(lock, LOCK_UN); close(lock); if directory >= 0 { close(directory) }; if revisionsFD >= 0 { close(revisionsFD) }; if lineageFD >= 0 { close(lineageFD) } } }
        directory = try revisionDirectoryDescriptor(storage)
        let pointerData = try safeRevisionRead(storage.appendingPathComponent("current.json"), maximum: 1024).data
        let pointer = try JSONDecoder().decode(CurrentRevision.self, from: pointerData)
        guard pointer.version == 1 else { throw RevisionCleanupFailure.invalid }
        let lineage = try pointer.lineageSHA256.map { _ in try lineageDirectory(storage, create: false) }
        revisionsFD = try revisionDirectoryDescriptor(storage.appendingPathComponent("revisions"))
        if let lineage { lineageFD = try revisionDirectoryDescriptor(lineage) }
        if lineage == nil { _ = try loadAnimation(id: id) }
        let scan = RevisionCleanupScan(owner: self, projectID: id, storage: storage,
            revisions: storage.appendingPathComponent("revisions"), lineage: lineage, pointerData: pointerData,
            selectedRevision: pointer.revision, next: pointer.lineageSHA256.map { .init(revision: pointer.revision, sha256: $0) },
            lockFD: lock, storageFD: directory, revisionsFD: revisionsFD, lineageFD: lineageFD, idleTimeout: idleTimeout)
        transferred = true
        return scan
    }
    private func requireScanAuthority(_ scan: RevisionCleanupScan) throws {
        guard scan.owner === self, scan.isActive() else { throw RevisionCleanupFailure.changed }
        try requireScanDirectories(scan)
        guard try safeRevisionRead(scan.storage.appendingPathComponent("current.json"), maximum: 1024).data == scan.pointerData else {
            throw RevisionCleanupFailure.changed
        }
    }
    private func requireScanDirectories(_ scan: RevisionCleanupScan) throws {
        func sameDirectory(_ path: URL, heldFD: Int32) throws {
            var held = stat(), named = stat()
            let directory = try revisionDirectoryDescriptor(path); defer { close(directory) }
            guard fstat(heldFD, &held) == 0, fstat(directory, &named) == 0,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw RevisionCleanupFailure.changed }
        }
        try sameDirectory(scan.storage, heldFD: scan.storageFD)
        try sameDirectory(scan.revisions, heldFD: scan.revisionsFD)
        if let lineage = scan.lineage { try sameDirectory(lineage, heldFD: scan.lineageFD) }
        var heldLock = stat(), namedLock = stat()
        guard fstat(scan.lockFD, &heldLock) == 0,
              fstatat(scan.storageFD, ".revision-mutation-lock-v1", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              heldLock.st_mode & S_IFMT == S_IFREG, heldLock.st_nlink == 1, heldLock.st_size == 0,
              sameRevisionFile(heldLock, namedLock) else { throw RevisionCleanupFailure.changed }
    }
    func advanceRevisionCleanupScan(_ scan: RevisionCleanupScan, maximumReceipts: Int = 256,
                                    checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> RevisionCleanupScanProgress {
        guard scan.owner === self else { throw RevisionCleanupFailure.changed }
        try scan.beginOperation(); defer { scan.endOperation() }
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        do {
            guard (1...256).contains(maximumReceipts) else { throw RevisionCleanupFailure.limit }
            try requireScanAuthority(scan); try checkCancellation()
            if let plan = scan.plan { scan.touch(); return .init(scannedRevisions: scan.depth, preview: plan.preview) }
            var processed = 0
            // Budget receipt+journal maxima plus format checks; reserve authority overhead.
            var metadataBudget = 512 * 1024 - 4096
            let pageStarted = ProcessInfo.processInfo.systemUptime
            while let next = scan.next, processed < maximumReceipts, metadataBudget >= 4160 {
                // A single bounded snapshot read can exceed this cooperative yield target.
                if processed > 0 && ProcessInfo.processInfo.systemUptime - pageStarted >= 0.05 { break }
                metadataBudget -= 4160
                try checkCancellation()
                guard scan.isActive() else { throw CancellationError() }
                guard scan.depth < Int.max - 1 else { throw RevisionCleanupFailure.limit }
                // Brent cycle detection retains constant metadata, not a growing UUID set.
                if scan.cycleAnchor == nil { scan.cycleAnchor = next.revision }
                else {
                    scan.cycleDistance += 1
                    guard scan.cycleAnchor != next.revision else { throw RevisionCleanupFailure.invalid }
                    if scan.cycleDistance == scan.cyclePower {
                        scan.cycleAnchor = next.revision; scan.cycleDistance = 0
                        guard scan.cyclePower <= Int.max / 2 else { throw RevisionCleanupFailure.limit }
                        scan.cyclePower *= 2
                    }
                }
                guard let lineage = scan.lineage else { throw RevisionCleanupFailure.invalid }
                let receipt = try lineageReceipt(next.revision, digest: next.sha256, in: scan.revisions, project: scan.projectID)
                let payload = scan.revisions.appendingPathComponent(receipt.revision.uuidString + ".json")
                let staged = lineage.appendingPathComponent(receipt.revision.uuidString + ".removing.json")
                let journal = try removalJournal(receipt, lineage: lineage)
                if scan.depth < 2 {
                    guard journal == nil, !itemExists(staged) else { throw RevisionCleanupFailure.invalid }
                    guard receipt.payloadBytes <= scan.readBudget else { throw RevisionCleanupFailure.limit }
                    scan.readBudget -= receipt.payloadBytes
                    let info = try verifiedSnapshot(payload, receipt: receipt)
                    scan.protected.append(.init(receipt: receipt, info: info, alreadyStaged: false))
                } else if itemExists(payload) || itemExists(staged) {
                    guard !(itemExists(payload) && itemExists(staged)), !itemExists(staged) || journal != nil else { throw RevisionCleanupFailure.invalid }
                    if scan.candidates.count < 8 && receipt.payloadBytes <= scan.readBudget {
                        scan.readBudget -= receipt.payloadBytes
                        let isStaged = itemExists(staged)
                        let info = try verifiedSnapshot(isStaged ? staged : payload, receipt: receipt)
                        if let journal { guard Int64(info.st_dev) == journal.device, UInt64(info.st_ino) == journal.inode else { throw RevisionCleanupFailure.changed } }
                        scan.candidates.append(.init(receipt: receipt, info: info, alreadyStaged: isStaged))
                        scan.bytes += Int64(receipt.payloadBytes)
                    } else { scan.more = true }
                } else { guard journal != nil else { throw RevisionCleanupFailure.invalid } }
                scan.depth += 1; processed += 1; scan.next = receipt.parent
            }
            try requireScanAuthority(scan); try checkCancellation()
            scan.touch()
            guard scan.next == nil else { return .init(scannedRevisions: scan.depth, preview: nil) }
            var consent = scan.pointerData
            consent.append(Data(scan.id.uuidString.utf8))
            for candidate in scan.candidates {
                let info = candidate.info, receipt = candidate.receipt
                consent.append(Data(("\n" + receipt.revision.uuidString + ":" + receipt.payloadSHA256 +
                    ":\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(candidate.alreadyStaged)").utf8))
            }
            let preview = RevisionCleanupPreview(projectID: scan.projectID, selectedRevision: scan.selectedRevision,
                confirmationToken: Self.digest(consent), candidates: scan.candidates.count, removableFileBytes: scan.bytes,
                retainedRevisions: scan.lineage == nil ? 1 : min(scan.depth, 2), moreBatchesAvailable: scan.more)
            scan.plan = CleanupPlan(preview: preview, storage: scan.storage, revisions: scan.revisions,
                lineage: scan.lineage, candidates: scan.candidates, pointerData: scan.pointerData)
            return .init(scannedRevisions: scan.depth, preview: preview)
        } catch { scan.cancel(); throw error }
    }
    func removeObsoleteRevisions(scan: RevisionCleanupScan, expectedConfirmationToken: String,
                                 checkCancellation: () throws -> Void = { try Task.checkCancellation() },
                                 checkpoint: (String, UUID) throws -> Void = { _, _ in }) throws -> RevisionCleanupResult {
        guard scan.owner === self else { throw RevisionCleanupFailure.changed }
        try scan.beginOperation(); defer { scan.endOperation() }
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        defer { scan.cancel() }
        try requireScanAuthority(scan)
        guard let plan = scan.plan, plan.preview.confirmationToken == expectedConfirmationToken else { throw RevisionCleanupFailure.changed }
        // Recheck both protected payloads before any irreversible action.
        for protected in scan.protected {
            let info = try verifiedSnapshot(scan.revisions.appendingPathComponent(protected.receipt.revision.uuidString + ".json"), receipt: protected.receipt)
            guard sameRevisionFile(info, protected.info) else { throw RevisionCleanupFailure.changed }
        }
        return try removeCleanupPlan(plan, id: scan.projectID, expectedSelectedRevision: scan.selectedRevision,
            checkCancellation: { try checkCancellation(); try self.requireScanAuthority(scan) },
            checkpoint: { stage, revision in
                try checkpoint(stage, revision)
                // Ignore cancellation until this individual journal operation finishes,
                // but reject replacement of any owned directory before proceeding.
                try self.requireScanDirectories(scan)
            })
    }

    private func cleanupPlan(id: UUID, checkCancellation: () throws -> Void) throws -> CleanupPlan {
        try checkCancellation()
        let project = animationsDir.appendingPathComponent(id.uuidString)
        let storage = try revisionDirectory(project, create: false)
        let revisions = storage.appendingPathComponent("revisions")
        let pointerData = try safeRevisionRead(storage.appendingPathComponent("current.json"), maximum: 1024).data
        let pointer = try JSONDecoder().decode(CurrentRevision.self, from: pointerData)
        guard pointer.version == 1 else { throw RevisionCleanupFailure.invalid }
        guard let digest = pointer.lineageSHA256 else {
            _ = try loadAnimation(id: id)
            return CleanupPlan(preview: .init(projectID: id, selectedRevision: pointer.revision, confirmationToken: Self.digest(pointerData), candidates: 0,
                removableFileBytes: 0, retainedRevisions: 1, moreBatchesAvailable: false), storage: storage,
                revisions: revisions, lineage: nil, candidates: [], pointerData: pointerData)
        }
        let lineage = try lineageDirectory(storage, create: false)
        var reference: LineageReference? = .init(revision: pointer.revision, sha256: digest)
        var seen = Set<UUID>(), candidates: [CleanupCandidate] = [], depth = 0, bytes: Int64 = 0
        var readBudget = 512 * 1024 * 1024, more = false
        while let next = reference {
            try checkCancellation()
            guard depth < 4096, seen.insert(next.revision).inserted else { throw RevisionCleanupFailure.limit }
            let receipt = try lineageReceipt(next.revision, digest: next.sha256, in: revisions, project: id)
            let payload = revisions.appendingPathComponent(receipt.revision.uuidString + ".json")
            let staged = lineage.appendingPathComponent(receipt.revision.uuidString + ".removing.json")
            let journal = try removalJournal(receipt, lineage: lineage)
            if depth < 2 {
                guard journal == nil, !itemExists(staged) else { throw RevisionCleanupFailure.invalid }
                guard receipt.payloadBytes <= readBudget else { throw RevisionCleanupFailure.limit }
                readBudget -= receipt.payloadBytes
                _ = try verifiedSnapshot(payload, receipt: receipt)
            } else if itemExists(payload) || itemExists(staged) {
                guard !(itemExists(payload) && itemExists(staged)), !itemExists(staged) || journal != nil else {
                    throw RevisionCleanupFailure.invalid
                }
                if candidates.count < 8 && receipt.payloadBytes <= readBudget {
                    readBudget -= receipt.payloadBytes
                    let isStaged = itemExists(staged)
                    let info = try verifiedSnapshot(isStaged ? staged : payload, receipt: receipt)
                    if let journal {
                        guard Int64(info.st_dev) == journal.device, UInt64(info.st_ino) == journal.inode else {
                            throw RevisionCleanupFailure.changed
                        }
                    }
                    candidates.append(.init(receipt: receipt, info: info, alreadyStaged: isStaged))
                    bytes += Int64(receipt.payloadBytes)
                } else { more = true }
            } else {
                // Missing payload is legitimate only after an explicit, durable
                // cleanup authorization. Unexplained missing history fails closed.
                guard journal != nil else { throw RevisionCleanupFailure.invalid }
            }
            depth += 1; reference = receipt.parent
        }
        try checkCancellation()
        guard try safeRevisionRead(storage.appendingPathComponent("current.json"), maximum: 1024).data == pointerData else {
            throw RevisionCleanupFailure.changed
        }
        var consent = pointerData
        for candidate in candidates {
            let info = candidate.info, receipt = candidate.receipt
            consent.append(Data(("\n" + receipt.revision.uuidString + ":" + receipt.payloadSHA256 +
                ":\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(candidate.alreadyStaged)").utf8))
        }
        return CleanupPlan(preview: .init(projectID: id, selectedRevision: pointer.revision,
            confirmationToken: Self.digest(consent), candidates: candidates.count, removableFileBytes: bytes, retainedRevisions: min(depth, 2), moreBatchesAvailable: more),
            storage: storage, revisions: revisions, lineage: lineage, candidates: candidates, pointerData: pointerData)
    }
    func previewObsoleteRevisions(id: UUID, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> RevisionCleanupPreview {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        let project = animationsDir.appendingPathComponent(id.uuidString)
        let storage = try revisionDirectory(project, create: false)
        let lock = try revisionMutationLock(storage); defer { flock(lock, LOCK_UN); close(lock) }
        return try cleanupPlan(id: id, checkCancellation: checkCancellation).preview
    }
    /// Explicit action only. Each completed removal is durable; interruption
    /// resumes from exact inode/hash journals. Cancellation after a removal
    /// returns its factual partial receipt instead of pretending nothing changed.
    func removeObsoleteRevisions(id: UUID, expectedSelectedRevision: UUID, expectedConfirmationToken: String,
                                 checkCancellation: () throws -> Void = { try Task.checkCancellation() },
                                 checkpoint: (String, UUID) throws -> Void = { _, _ in }) throws -> RevisionCleanupResult {
        Self.operationLock.lock(); defer { Self.operationLock.unlock() }
        let storage = try revisionDirectory(animationsDir.appendingPathComponent(id.uuidString), create: false)
        let lock = try revisionMutationLock(storage); defer { flock(lock, LOCK_UN); close(lock) }
        let plan = try cleanupPlan(id: id, checkCancellation: checkCancellation)
        guard plan.preview.selectedRevision == expectedSelectedRevision,
              plan.preview.confirmationToken == expectedConfirmationToken else { throw RevisionCleanupFailure.changed }
        return try removeCleanupPlan(plan, id: id, expectedSelectedRevision: expectedSelectedRevision,
            checkCancellation: checkCancellation, checkpoint: checkpoint)
    }
    private func removeCleanupPlan(_ plan: CleanupPlan, id: UUID, expectedSelectedRevision: UUID,
                                   checkCancellation: () throws -> Void,
                                   checkpoint: (String, UUID) throws -> Void) throws -> RevisionCleanupResult {
        let storage = plan.storage
        guard let lineage = plan.lineage else { return RevisionCleanupResult() }
        let revisionFD = try revisionDirectoryDescriptor(plan.revisions); defer { close(revisionFD) }
        let lineageFD = try revisionDirectoryDescriptor(lineage); defer { close(lineageFD) }
        var result = RevisionCleanupResult()
        for candidate in plan.candidates {
            do {
                try checkCancellation()
                guard try safeRevisionRead(storage.appendingPathComponent("current.json"), maximum: 1024).data == plan.pointerData else {
                    throw RevisionCleanupFailure.changed
                }
                let receipt = candidate.receipt, name = receipt.revision.uuidString + ".json"
                let stageName = receipt.revision.uuidString + ".removing.json"
                let source = candidate.alreadyStaged ? lineage.appendingPathComponent(stageName) : plan.revisions.appendingPathComponent(name)
                let latest = try verifiedSnapshot(source, receipt: receipt)
                guard sameRevisionFile(latest, candidate.info) else { throw RevisionCleanupFailure.changed }
                if try removalJournal(receipt, lineage: lineage) == nil {
                    let journal = RemovalJournal(version: 1, project: id, revision: receipt.revision,
                        payloadSHA256: receipt.payloadSHA256, payloadBytes: receipt.payloadBytes,
                        selectedRevision: expectedSelectedRevision, device: Int64(latest.st_dev), inode: UInt64(latest.st_ino))
                    let path = lineage.appendingPathComponent(receipt.revision.uuidString + ".cleanup-v1.json")
                    try JSONEncoder().encode(journal).write(to: path, options: .withoutOverwriting)
                    let handle = try FileHandle(forWritingTo: path)
                    do { try handle.synchronize(); try handle.close() }
                    catch { try? handle.close(); throw error }
                }
                // A prior attempt may have created the journal but failed its
                // durability barrier. Retry must establish it unconditionally.
                let journalPath = lineage.appendingPathComponent(receipt.revision.uuidString + ".cleanup-v1.json")
                let journalHandle = try FileHandle(forWritingTo: journalPath)
                do { try journalHandle.synchronize(); try journalHandle.close() }
                catch { try? journalHandle.close(); throw error }
                guard fsync(lineageFD) == 0 else { throw RevisionCleanupFailure.changed }
                try checkpoint("journal-durable", receipt.revision)
                guard try safeRevisionRead(storage.appendingPathComponent("current.json"), maximum: 1024).data == plan.pointerData else {
                    throw RevisionCleanupFailure.changed
                }
                // Past this point complete this one removal; cancellation is
                // observed again before the next candidate, never hidden.
                if !candidate.alreadyStaged {
                    guard renameatx_np(revisionFD, name, lineageFD, stageName, UInt32(RENAME_EXCL)) == 0 else {
                        throw RevisionCleanupFailure.changed
                    }
                }
                guard fsync(revisionFD) == 0, fsync(lineageFD) == 0 else { throw RevisionCleanupFailure.changed }
                try checkpoint("payload-staged", receipt.revision)
                // An unexpected selector change must never make an older
                // newly-selected payload disappear. Restore only our exact
                // staged inode and never overwrite a newly created source name.
                func requireUnchangedSelector() throws {
                    if (try? safeRevisionRead(storage.appendingPathComponent("current.json"), maximum: 1024).data) != plan.pointerData {
                        var staged = stat()
                        if fstatat(lineageFD, stageName, &staged, AT_SYMLINK_NOFOLLOW) == 0,
                           staged.st_dev == latest.st_dev, staged.st_ino == latest.st_ino {
                            if renameatx_np(lineageFD, stageName, revisionFD, name, UInt32(RENAME_EXCL)) == 0 {
                                _ = fsync(revisionFD); _ = fsync(lineageFD)
                            }
                        }
                        throw RevisionCleanupFailure.changed
                    }
                }
                try requireUnchangedSelector()
                let stagedInfo = try verifiedSnapshot(lineage.appendingPathComponent(stageName), receipt: receipt)
                guard stagedInfo.st_dev == latest.st_dev, stagedInfo.st_ino == latest.st_ino else {
                    throw RevisionCleanupFailure.changed
                }
                var namedStage = stat()
                guard fstatat(lineageFD, stageName, &namedStage, AT_SYMLINK_NOFOLLOW) == 0,
                      sameRevisionFile(namedStage, stagedInfo) else { throw RevisionCleanupFailure.changed }
                try requireUnchangedSelector()
                guard unlinkat(lineageFD, stageName, 0) == 0 else { throw RevisionCleanupFailure.changed }
                result.removedRevisions += 1
                result.removedFileBytes += Int64(receipt.payloadBytes)
                guard fsync(lineageFD) == 0 else { throw RevisionCleanupFailure.changed }
                try checkpoint("payload-removed", receipt.revision)
                // Metadata is tiny and retained for provenance/retry; do not
                // count it as reclaimed bytes or remove it automatically.
            } catch {
                if result.removedRevisions == 0 { throw error }
                result.stoppedReason = error is CancellationError ? "Stopped after the completed removals." : error.localizedDescription
                return result
            }
        }
        return result
    }
}

// The request exposes only serialized storage operations to a utility worker.
// DeviceStorageManager serializes all mutable state; it is not generally Sendable.
struct StudioRevisionCleanupRequest: @unchecked Sendable {
    fileprivate let store: DeviceStorageManager
    let projectID: UUID
    init(store: DeviceStorageManager, projectID: UUID) { self.store = store; self.projectID = projectID }
    func beginScan() throws -> DeviceStorageManager.RevisionCleanupScan { try store.beginRevisionCleanupScan(id: projectID) }
    func advance(_ scan: DeviceStorageManager.RevisionCleanupScan) throws -> DeviceStorageManager.RevisionCleanupScanProgress {
        guard scan.projectID == projectID else { throw DeviceStorageManager.RevisionCleanupFailure.changed }
        return try store.advanceRevisionCleanupScan(scan)
    }
    func remove(scan: DeviceStorageManager.RevisionCleanupScan, confirmationToken: String) throws -> DeviceStorageManager.RevisionCleanupResult {
        guard scan.projectID == projectID else { throw DeviceStorageManager.RevisionCleanupFailure.changed }
        return try store.removeObsoleteRevisions(scan: scan, expectedConfirmationToken: confirmationToken)
    }
    func preview() throws -> DeviceStorageManager.RevisionCleanupPreview { try store.previewObsoleteRevisions(id: projectID) }
    func remove(expected: UUID, confirmationToken: String) throws -> DeviceStorageManager.RevisionCleanupResult {
        try store.removeObsoleteRevisions(id: projectID, expectedSelectedRevision: expected, expectedConfirmationToken: confirmationToken)
    }
}
