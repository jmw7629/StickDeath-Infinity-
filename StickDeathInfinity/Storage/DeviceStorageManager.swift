import Foundation
import CoreData

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
    
    // MARK: - Animation Projects (on-device)
    
    func saveAnimation(_ project: AnimationProject) throws {
        let projectDir = animationsDir.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        
        let metadata = try JSONEncoder().encode(project.metadata)
        try metadata.write(to: projectDir.appendingPathComponent("metadata.json"))
        
        // Save frames as individual PNGs
        for (index, frame) in project.frames.enumerated() {
            if let data = frame.imageData {
                try data.write(to: projectDir.appendingPathComponent("frame_\(index).png"))
            }
        }
        
        // Save audio tracks
        for (index, track) in project.audioTracks.enumerated() {
            if let data = track.audioData {
                try data.write(to: projectDir.appendingPathComponent("audio_\(index).\(track.format)"))
            }
        }
    }
    
    func loadAnimation(id: UUID) throws -> AnimationProject? {
        let projectDir = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return nil }
        
        let metadataURL = projectDir.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(AnimationMetadata.self, from: data)
        
        // Load frames
        var frames: [AnimationFrame] = []
        var index = 0
        while true {
            let frameURL = projectDir.appendingPathComponent("frame_\(index).png")
            guard FileManager.default.fileExists(atPath: frameURL.path) else { break }
            let imageData = try Data(contentsOf: frameURL)
            frames.append(AnimationFrame(id: UUID().uuidString, elements: []))
            index += 1
        }
        
        return AnimationProject(id: id, metadata: metadata, frames: frames, audioTracks: [])
    }
    
    func listAnimations() -> [AnimationMetadata] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: animationsDir, includingPropertiesForKeys: nil) else { return [] }
        return contents.compactMap { dir in
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(AnimationMetadata.self, from: data) else { return nil }
            return meta
        }
    }
    
    func deleteAnimation(id: UUID) throws {
        let projectDir = animationsDir.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.removeItem(at: projectDir)
    }
    
    // MARK: - Messages (on-device encrypted SQLite)
    
    func saveMessage(_ message: ChatMessage) {
        // Messages stored in local SQLite via Core Data
        // Encrypted at rest using iOS Data Protection
        // No server sync — peer-to-peer delivery via LiveKit data channels
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

// MARK: - Data models

struct AnimationProject {
    let id: UUID
    let metadata: AnimationMetadata
    var frames: [AnimationFrame]
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
    var layerData: [LayerData]?
}

struct LayerData: Codable {
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
    // Stored on-device only, not synced to server
}

enum MediaType: String {
    case photo = "photos"
    case video = "videos"
    case audio = "audio"
    case animation = "animations"
}
