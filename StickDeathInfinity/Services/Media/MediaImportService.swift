// ═══════════════════════════════════════════════════════════════════
// MediaImportService — Real media import from Photos, Files, Camera
// Uses PhotosUI, UniformTypeIdentifiers, AVFoundation, ImageIO
// ═══════════════════════════════════════════════════════════════════

import Foundation
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import ImageIO
import SwiftUI

@MainActor
final class MediaImportService: ObservableObject {
    static let shared = MediaImportService()
    
    @Published var importedAssets: [MediaAsset] = []
    @Published var isImporting = false
    
    private let storageManager = DeviceStorageManager.shared
    
    // MARK: - Import Image from Photos
    func importImageFromPhotos(_ item: PhotosPickerItem) async throws -> MediaAsset {
        isImporting = true
        defer { isImporting = false }
        
        let data = try await item.loadTransferable(type: Data.self)
        guard let imageData = data else {
            throw MediaImportError.invalidData
        }
        
        let filename = "\(UUID().uuidString).jpg"
        let fileURL = try storageManager.saveMedia(data: imageData, type: .photo, filename: filename)
        
        // Create bookmark for persistent access
        let bookmarkData = try? fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        // Extract thumbnail
        let thumbnail = generateThumbnail(from: imageData)
        
        // Get image dimensions
        let (width, height) = getImageDimensions(from: imageData)
        
        let asset = MediaAsset(
            name: filename,
            type: .image,
            localURL: fileURL,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnail,
            width: width,
            height: height
        )
        
        importedAssets.append(asset)
        return asset
    }
    
    // MARK: - Import Image from Files
    func importImageFromFiles(_ url: URL) async throws -> MediaAsset {
        isImporting = true
        defer { isImporting = false }
        
        // Start accessing the security-scoped resource
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let data = try Data(contentsOf: url)
        let filename = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let fileURL = try storageManager.saveMedia(data: data, type: .photo, filename: filename)
        
        // Create bookmark
        let bookmarkData = try? fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let thumbnail = generateThumbnail(from: data)
        let (width, height) = getImageDimensions(from: data)
        
        let asset = MediaAsset(
            name: url.lastPathComponent,
            type: .image,
            localURL: fileURL,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnail,
            width: width,
            height: height
        )
        
        importedAssets.append(asset)
        return asset
    }
    
    // MARK: - Import Video from Photos
    func importVideoFromPhotos(_ item: PhotosPickerItem) async throws -> MediaAsset {
        isImporting = true
        defer { isImporting = false }
        
        guard let movieURL = try await item.loadTransferable(type: MovieTransferable.self) else {
            throw MediaImportError.invalidData
        }
        
        let videoData = try Data(contentsOf: movieURL.url)
        let filename = "\(UUID().uuidString).mp4"
        let fileURL = try storageManager.saveMedia(data: videoData, type: .video, filename: filename)
        
        // Create bookmark
        let bookmarkData = try? fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        // Extract video metadata
        let (duration, width, height) = await getVideoMetadata(from: fileURL)
        let thumbnail = await generateVideoThumbnail(from: fileURL)
        
        let asset = MediaAsset(
            name: filename,
            type: .video,
            localURL: fileURL,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnail,
            duration: duration,
            width: width,
            height: height
        )
        
        importedAssets.append(asset)
        return asset
    }
    
    // MARK: - Import Video from Files
    func importVideoFromFiles(_ url: URL) async throws -> MediaAsset {
        isImporting = true
        defer { isImporting = false }
        
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let data = try Data(contentsOf: url)
        let filename = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let fileURL = try storageManager.saveMedia(data: data, type: .video, filename: filename)
        
        let bookmarkData = try? fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let (duration, width, height) = await getVideoMetadata(from: fileURL)
        let thumbnail = await generateVideoThumbnail(from: fileURL)
        
        let asset = MediaAsset(
            name: url.lastPathComponent,
            type: .video,
            localURL: fileURL,
            bookmarkData: bookmarkData,
            thumbnailData: thumbnail,
            duration: duration,
            width: width,
            height: height
        )
        
        importedAssets.append(asset)
        return asset
    }
    
    // MARK: - Import Audio from Files
    func importAudioFromFiles(_ url: URL) async throws -> MediaAsset {
        isImporting = true
        defer { isImporting = false }
        
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let data = try Data(contentsOf: url)
        let filename = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let fileURL = try storageManager.saveMedia(data: data, type: .audio, filename: filename)
        
        let bookmarkData = try? fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let duration = await getAudioDuration(from: fileURL)
        
        let asset = MediaAsset(
            name: url.lastPathComponent,
            type: .audio,
            localURL: fileURL,
            bookmarkData: bookmarkData,
            duration: duration
        )
        
        importedAssets.append(asset)
        return asset
    }
    
    // MARK: - Delete Media Asset
    func deleteAsset(_ asset: MediaAsset) throws {
        try FileManager.default.removeItem(at: asset.localURL)
        importedAssets.removeAll { $0.id == asset.id }
    }
    
    // MARK: - Helper Methods
    private func generateThumbnail(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return thumbnail.jpegData(compressionQuality: 0.7)
    }
    
    private func getImageDimensions(from data: Data) -> (Int, Int)? {
        guard let image = UIImage(data: data) else { return nil }
        return (Int(image.size.width), Int(image.size.height))
    }
    
    private func getVideoMetadata(from url: URL) async -> (TimeInterval?, Int?, Int?) {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks?.first else {
            return (duration, nil, nil)
        }
        let size = try? await videoTrack.load(.naturalSize)
        return (duration, Int(size?.width ?? 0), Int(size?.height ?? 0))
    }
    
    private func generateVideoThumbnail(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        
        do {
            let (cgImage, _) = try await imageGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            let uiImage = UIImage(cgImage: cgImage)
            let size = CGSize(width: 200, height: 200)
            let renderer = UIGraphicsImageRenderer(size: size)
            let thumbnail = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: size))
            }
            return thumbnail.jpegData(compressionQuality: 0.7)
        } catch {
            return nil
        }
    }
    
    private func getAudioDuration(from url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        return try? await asset.load(.duration).seconds
    }
}

// MARK: - Errors
enum MediaImportError: LocalizedError {
    case invalidData
    case fileNotFound
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .invalidData: return "Invalid media data"
        case .fileNotFound: return "File not found"
        case .permissionDenied: return "Permission denied"
        }
    }
}

// MARK: - Movie Transferable for PhotosPicker
struct MovieTransferable: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(received.file.path.lastPathComponent)
            try FileManager.default.copyItem(at: received.file.path, to: copy)
            return Self(url: copy)
        }
    }
}