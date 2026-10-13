import Foundation
import CoreGraphics
import ImageIO

/// Deterministic four-connected edge-color removal, not semantic AI segmentation.
/// Work is bounded and cancellable; originals and the document are never mutated here.
enum StudioBackgroundCut {
    struct Result: Sendable {
        let png: Data
        let removedPixels: Int
    }
    enum Failure: LocalizedError {
        case invalid, limit, encoding, busy
        var errorDescription: String? {
            switch self {
            case .invalid: return "Background Cut requires a valid normalized PNG and a tolerance from 0–100."
            case .limit: return "Background Cut supports images up to 4 megapixels and 16 MB each."
            case .encoding: return "The cut image could not be encoded. The project has not changed."
            case .busy: return "The previous Background Cut is still finishing. Try Preview Cut again in a moment."
            }
        }
    }
    /// One process-wide batch owns decode memory, including after its sheet has
    /// been dismissed. Cancellation revokes output immediately but cannot stop
    /// ImageIO in the middle of a synchronous decode or PNG encoding call.
    static func removeBatch(from inputs: [String: Data], red: UInt8, green: UInt8, blue: UInt8,
                            tolerance: Int,
                            checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) async throws -> [String: Result] {
        try checkCancellation()
        guard (0...100).contains(tolerance), !inputs.isEmpty else { throw Failure.invalid }
        guard inputs.count <= 16 else { throw Failure.limit }
        var pixels = 0, encoded = 0
        for data in inputs.values {
            try checkCancellation()
            guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw Failure.limit }
            encoded += data.count
            guard encoded <= 64 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? Int,
                  let height = info[kCGImagePropertyPixelHeight] as? Int,
                  (1...8192).contains(width), (1...8192).contains(height), width <= 4_194_304 / height else {
                throw Failure.limit
            }
            pixels += width * height
            guard pixels <= 16_777_216 else { throw Failure.limit }
        }
        try await StudioBackgroundCutLease.shared.acquire()
        do {
            try checkCancellation()
            var results: [String: Result] = [:]
            for id in inputs.keys.sorted() {
                try checkCancellation()
                results[id] = try remove(from: inputs[id]!, red: red, green: green, blue: blue,
                                         tolerance: tolerance, checkCancellation: checkCancellation)
            }
            try checkCancellation()
            await StudioBackgroundCutLease.shared.release()
            return results
        } catch {
            await StudioBackgroundCutLease.shared.release()
            throw error
        }
    }

    static func remove(from data: Data, red: UInt8, green: UInt8, blue: UInt8, tolerance: Int,
                       checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Result {
        try checkCancellation()
        guard (0...100).contains(tolerance) else { throw Failure.invalid }
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw Failure.limit }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == "public.png",
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 4_194_304,
              (info[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.invalid }
        let count = width * height
        var pixels = [UInt8](repeating: 0, count: count * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        try pixels.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: bitmap) else { throw Failure.limit }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        try checkCancellation()
        var visited = [UInt8](repeating: 0, count: count)
        var queue = [Int32](); queue.reserveCapacity(count)
        let threshold = tolerance * 255 / 100
        let color = [Int(red), Int(green), Int(blue)]
        func enqueue(_ index: Int) {
            guard visited[index] == 0 else { return }
            visited[index] = 1
            let base = index * 4, alpha = Int(pixels[base + 3])
            if alpha == 0 { queue.append(Int32(index)); return }
            for channel in 0..<3 {
                let straight = min(255, (Int(pixels[base + channel]) * 255 + alpha / 2) / alpha)
                if abs(straight - color[channel]) > threshold { return }
            }
            queue.append(Int32(index))
        }
        for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
        for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
        var cursor = 0, removed = 0
        while cursor < queue.count {
            if cursor % 4096 == 0 { try checkCancellation() }
            let index = Int(queue[cursor]); cursor += 1
            let x = index % width, y = index / width, base = index * 4
            if pixels[base + 3] > 0 { removed += 1 }
            pixels[base] = 0; pixels[base + 1] = 0; pixels[base + 2] = 0; pixels[base + 3] = 0
            if x > 0 { enqueue(index - 1) }; if x + 1 < width { enqueue(index + 1) }
            if y > 0 { enqueue(index - width) }; if y + 1 < height { enqueue(index + width) }
        }
        try checkCancellation()
        guard removed > 0 else { return .init(png: data, removedPixels: 0) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let output = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.encoding }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { throw Failure.encoding }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= 16 * 1024 * 1024 else { throw Failure.encoding }
        try checkCancellation()
        return .init(png: encoded as Data, removedPixels: removed)
    }
}

/// Fail fast rather than accumulating queued copies of project media.
private actor StudioBackgroundCutLease {
    static let shared = StudioBackgroundCutLease()
    private var busy = false
    func acquire() throws {
        guard !busy else { throw StudioBackgroundCut.Failure.busy }
        busy = true
    }
    func release() { busy = false }
}
