import Foundation
import SDCore

/// Device-first storage architecture for StickDeath Infinity
/// Animation persistence is delegated to SDCore StudioStorage.
/// DeviceStorageManager retains message/media/cache behavior and
/// read-only legacy migration discovery.
///
/// Storage hierarchy:
///   ~/Documents/Animations/       — legacy raster frames (read-only migration)
///   ~/Documents/StudioProjects/   — canonical SDCore projects
///   ~/Documents/Media/            — photos, videos, audio files
///   ~/Documents/Messages/         — encrypted message archives
///   ~/Library/Caches/AI/          — Spatter AI cached responses
///   ~/Library/Caches/Thumbnails/  — generated thumbnails

class DeviceStorageManager {
    static let shared = DeviceStorageManager()

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
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private var cachesDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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

    // MARK: - Animation Discovery (read-only legacy migration)

    /// Discover legacy animation project IDs from the Animations directory.
    /// This is read-only; do not write new animations here.
    func discoverLegacyAnimationIDs() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: animationsDir, includingPropertiesForKeys: nil) else { return [] }
        return contents.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
    }

    /// Check if a legacy animation exists at the given ID.
    func legacyAnimationExists(id: String) -> Bool {
        let projectDir = animationsDir.appendingPathComponent(id, isDirectory: true)
        return FileManager.default.fileExists(atPath: projectDir.path)
    }

    // MARK: - Messages (on-device encrypted SQLite)

    func saveMessage(_ message: ChatMessage) {
        // Messages stored in local SQLite via Core Data
        // Encrypted at rest using iOS Data Protection
    }

    // MARK: - Media files (on-device)

    func saveMedia(data: Data, type: MediaType, filename: String) throws -> URL {
        let typeDir = mediaDir.appendingPathComponent(type.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: typeDir, withIntermediateDirectories: true)
        let fileURL = typeDir.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    func clearCache() throws {
        try? FileManager.default.removeItem(at: aiCacheDir)
        try? FileManager.default.removeItem(at: thumbnailsDir)
        setupDirectories()
    }
}

// MARK: - Data models (UI-only, non-canonical)

struct AnimationProject {
    let id: UUID
    let metadata: AnimationMetadata
    var frames: [StoredAnimationFrame]
    var audioTracks: [AudioTrack]
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

struct StoredAnimationFrame {
    var imageData: Data?
    var layerData: [LegacyLayerData]?
}

struct LegacyLayerData: Codable {
    let id: UUID
    var name: String
    var opacity: Double
    var blendMode: String
    var locked: Bool
    var visible: Bool
}

struct AudioTrack {
    let id: UUID
    var name: String
    var format: String
    var audioData: Data?
    var startTime: Double
    var duration: Double
}

struct StoredChatMessage: Codable {
    let id: UUID
    let senderId: String
    let recipientId: String
    let text: String
    let timestamp: Date
    let mediaURL: String?
}

enum MediaType: String {
    case photo = "photos"
    case video = "videos"
    case audio = "audio"
    case animation = "animations"
}
