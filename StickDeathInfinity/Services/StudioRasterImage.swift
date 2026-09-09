import Foundation
import CoreGraphics
import ImageIO

/// Shared bounded ImageIO preparation for canvas, thumbnails and file exports.
/// Cache keys retain and compare the complete immutable encoded bytes, so a
/// reused asset ID can never silently return another image's pixels.
enum StudioRasterImage {
    static let maximumCacheBytes = 96 * 1024 * 1024
    static let maximumCacheEntries = 128
    static let maximumManagedHistoryBytes = 40 * 1024 * 1024
    static let maximumManagedHistoryPixels = 32 * 1024 * 1024
    struct Prepared {
        let assetID: String
        let encoded: Data
        let managed: Bool
        let image: CGImage
    }
    private struct Entry { let prepared: Prepared; let cost: Int; var used: UInt64 }
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var bytes = 0
    private static var clock: UInt64 = 0
    static var footprint: (entries: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }; return (entries.count, bytes)
    }
    enum Failure: LocalizedError {
        case missing, invalid, limit
        var errorDescription: String? {
            switch self {
            case .missing: return "An imported still image is missing. Rendering is unavailable; the project has not been changed."
            case .invalid: return "An imported still image or its original metadata is corrupt or unsupported. The project has not been changed."
            case .limit: return "Imported image data exceeds the bounded rendering or history capacity. Use a smaller still image."
            }
        }
    }

    static func prepare(assetID: String, data: Data, managed: Bool, maximumDimension: Int = 8192) throws -> Prepared {
        guard !assetID.isEmpty, assetID.utf8.count <= 256, !data.isEmpty, data.count <= 32 * 1024 * 1024,
              (1...8192).contains(maximumDimension) else { throw Failure.limit }
        let key = assetID + ":\(maximumDimension):\(managed)"
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        if var hit = entries[key], hit.prepared.encoded == data {
            hit.used = clock; entries[key] = hit; return hit.prepared
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = metadata[kCGImagePropertyPixelWidth] as? Int,
              let height = metadata[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216 else { throw Failure.invalid }
        if managed {
            guard CGImageSourceGetType(source) as String? == "public.png",
                  (metadata[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
                  (metadata[kCGImagePropertyDepth] as? Int ?? 8) == 8 else { throw Failure.invalid }
        }
        // Evict before allocating the next image, bounding cache+decode peak.
        // Thumbnail transforms preserve aspect ratio and never enlarge input.
        let scale = min(1, Double(maximumDimension) / Double(max(width, height)))
        let estimated = data.count + Int(ceil(Double(width) * scale)) * Int(ceil(Double(height) * scale)) * 8 + 4096
        while !entries.isEmpty && bytes + estimated > maximumCacheBytes {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            bytes -= removed.cost
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), image.width <= maximumDimension, image.height <= maximumDimension,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.invalid }
        let cost = data.count + image.bytesPerRow * image.height + key.utf8.count + 1024
        guard cost <= maximumCacheBytes else { throw Failure.limit }
        if let old = entries.removeValue(forKey: key) { bytes -= old.cost }
        while bytes + cost > maximumCacheBytes || entries.count >= maximumCacheEntries {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            bytes -= removed.cost
        }
        let prepared = Prepared(assetID: assetID, encoded: data, managed: managed, image: image)
        entries[key] = Entry(prepared: prepared, cost: cost, used: clock); bytes += cost
        return prepared
    }

    /// Import has already passed the actual decoder. Recheck immutable source
    /// metadata and normalized pixels before accepting a caller-supplied record.
    static func validate(source: StoredImageSource, normalized: Data) throws {
        try source.validate()
        guard let original = CGImageSourceCreateWithData(source.originalData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(original) == 1,
              let type = CGImageSourceGetType(original) as String?,
              ["jpeg": ["public.jpeg"], "png": ["public.png"], "heif": ["public.heic", "public.heif"]][source.container]?.contains(type) == true,
              let metadata = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any],
              metadata[kCGImagePropertyPixelWidth] as? Int == source.originalWidth,
              metadata[kCGImagePropertyPixelHeight] as? Int == source.originalHeight,
              (metadata[kCGImagePropertyOrientation] as? Int ?? 1) == source.originalOrientation,
              CGImageSourceGetStatus(original) == .statusComplete else { throw Failure.invalid }
        let prepared = try prepare(assetID: "image-" + source.id.uuidString, data: normalized, managed: true)
        guard prepared.image.width == source.normalizedWidth, prepared.image.height == source.normalizedHeight else { throw Failure.invalid }
    }
}
