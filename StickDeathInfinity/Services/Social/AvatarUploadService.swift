// ═══════════════════════════════════════════════════════════════════
// AvatarUploadService — Photos-picked avatar, downscaled on device to the
// AvatarImagePolicy bounds, uploaded to the account's own object path in the
// avatars bucket and persisted through the existing profile update. The
// original photo never leaves the device; only the bounded JPEG is sent.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum AvatarUploadService {
    enum Failure: LocalizedError {
        case unreadable, tooLarge, notConfigured, signedOut, unconfirmed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The selected image could not be read."
            case .tooLarge: return "The image could not be reduced to the avatar size limit."
            case .notConfigured: return "Avatar storage is not configured in this build. Nothing was uploaded."
            case .signedOut: return "Sign in before changing your avatar."
            case .unconfirmed: return "The server did not confirm the avatar. Your previous avatar is unchanged."
            }
        }
    }
    struct Prepared: Equatable { let jpeg: Data; let width: Int; let height: Int }

    /// Downscale to at most 512 px and step JPEG quality down until the byte bound holds.
    static func prepare(imageData: Data) throws -> Prepared {
        #if canImport(UIKit)
        guard let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0 else { throw Failure.unreadable }
        let target = AvatarImagePolicy.targetSize(width: Double(image.size.width * image.scale), height: Double(image.size.height * image.scale))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target.width, height: target.height), format: format)
        let scaled = renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: target.width, height: target.height)) }
        for quality in [0.85, 0.7, 0.55, 0.4, 0.3] {
            if let jpeg = scaled.jpegData(compressionQuality: quality), jpeg.count <= AvatarImagePolicy.maximumBytes {
                if let problem = AvatarImagePolicy.validate(byteCount: jpeg.count, width: target.width, height: target.height) {
                    throw Failure.unreadable.with(problem)
                }
                return Prepared(jpeg: jpeg, width: target.width, height: target.height)
            }
        }
        throw Failure.tooLarge
        #else
        throw Failure.unreadable
        #endif
    }

    /// Upload to `avatars/<account>/avatar.jpg` (upsert) and persist the public
    /// HTTPS address on the profile. Returns the confirmed address.
    static func upload(_ prepared: Prepared, account: String) async throws -> URL {
        let client: SupabaseClient
        do { client = try SupabaseManager.shared.client } catch { throw Failure.notConfigured }
        guard let session = client.auth.currentSession, !session.isExpired,
              session.user.id.uuidString.lowercased() == account.lowercased() else { throw Failure.signedOut }
        let path = AvatarImagePolicy.objectPath(account: account)
        let bucket = client.storage.from(AvatarImagePolicy.bucket)
        _ = try await bucket.upload(path, data: prepared.jpeg, options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
        let publicURL = try bucket.getPublicURL(path: path)
        guard let checked = CommunityMediaURL.checked(publicURL.absoluteString) else { throw Failure.unconfirmed }
        try Task.checkCancellation()
        // Cache-busting query keeps AsyncImage from showing the previous file.
        let stamped = checked.absoluteString + "?v=" + String(Int(Date().timeIntervalSince1970))
        try await AuthService.shared.updateProfile(["avatar_url": .string(stamped)])
        guard AuthService.shared.currentProfile?.avatarURL == stamped else { throw Failure.unconfirmed }
        return checked
    }

    enum Removal: Equatable { case removed, profileClearedFileRetained }
    /// Remove the avatar: the profile reference is cleared first (so the profile
    /// never points at a deleted file), then the account's own stored object is
    /// deleted. If the delete fails the caller is told the file was retained.
    static func remove(account: String) async throws -> Removal {
        let client: SupabaseClient
        do { client = try SupabaseManager.shared.client } catch { throw Failure.notConfigured }
        guard let session = client.auth.currentSession, !session.isExpired,
              session.user.id.uuidString.lowercased() == account.lowercased() else { throw Failure.signedOut }
        try await AuthService.shared.updateProfile(["avatar_url": .null])
        guard AuthService.shared.currentProfile?.avatarURL == nil else { throw Failure.unconfirmed }
        try Task.checkCancellation()
        do {
            _ = try await client.storage.from(AvatarImagePolicy.bucket).remove(paths: [AvatarImagePolicy.objectPath(account: account)])
            return .removed
        } catch {
            return .profileClearedFileRetained
        }
    }
}

private extension AvatarUploadService.Failure {
    func with(_ detail: String) -> LocalizedError { AvatarUploadDetail(detail: detail) }
}
private struct AvatarUploadDetail: LocalizedError { let detail: String; var errorDescription: String? { detail } }
