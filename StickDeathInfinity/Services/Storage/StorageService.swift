// ═══════════════════════════════════════════════════════════════════
// StorageService — Supabase Storage for images, videos, project data
// Matches: src/services/StorageService.ts
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase
import UIKit

@MainActor
final class StorageService {
    static let shared = StorageService()
    private let supabase = SupabaseManager.shared.client
    private let bucket = "media"

    // MARK: - Upload Image
    func uploadImage(_ image: UIImage, path: String, quality: CGFloat = 0.8) async throws -> String {
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw StorageError.invalidImage
        }

        let filePath = "\(path)/\(UUID().uuidString).jpg"
        try await supabase.storage.from(bucket).upload(
            filePath,
            data: data,
            options: .init(contentType: "image/jpeg")
        )

        let publicURL = try supabase.storage.from(bucket).getPublicURL(path: filePath)
        return publicURL.absoluteString
    }

    // MARK: - Upload Video
    func uploadVideo(data: Data, path: String) async throws -> String {
        let filePath = "\(path)/\(UUID().uuidString).mp4"
        try await supabase.storage.from(bucket).upload(
            filePath,
            data: data,
            options: .init(contentType: "video/mp4")
        )

        let publicURL = try supabase.storage.from(bucket).getPublicURL(path: filePath)
        return publicURL.absoluteString
    }

    // MARK: - Upload Avatar
    func uploadAvatar(_ image: UIImage) async throws -> String {
        guard let userId = AuthService.shared.userId else {
            throw StorageError.notAuthenticated
        }
        return try await uploadImage(image, path: "avatars/\(userId)")
    }

    // MARK: - Upload Project Frame Data
    func uploadProjectData(_ data: Data, projectID: String) async throws -> String {
        let filePath = "projects/\(projectID)/\(UUID().uuidString).json"
        try await supabase.storage.from(bucket).upload(
            filePath,
            data: data,
            options: .init(contentType: "application/json")
        )

        let publicURL = try supabase.storage.from(bucket).getPublicURL(path: filePath)
        return publicURL.absoluteString
    }

    // MARK: - Delete File
    func deleteFile(path: String) async throws {
        try await supabase.storage.from(bucket).remove(paths: [path])
    }

    // MARK: - Download
    func download(path: String) async throws -> Data {
        try await supabase.storage.from(bucket).download(path: path)
    }

    enum StorageError: Error {
        case invalidImage
        case notAuthenticated
        case uploadFailed
    }
}
