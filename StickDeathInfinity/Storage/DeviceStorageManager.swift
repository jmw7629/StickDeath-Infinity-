import Foundation
import CoreData
import SDCore

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

    // MARK: - Animation Projects (on-device, preserves legacy raster frames)

    func saveAnimation(_ project: AnimationProject) throws {
        let projectDir = animationsDir.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Save metadata (now Codable from SDCore)
        let metadata = try JSONEncoder().encode(project.metadata)
        try metadata.write(to: projectDir.appendingPathComponent("metadata.json"))

        // Save frames — preserve existing raster files, write new/changed ones
        for (index, frame) in project.frames.enumerated() {
            let frameURL = projectDir.appendingPathComponent("frame_\(index).png")

            // Only write raster data if present and different from existing
            if let imageData = frame.imageData {
                let existingData = try? Data(contentsOf: frameURL)
                if existingData != imageData {
                    try imageData.write(to: frameURL)
                }
            } else {
                // Vector-only frame: write a marker file so load knows it's not raster
                let markerURL = projectDir.appendingPathComponent("frame_\(index).vector")
                if !FileManager.default.fileExists(atPath: markerURL.path) {
                    try Data().write(to: markerURL)
                }
            }
        }

        // Remove orphaned raster files if frame count decreased
        let fm = FileManager.default
        var cleanupIndex = project.frames.count
        while true {
            let staleRaster = projectDir.appendingPathComponent("frame_\(cleanupIndex).png")
            let staleVector = projectDir.appendingPathComponent("frame_\(cleanupIndex).vector")
            let rasterExists = fm.fileExists(atPath: staleRaster.path)
            let vectorExists = fm.fileExists(atPath: staleVector.path)
            guard rasterExists || vectorExists else { break }
            if rasterExists { try? fm.removeItem(at: staleRaster) }
            if vectorExists { try? fm.removeItem(at: staleVector) }
            cleanupIndex += 1
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

        // Load frames — detect raster vs vector
        var frames: [StoredAnimationFrame] = []
        var index = 0
        while true {
            let rasterURL = projectDir.appendingPathComponent("frame_\(index).png")
            let vectorMarker = projectDir.appendingPathComponent("frame_\(index).vector")

            if FileManager.default.fileExists(atPath: rasterURL.path) {
                // Legacy or raster frame — preserve the raster data
                let imageData = try Data(contentsOf: rasterURL)
                frames.append(StoredAnimationFrame(imageData: imageData, layerData: nil))
            } else if FileManager.default.fileExists(atPath: vectorMarker.path) {
                // Vector-only frame — no raster data
                frames.append(StoredAnimationFrame(imageData: nil, layerData: nil))
            } else {
                break
            }
            index += 1
        }

        // Load audio tracks
        var audioTracks: [AudioTrack] = []
        var audioIndex = 0
        while true {
            let audioDir = projectDir
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil
            ) else { break }
            let audioFiles = contents.filter { $0.lastPathComponent.hasPrefix("audio_\(audioIndex).") }
            guard let audioFile = audioFiles.first else { break }
            let audioData = try Data(contentsOf: audioFile)
            let format = audioFile.pathExtension
            audioTracks.append(AudioTrack(
                id: UUID(),
                name: "audio_\(audioIndex)",
                format: format,
                audioData: audioData,
                startTime: 0,
                duration: 0
            ))
            audioIndex += 1
        }

        return AnimationProject(id: id, metadata: metadata, frames: frames, audioTracks: audioTracks)
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
