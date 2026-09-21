import Foundation
import ImageIO

/// One process-wide actor serializes verification and thumbnail decoding.
/// Visible cells cancel their requests on disappearance. The cache holds only
/// verified 128 px thumbnails, never full-resolution project images.
actor StudioImageLibraryThumbnails {
    static let shared = StudioImageLibraryThumbnails()
    static let maximumEntries = 48
    private var cached: [String: CGImage] = [:]
    private var order: [String] = []

    func image(_ item: StudioImageCatalogue.Image, catalogue: StudioImageCatalogue) throws -> CGImage {
        try Task.checkCancellation()
        guard catalogue.images.contains(item) else { throw StudioImageCatalogue.CatalogueError.invalid }
        let key = item.sha256 + ":" + item.pixelSHA256 + ":\(item.width):\(item.height)"
        if let image = cached[key] {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
        let bytes = try catalogue.checkedPNG(item)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width <= 128, image.height <= 128 else {
            throw StudioImageCatalogue.CatalogueError.invalid
        }
        try Task.checkCancellation()
        if order.count >= Self.maximumEntries, let oldest = order.first {
            cached.removeValue(forKey: oldest); order.removeFirst()
        }
        cached[key] = image; order.append(key)
        return image
    }
    var cachedImageCount: Int { cached.count }
}
