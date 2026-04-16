// VideoImportManager.swift
// Video import — extracts frames from camera roll videos into animation frames
// Uses AVAssetImageGenerator for frame extraction at configurable FPS
// Leverages same AVFoundation patterns as VideoExportManager

import Foundation
import AVFoundation
import UIKit
import Photos

@MainActor
class VideoImportManager: ObservableObject {
    static let shared = VideoImportManager()

    @Published var isImporting = false
    @Published var progress: Double = 0
    @Published var importError: String?
    @Published var previewFrames: [UIImage] = []

    // Maximum frames to prevent memory issues
    static let maxFrames = 300
    // Default thumbnail size for preview
    static let previewSize = CGSize(width: 120, height: 120)

    enum ImportError: LocalizedError {
        case noVideo
        case invalidAsset
        case cannotLoadTrack
        case extractionFailed(String)
        case tooLong(Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideo: return "No video selected"
            case .invalidAsset: return "Could not load video"
            case .cannotLoadTrack: return "Video has no video track"
            case .extractionFailed(let msg): return "Frame extraction failed: \(msg)"
            case .tooLong(let max): return "Video too long (max \(max) frames)"
            case .cancelled: return "Import cancelled"
            }
        }
    }

    /// Import result with extracted frames and metadata
    struct ImportResult {
        let frames: [UIImage]
        let originalFPS: Float
        let duration: Double
        let naturalSize: CGSize
        let frameCount: Int
    }

    /// Import configuration
    struct ImportConfig {
        var targetFPS: Int = 12           // Match project FPS
        var maxDimension: CGFloat = 1080  // Scale down large videos
        var startTime: Double = 0         // Trim start (seconds)
        var endTime: Double? = nil        // Trim end (nil = full video)
        var sampleMode: SampleMode = .matchFPS

        enum SampleMode {
            case matchFPS       // Sample at project FPS
            case everyFrame     // Extract every source frame
            case keyframesOnly  // Only keyframes (fast but sparse)
        }
    }

    // MARK: - Get Video Info (preview before import)

    /// Analyzes a video URL and returns metadata without extracting frames
    func analyzeVideo(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.cannotLoadTrack
        }

        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let totalFrames = Int(CMTimeGetSeconds(duration) * Double(nominalFrameRate))

        return VideoInfo(
            duration: CMTimeGetSeconds(duration),
            fps: nominalFrameRate,
            naturalSize: naturalSize,
            totalFrames: totalFrames,
            url: url
        )
    }

    struct VideoInfo {
        let duration: Double
        let fps: Float
        let naturalSize: CGSize
        let totalFrames: Int
        let url: URL

        var formattedDuration: String {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            return String(format: "%d:%02d", mins, secs)
        }

        var formattedSize: String {
            "\(Int(naturalSize.width))×\(Int(naturalSize.height))"
        }
    }

    // MARK: - Extract Frames

    /// Extract frames from a video URL with the given configuration
    func extractFrames(
        from url: URL,
        config: ImportConfig = ImportConfig()
    ) async throws -> ImportResult {
        guard !isImporting else { throw ImportError.extractionFailed("Import already in progress") }

        isImporting = true
        progress = 0
        importError = nil
        previewFrames = []

        defer {
            isImporting = false
        }

        let asset = AVURLAsset(url: url)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.cannotLoadTrack
        }

        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let durationSeconds = CMTimeGetSeconds(duration)

        // Calculate time range
        let startSec = config.startTime
        let endSec = min(config.endTime ?? durationSeconds, durationSeconds)
        let clipDuration = endSec - startSec

        // Determine how many frames to extract
        let sampleFPS: Double
        switch config.sampleMode {
        case .matchFPS:
            sampleFPS = Double(config.targetFPS)
        case .everyFrame:
            sampleFPS = Double(nominalFrameRate)
        case .keyframesOnly:
            sampleFPS = min(Double(config.targetFPS), 4.0) // ~4 keyframes/sec
        }

        let frameCount = Int(clipDuration * sampleFPS)

        guard frameCount > 0 else {
            throw ImportError.extractionFailed("No frames to extract")
        }

        guard frameCount <= VideoImportManager.maxFrames else {
            throw ImportError.tooLong(VideoImportManager.maxFrames)
        }

        // Set up image generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = config.sampleMode == .keyframesOnly
            ? CMTime(seconds: 0.5, preferredTimescale: 600)
            : CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore

        // Scale down if needed
        let scaledSize = scaledDimensions(naturalSize, maxDimension: config.maxDimension)
        generator.maximumSize = scaledSize

        // Generate time points
        let times: [CMTime] = (0..<frameCount).map { i in
            let seconds = startSec + (Double(i) / sampleFPS)
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }

        // Extract frames
        var extractedFrames: [UIImage] = []
        extractedFrames.reserveCapacity(frameCount)

        for (index, time) in times.enumerated() {
            do {
                let (cgImage, _) = try await generator.image(at: time)
                let uiImage = UIImage(cgImage: cgImage)
                extractedFrames.append(uiImage)

                // Update progress on main thread
                progress = Double(index + 1) / Double(frameCount)

                // Update preview every 10 frames
                if index % 10 == 0 || index == frameCount - 1 {
                    previewFrames = Array(extractedFrames.suffix(6))
                }
            } catch {
                // Skip failed frames but continue extraction
                print("⚠️ VideoImport: Failed to extract frame \(index): \(error.localizedDescription)")
                continue
            }
        }

        guard !extractedFrames.isEmpty else {
            throw ImportError.extractionFailed("No frames could be extracted")
        }

        HapticManager.shared.objectPlaced()

        return ImportResult(
            frames: extractedFrames,
            originalFPS: nominalFrameRate,
            duration: clipDuration,
            naturalSize: naturalSize,
            frameCount: extractedFrames.count
        )
    }

    // MARK: - Helpers

    /// Scale dimensions to fit within maxDimension while preserving aspect ratio
    private func scaledDimensions(_ size: CGSize, maxDimension: CGFloat) -> CGSize {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        return CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
    }

    /// Reset state
    func reset() {
        isImporting = false
        progress = 0
        importError = nil
        previewFrames = []
    }
}
