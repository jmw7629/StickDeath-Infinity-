// VideoExportManager.swift
// Local video export — captures animation frames to MP4 via AVAssetWriter
// Supports watermark overlay, configurable FPS, and audio mixing

import Foundation
import AVFoundation
import UIKit
import Photos

@MainActor
class VideoExportManager: ObservableObject {
    static let shared = VideoExportManager()

    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var exportError: String?

    // MARK: - Export Animation to MP4
    /// Renders animation frames into an MP4 file saved to the camera roll
    /// - Parameters:
    ///   - frames: Array of rendered frame images (UIImage)
    ///   - fps: Frames per second
    ///   - canvasSize: Output video dimensions
    ///   - watermark: Whether to add "StickDeath ∞" watermark
    ///   - audioURL: Optional audio track to mix in
    /// - Returns: URL of the exported MP4 file
    func exportToMP4(
        frames: [UIImage],
        fps: Int = 12,
        canvasSize: CGSize = CGSize(width: 1080, height: 1920),
        watermark: Bool = true,
        audioURL: URL? = nil
    ) async throws -> URL {
        guard !frames.isEmpty else {
            throw ExportError.noFrames
        }

        isExporting = true
        progress = 0
        exportError = nil

        defer { isExporting = false }

        // Temp file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stickdeath_export_\(UUID().uuidString).mp4")

        // Clean up any existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvasSize.width),
            AVVideoHeightKey: Int(canvasSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,  // 6 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let sourcePixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(canvasSize.width),
            kCVPixelBufferHeightKey as String: Int(canvasSize.height),
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelAttrs
        )

        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        // Write frames
        for (index, frame) in frames.enumerated() {
            // Wait for writer to be ready
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            var processedFrame = frame

            // Apply watermark if needed
            if watermark {
                processedFrame = applyWatermark(to: frame, canvasSize: canvasSize) ?? frame
            }

            // Convert UIImage to pixel buffer
            guard let pixelBuffer = pixelBuffer(from: processedFrame, size: canvasSize) else {
                throw ExportError.pixelBufferFailed
            }

            let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)

            progress = Double(index + 1) / Double(frames.count)
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
            exportError = errorMsg
            throw ExportError.writerFailed(errorMsg)
        }

        // Mix audio if provided
        if let audioURL {
            let mixedURL = try await mixAudio(videoURL: outputURL, audioURL: audioURL)
            return mixedURL
        }

        return outputURL
    }

    // MARK: - Save to Camera Roll
    func saveToCameraRoll(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }

    // MARK: - Full Export Pipeline (render frames + save)
    func exportAndSave(
        frames: [UIImage],
        fps: Int = 12,
        canvasSize: CGSize = CGSize(width: 1080, height: 1920),
        watermark: Bool = true,
        audioURL: URL? = nil
    ) async throws {
        let url = try await exportToMP4(
            frames: frames, fps: fps, canvasSize: canvasSize,
            watermark: watermark, audioURL: audioURL
        )
        try await saveToCameraRoll(url: url)
        // Clean up temp file
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Watermark
    private func applyWatermark(to image: UIImage, canvasSize: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))

            // Watermark text
            let text = "STICKDEATH ∞"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "SpecialElite-Regular", size: 16) ?? UIFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.4),
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textPoint = CGPoint(
                x: canvasSize.width - textSize.width - 16,
                y: canvasSize.height - textSize.height - 16
            )
            (text as NSString).draw(at: textPoint, withAttributes: attrs)
        }
    }

    // MARK: - Pixel Buffer from UIImage
    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        // Flip coordinate system (UIImage is upside-down in CGContext)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()

        return buffer
    }

    // MARK: - Audio Mixing
    private func mixAudio(videoURL: URL, audioURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let composition = AVMutableComposition()

        // Video track
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.mixFailed
        }

        let videoDuration = try await videoAsset.load(.duration)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack, at: .zero
        )

        // Audio track
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            let insertDuration = min(videoDuration, audioDuration)
            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: audioTrack, at: .zero
            )
        }

        // Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stickdeath_mixed_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.mixFailed
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        await exportSession.export()

        guard exportSession.status == .completed else {
            throw ExportError.mixFailed
        }

        // Clean up original video
        try? FileManager.default.removeItem(at: videoURL)

        return outputURL
    }

    // MARK: - Render a single frame to UIImage
    /// Use this to capture each animation frame for export
    static func renderFrame(
        figures: [StickFigure],
        frameStates: [FigureState],
        drawnElements: [DrawnElement],
        canvasSize: CGSize,
        backgroundColor: UIColor = .white
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            let context = ctx.cgContext

            // Background
            context.setFillColor(backgroundColor.cgColor)
            context.fill(CGRect(origin: .zero, size: canvasSize))

            let centerX = canvasSize.width / 2
            let centerY = canvasSize.height / 2

            // Draw stick figures
            for state in frameStates where state.visible {
                guard let figure = figures.first(where: { $0.id == state.figureId }) else { continue }
                let joints = state.joints

                // Figure color
                let color = UIColor(
                    red: CGFloat(figure.color.red),
                    green: CGFloat(figure.color.green),
                    blue: CGFloat(figure.color.blue),
                    alpha: CGFloat(figure.color.opacity)
                )

                context.setStrokeColor(color.cgColor)
                context.setLineWidth(figure.lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)

                // Draw limbs
                let limbs: [(String, String)] = [
                    ("head", "neck"), ("neck", "torso"),
                    ("neck", "leftShoulder"), ("leftShoulder", "leftElbow"), ("leftElbow", "leftHand"),
                    ("neck", "rightShoulder"), ("rightShoulder", "rightElbow"), ("rightElbow", "rightHand"),
                    ("torso", "leftHip"), ("leftHip", "leftKnee"), ("leftKnee", "leftFoot"),
                    ("torso", "rightHip"), ("rightHip", "rightKnee"), ("rightKnee", "rightFoot"),
                ]

                for (from, to) in limbs {
                    guard let p1 = joints[from], let p2 = joints[to] else { continue }
                    context.move(to: CGPoint(x: centerX + p1.x, y: centerY + p1.y))
                    context.addLine(to: CGPoint(x: centerX + p2.x, y: centerY + p2.y))
                }
                context.strokePath()

                // Draw head circle
                if let headPos = joints["head"] {
                    let headRect = CGRect(
                        x: centerX + headPos.x - figure.headRadius,
                        y: centerY + headPos.y - figure.headRadius,
                        width: figure.headRadius * 2,
                        height: figure.headRadius * 2
                    )
                    context.strokeEllipse(in: headRect)
                }
            }

            // Draw drawn elements
            for element in drawnElements {
                let strokeColor = UIColor(hex: element.strokeColor) ?? .black

                switch element.tool {
                case "pencil", "pen":
                    guard element.points.count >= 2 else { continue }
                    context.setStrokeColor(strokeColor.cgColor)
                    context.setLineWidth(element.strokeWidth)
                    context.setLineCap(.round)

                    let first = element.points[0]
                    context.move(to: CGPoint(x: centerX + first.x, y: centerY + first.y))
                    for pt in element.points.dropFirst() {
                        context.addLine(to: CGPoint(x: centerX + pt.x, y: centerY + pt.y))
                    }
                    context.strokePath()

                case "line":
                    guard let first = element.points.first, let last = element.points.last else { continue }
                    context.setStrokeColor(strokeColor.cgColor)
                    context.setLineWidth(element.strokeWidth)
                    context.move(to: CGPoint(x: centerX + first.x, y: centerY + first.y))
                    context.addLine(to: CGPoint(x: centerX + last.x, y: centerY + last.y))
                    context.strokePath()

                case "rectangle":
                    if let origin = element.origin, let size = element.size {
                        let rect = CGRect(
                            x: centerX + origin.x, y: centerY + origin.y,
                            width: size.width, height: size.height
                        )
                        if let fillHex = element.fillColor, let fc = UIColor(hex: fillHex) {
                            context.setFillColor(fc.cgColor)
                            context.fill(rect)
                        }
                        context.setStrokeColor(strokeColor.cgColor)
                        context.setLineWidth(element.strokeWidth)
                        context.stroke(rect)
                    }

                case "circle":
                    if let origin = element.origin, let size = element.size {
                        let rect = CGRect(
                            x: centerX + origin.x, y: centerY + origin.y,
                            width: size.width, height: size.height
                        )
                        if let fillHex = element.fillColor, let fc = UIColor(hex: fillHex) {
                            context.setFillColor(fc.cgColor)
                            context.fillEllipse(in: rect)
                        }
                        context.setStrokeColor(strokeColor.cgColor)
                        context.setLineWidth(element.strokeWidth)
                        context.strokeEllipse(in: rect)
                    }

                case "text":
                    if let text = element.text, let origin = element.origin {
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: element.fontSize ?? 14),
                            .foregroundColor: strokeColor,
                        ]
                        (text as NSString).draw(
                            at: CGPoint(x: centerX + origin.x, y: centerY + origin.y),
                            withAttributes: attrs
                        )
                    }

                default: break
                }
            }
        }
    }
}

// MARK: - UIColor hex helper (for frame rendering)
extension UIColor {
    convenience init?(hex: String) {
        let clean = hex.replacingOccurrences(of: "#", with: "")
        guard clean.count == 6 || clean.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        if clean.count == 6 {
            self.init(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1.0
            )
        } else {
            self.init(
                red: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
        }
    }
}

// MARK: - Export Errors
enum ExportError: LocalizedError {
    case noFrames
    case pixelBufferFailed
    case writerFailed(String)
    case mixFailed

    var errorDescription: String? {
        switch self {
        case .noFrames: return "No frames to export"
        case .pixelBufferFailed: return "Failed to create pixel buffer"
        case .writerFailed(let msg): return "Video writer failed: \(msg)"
        case .mixFailed: return "Audio mixing failed"
        }
    }
}
