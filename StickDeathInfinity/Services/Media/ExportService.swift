// ═══════════════════════════════════════════════════════════════════
// ExportService — Real MP4/GIF/PNG export using native frameworks
// Uses AVAssetWriter, ImageIO, Core Graphics for frame-at-time rendering
// ═══════════════════════════════════════════════════════════════════

import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ExportService: ObservableObject {
    static let shared = ExportService()
    
    @Published var progress: ExportProgress = .idle
    @Published var isCancelled = false
    
    private var exportTask: Task<Void, Never>?
    
    // MARK: - Export MP4
    func exportMP4(
        frames: [AnimationFrame],
        canvasWidth: Int,
        canvasHeight: Int,
        fps: Int,
        quality: ExportQuality,
        layers: [CanvasLayer],
        audioClips: [AudioClip],
        rotoscopeReference: RotoscopeReference?,
        rotoscopeVideoAsset: MediaAsset?
    ) async throws -> ExportResult {
        isCancelled = false
        progress = .preparing
        
        let outputURL = getExportURL(format: .mp4, quality: quality)
        try? FileManager.default.removeItem(at: outputURL)
        
        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        // Configure video settings based on quality
        let outputSize = getSizeForQuality(quality, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputSize.width,
            AVVideoHeightKey: outputSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality == .fullHD ? 10_000_000 : 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputSize.width,
            kCVPixelBufferHeightKey as String: outputSize.height
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        writer.add(videoInput)
        
        // Start writing
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Render frames one at a time (bounded memory)
        let frameDuration = CMTime(value: CMTimeValue(1), timescale: CMTimeScale(fps))
        var currentTime = CMTime.zero
        
        for (index, frame) in frames.enumerated() {
            if isCancelled {
                writer.cancelWriting()
                throw ExportError.cancelled
            }
            
            // Render frame to image
            let frameImage = renderFrame(
                frame: frame,
                width: outputSize.width,
                height: outputSize.height,
                layers: layers,
                rotoscopeReference: rotoscopeReference,
                rotoscopeVideoAsset: rotoscopeVideoAsset
            )
            
            // Wait for video input to be ready
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            
            // Get pixel buffer
            guard let pixelBuffer = createPixelBuffer(
                from: frameImage,
                width: outputSize.width,
                height: outputSize.height,
                adaptor: adaptor
            ) else {
                throw ExportError.renderFailed
            }
            
            // Append frame
            if !adaptor.append(pixelBuffer, withPresentationTime: currentTime) {
                throw ExportError.writeFailed
            }
            
            currentTime = CMTimeAdd(currentTime, frameDuration)
            
            // Update progress
            let progressValue = Double(index + 1) / Double(frames.count)
            progress = .exporting(progress: progressValue)
        }
        
        // Finish writing
        videoInput.markAsFinished()
        await writer.finishWriting()
        
        guard writer.status == .completed else {
            throw ExportError.writeFailed
        }
        
        // Mix audio if available
        if !audioClips.isEmpty {
            let mixedURL = await mixAudio(
                videoURL: outputURL,
                audioClips: audioClips,
                fps: fps,
                totalFrames: frames.count
            )
            if let mixedURL = mixedURL {
                try FileManager.default.removeItem(at: outputURL)
                try FileManager.default.moveItem(at: mixedURL, to: outputURL)
            }
        }
        
        // Get file size
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (fileAttributes?[.size] as? Int64) ?? 0
        
        let result = ExportResult(
            url: outputURL,
            format: .mp4,
            fileSize: fileSize,
            duration: Double(frames.count) / Double(fps),
            width: outputSize.width,
            height: outputSize.height
        )
        
        progress = .complete(result: result)
        return result
    }
    
    // MARK: - Export GIF
    func exportGIF(
        frames: [AnimationFrame],
        canvasWidth: Int,
        canvasHeight: Int,
        fps: Int,
        quality: ExportQuality,
        layers: [CanvasLayer],
        rotoscopeReference: RotoscopeReference?,
        rotoscopeVideoAsset: MediaAsset?
    ) async throws -> ExportResult {
        isCancelled = false
        progress = .preparing
        
        let outputURL = getExportURL(format: .gif, quality: quality)
        try? FileManager.default.removeItem(at: outputURL)
        
        let outputSize = getSizeForQuality(quality, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let frameDuration = 1.0 / Double(fps)
        
        // Create GIF destination
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw ExportError.destinationFailed
        }
        
        // GIF properties
        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0 // Loop forever
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        
        // Render and add frames
        for (index, frame) in frames.enumerated() {
            if isCancelled {
                throw ExportError.cancelled
            }
            
            let frameImage = renderFrame(
                frame: frame,
                width: outputSize.width,
                height: outputSize.height,
                layers: layers,
                rotoscopeReference: rotoscopeReference,
                rotoscopeVideoAsset: rotoscopeVideoAsset
            )
            
            guard let cgImage = frameImage.cgImage else {
                throw ExportError.renderFailed
            }
            
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: frameDuration,
                    kCGImagePropertyGIFDelayTime: frameDuration
                ]
            ]
            
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            
            // Update progress
            let progressValue = Double(index + 1) / Double(frames.count)
            progress = .exporting(progress: progressValue)
        }
        
        // Finalize GIF
        if !CGImageDestinationFinalize(destination) {
            throw ExportError.writeFailed
        }
        
        // Get file size
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (fileAttributes?[.size] as? Int64) ?? 0
        
        let result = ExportResult(
            url: outputURL,
            format: .gif,
            fileSize: fileSize,
            duration: Double(frames.count) * frameDuration,
            width: outputSize.width,
            height: outputSize.height
        )
        
        progress = .complete(result: result)
        return result
    }
    
    // MARK: - Export PNG Sequence
    func exportPNGSequence(
        frames: [AnimationFrame],
        canvasWidth: Int,
        canvasHeight: Int,
        quality: ExportQuality,
        layers: [CanvasLayer],
        rotoscopeReference: RotoscopeReference?,
        rotoscopeVideoAsset: MediaAsset?
    ) async throws -> ExportResult {
        isCancelled = false
        progress = .preparing
        
        let outputDir = getExportDirectory(format: .png, quality: quality)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        let outputSize = getSizeForQuality(quality, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        
        // Render and save frames
        for (index, frame) in frames.enumerated() {
            if isCancelled {
                throw ExportError.cancelled
            }
            
            let frameImage = renderFrame(
                frame: frame,
                width: outputSize.width,
                height: outputSize.height,
                layers: layers,
                rotoscopeReference: rotoscopeReference,
                rotoscopeVideoAsset: rotoscopeVideoAsset
            )
            
            let filename = String(format: "frame_%04d.png", index + 1)
            let fileURL = outputDir.appendingPathComponent(filename)
            
            guard let imageData = frameImage.pngData() else {
                throw ExportError.renderFailed
            }
            
            try imageData.write(to: fileURL)
            
            // Update progress
            let progressValue = Double(index + 1) / Double(frames.count)
            progress = .exporting(progress: progressValue)
        }
        
        // Get total size
        var totalSize: Int64 = 0
        let files = try FileManager.default.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        for file in files {
            let resourceValues = try file.resourceValues(forKeys: [.fileSizeKey])
            totalSize += Int64(resourceValues.fileSize ?? 0)
        }
        
        let result = ExportResult(
            url: outputDir,
            format: .png,
            fileSize: totalSize,
            width: outputSize.width,
            height: outputSize.height
        )
        
        progress = .complete(result: result)
        return result
    }
    
    // MARK: - Cancel Export
    func cancelExport() {
        isCancelled = true
        exportTask?.cancel()
        progress = .cancelled
    }
    
    // MARK: - Private Helpers
    private func renderFrame(
        frame: AnimationFrame,
        width: Int,
        height: Int,
        layers: [CanvasLayer],
        rotoscopeReference: RotoscopeReference?,
        rotoscopeVideoAsset: MediaAsset?
    ) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Fill background white
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Draw rotoscope reference (behind drawing)
            if let reference = rotoscopeReference,
               !reference.isAboveDrawing,
               let videoAsset = rotoscopeVideoAsset,
               let imageData = try? Data(contentsOf: videoAsset.localURL),
               let image = UIImage(data: imageData) {
                let rect = CGRect(origin: .zero, size: size)
                image.draw(in: rect)
            }
            
            // Draw layers (respecting visibility and opacity)
            for layer in layers where layer.visible {
                let layerOpacity = CGFloat(layer.opacity)
                
                // Draw elements for this layer
                for element in frame.elements where element.layerID == layer.id {
                    drawElement(
                        element: element,
                        in: context,
                        width: width,
                        height: height,
                        opacity: layerOpacity
                    )
                }
            }
            
            // Draw rotoscope reference (above drawing)
            if let reference = rotoscopeReference,
               reference.isAboveDrawing,
               let videoAsset = rotoscopeVideoAsset,
               let imageData = try? Data(contentsOf: videoAsset.localURL),
               let image = UIImage(data: imageData) {
                let rect = CGRect(origin: .zero, size: size)
                UIColor.white.withAlphaComponent(CGFloat(1.0 - reference.opacity)).setFill()
                context.fill(rect)
                image.draw(in: rect)
            }
        }
    }
    
    private func drawElement(
        element: DrawnElement,
        in context: UIGraphicsImageRendererContext,
        width: Int,
        height: Int,
        opacity: CGFloat
    ) {
        guard element.points.count >= 2 else { return }
        
        let scaleX = CGFloat(width) / CGFloat(1080)
        let scaleY = CGFloat(height) / CGFloat(1080)
        let color = UIColor(Color(hex: element.color))
        
        context.cgContext.setStrokeColor(color.withAlphaComponent(opacity * CGFloat(element.opacity)).cgColor)
        context.cgContext.setLineWidth(element.width * scaleX)
        context.cgContext.setLineCap(.round)
        context.cgContext.setLineJoin(.round)
        
        let path = UIBezierPath()
        let first = element.points[0]
        path.move(to: CGPoint(x: first.x * scaleX, y: first.y * scaleY))
        
        for point in element.points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scaleX, y: point.y * scaleY))
        }
        
        path.stroke()
    }
    
    private func mixAudio(
        videoURL: URL,
        audioClips: [AudioClip],
        fps: Int,
        totalFrames: Int
    ) async -> URL? {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        
        // Add video track
        guard let videoTrack = try? await videoAsset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        
        let videoDuration = try! await videoAsset.load(.duration)
        try? compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        
        // Add audio tracks for each clip
        for clip in audioClips {
            let audioAsset = AVURLAsset(url: getAudioURL(for: clip))
            guard let sourceAudioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
                  let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            
            let startTime = CMTime(seconds: clip.startTime, preferredTimescale: 600)
            let clipDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
            
            try? compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: clipDuration),
                of: sourceAudioTrack,
                at: startTime
            )
        }
        
        // Export mixed audio
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            return nil
        }
        
        return outputURL
    }
    
    private func getAudioURL(for clip: AudioClip) -> URL {
        // In a real implementation, this would look up the actual audio file URL
        // For now, return a placeholder
        return Bundle.main.url(forResource: clip.soundName, withExtension: "mp3") ?? URL(fileURLWithPath: "/dev/null")
    }
    
    private func createPixelBuffer(
        from image: UIImage,
        width: Int,
        height: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            nil,
            adaptor.pixelBufferPool,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let baseAddress = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    
    private func getExportURL(format: ExportFormat, quality: ExportQuality) -> URL {
        let filename = "\(UUID().uuidString).\(format.rawValue.lowercased())"
        let directory = getExportDirectory(format: format, quality: quality)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename)
    }
    
    private func getExportDirectory(format: ExportFormat, quality: ExportQuality) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Exports/\(format.rawValue)/\(quality.rawValue)", isDirectory: true)
    }
    
    private func getSizeForQuality(_ quality: ExportQuality, canvasWidth: Int, canvasHeight: Int) -> CGSize {
        let aspectRatio = CGFloat(canvasWidth) / CGFloat(canvasHeight)
        
        switch quality {
        case .standard:
            return CGSize(width: 480, height: Int(480 / aspectRatio))
        case .hd:
            return CGSize(width: 720, height: Int(720 / aspectRatio))
        case .fullHD:
            return CGSize(width: 1080, height: Int(1080 / aspectRatio))
        }
    }
}

// MARK: - Export Errors
enum ExportError: LocalizedError {
    case cancelled
    case renderFailed
    case writeFailed
    case destinationFailed
    case audioMixFailed
    
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Export was cancelled"
        case .renderFailed: return "Failed to render frame"
        case .writeFailed: return "Failed to write export file"
        case .destinationFailed: return "Failed to create export destination"
        case .audioMixFailed: return "Failed to mix audio"
        }
    }
}