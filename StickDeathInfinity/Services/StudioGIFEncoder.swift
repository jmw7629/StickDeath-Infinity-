import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Encodes the canonical Studio compositor. Returning these verified bytes is
/// not a file-save/share receipt; the caller must own that separate operation.
@MainActor
final class StudioGIFEncoder {
    struct Snapshot {
        let document: StudioDocument
        let rasterDataByID: [String: Data]
    }
    struct Receipt: Codable {
        var version = 1
        let projectID: UUID
        let revision: Int
        let frameIDs: [String]
        let width: Int
        let height: Int
        let sourceFPS: Int
        let delaysCentiseconds: [Int]
        let encodedBytes: Int
        let background: String
        let audioIncluded: Bool
        let editorGuidesIncluded: Bool
    }
    struct Encoded {
        let data: Data
        let receipt: Receipt
    }
    enum Phase { case rendering, finalizing, verifying }
    struct Progress { let phase: Phase; let completed: Int; let total: Int }
    enum Failure: LocalizedError {
        case limit, frameRate, missingRaster, encoding, verification, alreadyEncoding
        var errorDescription: String? {
            switch self {
            case .limit: return "GIF exceeds the safe frame, pixel, source or output size limit. Use a smaller canvas or MP4."
            case .frameRate: return "GIF supports 1–50 FPS here. Use MP4 to retain a higher frame rate."
            case .missingRaster: return "An original project image is missing. No GIF was returned."
            case .encoding: return "The animated GIF could not be encoded. No GIF was returned."
            case .verification: return "The encoded GIF did not retain the expected frames or timing. No GIF was returned."
            case .alreadyEncoding: return "A GIF is already being encoded. Wait for it or cancel it."
            }
        }
    }
    // Image I/O may retain frame bitmaps until finalization. Bound their total
    // potential RGBA storage to 32 MiB. Returned output is capped at 32 MiB;
    // Image I/O can use additional temporary memory during finalization.
    static let maximumPixels = 8_388_608
    static let maximumBytes = 32 * 1024 * 1024
    private static var inProgress = false

    static func timing(frameCount: Int, fps: Int) throws -> [Int] {
        guard (1...240).contains(frameCount) else { throw Failure.limit }
        guard (1...50).contains(fps) else { throw Failure.frameRate }
        // Each cumulative boundary is within half a centisecond of the source;
        // repeating one rounded delay would drift at rates such as 12/24 FPS.
        return (0..<frameCount).map { index in
            ((index + 1) * 100 + fps / 2) / fps - (index * 100 + fps / 2) / fps
        }
    }

    func encode(_ snapshot: Snapshot, progress: (Progress) throws -> Void = { _ in }) async throws -> Encoded {
        try Task.checkCancellation()
        guard !Self.inProgress else { throw Failure.alreadyEncoding }
        Self.inProgress = true
        defer { Self.inProgress = false }
        let document = snapshot.document
        let renderer = StudioExportService()
        try renderer.validate(document)
        let delays = try Self.timing(frameCount: document.frames.count, fps: document.fps)
        guard document.width * document.height * document.frames.count <= Self.maximumPixels,
              snapshot.rasterDataByID.count <= 240 else { throw Failure.limit }
        var sourceBytes = 0
        for bytes in snapshot.rasterDataByID.values {
            guard bytes.count <= Self.maximumBytes - sourceBytes else { throw Failure.limit }
            sourceBytes += bytes.count
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString,
                                                                 document.frames.count, nil) else { throw Failure.encoding }
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, frame) in document.frames.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let visible = document.layers.contains { $0.id == frame.rasterLayerID && $0.visible && $0.opacity > 0 }
                let raster: Data?
                if visible, let id = frame.rasterAssetID {
                    guard let bytes = snapshot.rasterDataByID[id] else { throw Failure.missingRaster }
                    raster = bytes
                } else { raster = nil }
                let image = try renderer.render(frame, document: document, background: .white, raster: raster)
                let delay = Double(delays[index]) / 100
                CGImageDestinationAddImage(destination, image,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                    kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            }
            guard data.length <= Self.maximumBytes else { throw Failure.limit }
            try progress(.init(phase: .rendering, completed: index + 1, total: document.frames.count))
            await Task.yield()
        }
        try Task.checkCancellation()
        try progress(.init(phase: .finalizing, completed: document.frames.count, total: document.frames.count))
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        try Task.checkCancellation()
        guard data.length > 0, data.length <= Self.maximumBytes else { throw Failure.limit }
        let encoded = data as Data
        guard let source = CGImageSourceCreateWithData(encoded as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(source) as String? == UTType.gif.identifier,
            CGImageSourceGetCount(source) == document.frames.count,
            CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            (gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue == 0 else { throw Failure.verification }
        for index in document.frames.indices {
            try Task.checkCancellation()
            try autoreleasepool {
                guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                      let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let gif = frame[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                      let delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber,
                      abs(delay.doubleValue - Double(delays[index]) / 100) < 0.0001,
                      let image = CGImageSourceCreateImageAtIndex(source, index,
                          [kCGImageSourceShouldCache: false] as CFDictionary),
                      image.width == document.width, image.height == document.height else { throw Failure.verification }
            }
            try progress(.init(phase: .verifying, completed: index + 1, total: document.frames.count))
            await Task.yield()
        }
        try Task.checkCancellation()
        return Encoded(data: encoded, receipt: Receipt(projectID: document.id, revision: document.revision,
            frameIDs: document.frames.map(\.id), width: document.width, height: document.height,
            sourceFPS: document.fps, delaysCentiseconds: delays, encodedBytes: encoded.count,
            background: "white", audioIncluded: false, editorGuidesIncluded: false))
    }
}
