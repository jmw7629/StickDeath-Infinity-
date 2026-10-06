import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// Imports one decoded reference frame, not a movie track. The original movie
/// remains with its owner. Only the returned oriented SDR PNG enters the editor's
/// existing managed-image transaction, history, save and export paths.
actor StudioVideoFrameImportService {
    static let shared = StudioVideoFrameImportService()
    static let maximumPixels = 4_194_304
    static let maximumDimension = 4096
    private var busy = false

    /// Immutable mapping captured before the system picker opens. The trim end
    /// is exclusive, just like AVFoundation time ranges.
    struct Mapping: Equatable, Sendable {
        var sourceStartSeconds: Double = 0
        var sourceEndSeconds: Double? = nil
        var projectStartSeconds: Double = 0
        var speed: Double = 1

        func sourceTime(projectSeconds: Double) throws -> Double {
            guard sourceStartSeconds.isFinite, (0..<3600).contains(sourceStartSeconds),
                  projectStartSeconds.isFinite, (0...3600).contains(projectStartSeconds),
                  speed.isFinite, (0.25...4).contains(speed), projectSeconds.isFinite,
                  projectSeconds >= projectStartSeconds else { throw Failure.invalidMapping }
            if let end = sourceEndSeconds {
                guard end.isFinite, end > sourceStartSeconds, end <= 3600 else { throw Failure.invalidMapping }
            }
            let result = sourceStartSeconds + (projectSeconds - projectStartSeconds) * speed
            guard result.isFinite, result < (sourceEndSeconds ?? 3600) else { throw Failure.outsideTrim }
            return result
        }
    }

    struct Frame: Sendable {
        let image: StudioImageImportService.ImportedImage
        let requestedSeconds: Double
        let sourceRequestedSeconds: Double
        let mapping: Mapping
        let actualSeconds: Double
        let durationSeconds: Double
    }
    enum Failure: LocalizedError {
        case busy, invalidTime, invalidMapping, outsideTrim, unsupportedVideo, geometry, outsideVideo, encoding, timedOut
        var errorDescription: String? {
            switch self {
            case .busy: return "Another video frame is being prepared. Wait or cancel it first."
            case .invalidTime: return "The selected Studio frame has an invalid time. No reference was added."
            case .invalidMapping: return "Use a valid source trim, a Studio start no later than the playhead, and speed between 0.25× and 4×."
            case .outsideTrim: return "The Studio playhead maps past the selected source trim. Adjust timing or select an earlier Studio frame."
            case .unsupportedVideo: return "Choose a self-contained MP4 or MOV with one readable video track, up to 16 MB and one hour."
            case .geometry: return "This video exceeds the frame import limit: 4 megapixels and 4096 pixels on either edge."
            case .outsideVideo: return "The Studio playhead is outside this video. Select an earlier Studio frame and choose the video again."
            case .encoding: return "The video frame could not be converted to a supported PNG. No reference was added."
            case .timedOut: return "The video frame took too long to decode. No reference was added."
            }
        }
    }

    func extract(from url: URL, projectFrameIndex: Int, fps: Int,
                 mapping: Mapping = Mapping(),
                 scratchParent: URL = FileManager.default.temporaryDirectory) async throws -> Frame {
        try Task.checkCancellation()
        guard !busy else { throw Failure.busy }
        guard projectFrameIndex >= 0, projectFrameIndex <= 216_000, (1...120).contains(fps) else { throw Failure.invalidTime }
        let projectSeconds = Double(projectFrameIndex) / Double(fps)
        let sourceSeconds = try mapping.sourceTime(projectSeconds: projectSeconds)
        guard ["mp4", "mov"].contains(url.pathExtension.lowercased()) else { throw Failure.unsupportedVideo }
        busy = true
        defer { busy = false }
        // Reuse the tested, security-scoped regular-file copy. Its 16 MB limit,
        // no-follow descriptors, source identity checks and owned-only cleanup
        // also apply to video. No source path is passed to AVFoundation.
        let owned = try StudioImageProviderFile.materialize(from: url, scratchParent: scratchParent)
        do {
            let copiedURL = try owned.url()
            let frame = try await withThrowingTaskGroup(of: Frame.self) { group in
                group.addTask { try await Self.decode(copiedURL, name: owned.displayName,
                    time: CMTime(seconds: sourceSeconds, preferredTimescale: 600_000),
                    projectSeconds: projectSeconds, mapping: mapping) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw Failure.encoding }
                return result
            }
            try Task.checkCancellation()
            _ = try owned.url()
            try owned.cleanup()
            return frame
        } catch {
            let operation = error
            do { try owned.cleanup() }
            catch { throw StudioImageProviderFile.Failure.operationAndCleanupFailed(operation: operation) }
            throw operation
        }
    }

    private static func decode(_ url: URL, name: String, time: CMTime,
                               projectSeconds: Double, mapping: Mapping) async throws -> Frame {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard try await asset.load(.isReadable), !(try await asset.load(.hasProtectedContent)) else { throw Failure.unsupportedVideo }
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0, duration.seconds <= 3600 else { throw Failure.unsupportedVideo }
            guard time < duration else { throw Failure.outsideVideo }
            if let end = mapping.sourceEndSeconds, end > duration.seconds { throw Failure.outsideVideo }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard tracks.count == 1, let track = tracks.first else { throw Failure.unsupportedVideo }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= CGFloat(maximumDimension), size.height <= CGFloat(maximumDimension),
                  size.width * size.height <= CGFloat(maximumPixels),
                  oriented.width.isFinite, oriented.height.isFinite,
                  oriented.width > 0, oriented.height > 0,
                  oriented.width <= CGFloat(maximumDimension), oriented.height <= CGFloat(maximumDimension) else { throw Failure.geometry }
            try Task.checkCancellation()
            let result = try await generator.image(at: time)
            try Task.checkCancellation()
            let image = result.image
            guard image.width > 0, image.height > 0, image.width <= maximumDimension,
                  image.height <= maximumDimension, image.width * image.height <= maximumPixels else { throw Failure.geometry }
            let png = try encode(image)
            let title = String(name.prefix(85)) + String(format: " @ %.3fs", time.seconds)
            let imported = StudioImageImportService.ImportedImage(id: UUID(), name: title, container: .png,
                originalData: png, originalWidth: image.width, originalHeight: image.height, originalOrientation: 1,
                width: image.width, height: image.height, normalizedPNG: png)
            return Frame(image: imported, requestedSeconds: projectSeconds,
                sourceRequestedSeconds: time.seconds, mapping: mapping, actualSeconds: result.actualTime.seconds, durationSeconds: duration.seconds)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            asset.cancelLoading()
        }
    }

    private static func encode(_ image: CGImage) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.encoding }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else { throw Failure.encoding }
        let buffer = PNGBuffer()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            let buffer = Unmanaged<PNGBuffer>.fromOpaque(info).takeUnretainedValue()
            guard !Task.isCancelled, count <= StudioImageImportService.maximumEncodedBytes - buffer.data.count else {
                buffer.failed = true; return 0
            }
            buffer.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(buffer).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, "public.png" as CFString, 1, nil) else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, normalized, [kCGImagePropertyOrientation: 1] as CFDictionary)
        let complete = CGImageDestinationFinalize(destination)
        try Task.checkCancellation()
        guard complete, !buffer.failed else { throw Failure.encoding }
        return buffer.data
    }
    private final class PNGBuffer { var data = Data(); var failed = false }
}
