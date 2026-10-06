import Foundation
import AVFoundation
import CoreGraphics

/// Original generated H.264 fixture with nonuniform source timestamps.
enum VideoFrameFixture {
    private struct FixtureFailure: Error { let message: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw FixtureFailure(message: message) }
    }
    static func makeMovie(_ url: URL, rotate: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64])
        input.expectsMediaDataInRealTime = false
        if rotate { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        try check(writer.startWriting(), "fixture writer did not start")
        writer.startSession(atSourceTime: .zero)
        // Nonuniform presentation timestamps exercise source-time lookup rather
        // than guessing a frame number from nominalFrameRate.
        for (index, seconds) in [0.0, 0.4, 1.1].enumerated() {
            var attempts = 0
            while !input.isReadyForMoreMediaData {
                attempts += 1; try check(attempts < 500, "fixture writer readiness deadline")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            var buffer: CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault, 96, 64, kCVPixelFormatType_32ARGB,
                nil, &buffer) == kCVReturnSuccess, "fixture pixel buffer")
            guard let buffer else { throw FixtureFailure(message: "nil fixture buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 { for x in 0..<96 {
                let offset = y * row + x * 4
                bytes[offset] = 255
                bytes[offset + 1] = index == 0 ? 255 : 0
                bytes[offset + 2] = index == 1 ? 255 : 0
                bytes[offset + 3] = index == 2 ? 255 : 0
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try check(adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 30000)), "fixture append")
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 30000))
        input.markAsFinished()
        await writer.finishWriting()
        try check(writer.status == .completed, "fixture movie failed: \(String(describing: writer.error))")
    }

}
