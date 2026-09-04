// ═══════════════════════════════════════════════════════════════════
// Models — All data types for StickDeath Infinity
// Matches: Supabase schema + React TypeScript types exactly
// ═══════════════════════════════════════════════════════════════════

import Foundation
import SwiftUI

// MARK: - User Profile
struct UserProfile: Codable, Identifiable {
    let id: String
    var username: String?
    var email: String?
    var avatarURL: String?
    var bio: String?
    var role: UserRole?
    var subscriptionTier: String?
    var onboarded: Bool?
    var skillLevel: String?
    var interests: [String]?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, email, bio, role, onboarded, interests
        case avatarURL = "avatar_url"
        case subscriptionTier = "subscription_tier"
        case skillLevel = "skill_level"
        case createdAt = "created_at"
    }

    enum UserRole: String, Codable {
        case user, creator, moderator, superadmin
    }
}

// MARK: - Studio Project
struct StudioProject: Codable, Identifiable {
    let id: String
    var userID: String
    var name: String
    var width: Int?
    var height: Int?
    var fps: Int?
    var frameCount: Int?
    var thumbnailURL: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, width, height, fps
        case userID = "user_id"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Drawing Types
struct DrawnElement: Codable, Identifiable {
    let id: String
    var tool: DrawingTool
    var points: [StrokePoint]
    var color: String       // hex color
    var width: CGFloat
    var opacity: Double
    var fillColor: String?  // for fill tool / shape fill
    var layerID: String?
}

struct StrokePoint: Codable {
    var x: CGFloat
    var y: CGFloat
    var pressure: CGFloat?
    var timestamp: TimeInterval?
}

enum DrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

struct AnimationFrame: Codable, Identifiable {
    let id: String
    var elements: [DrawnElement]
}

// Lock mode enum for type safety
enum LayerLockMode: String, Codable, CaseIterable {
    case free, full, position, alpha
}

struct CanvasLayer: Codable, Identifiable {
    let id: String
    var name: String
    var visible: Bool
    var locked: Bool
    var opacity: Double
    var lockMode: String = "free"      // free, full, position, alpha
    var blendMode: String = "normal"   // normal, multiply, screen, overlay, etc.
    var glowEnabled: Bool = false
    var glowColor: String?
    var colorLabel: String?
}

// StudioLayer — used by LayerPanel (wraps CanvasLayer with typed lock mode)
struct StudioLayer: Identifiable {
    let id: UUID
    var name: String
    var visible: Bool
    var opacity: Double
    var lockMode: LayerLockMode
    var blendMode: String
    var labelColor: Color
    
    init(from canvas: CanvasLayer) {
        self.id = UUID(uuidString: canvas.id) ?? UUID()
        self.name = canvas.name
        self.visible = canvas.visible
        self.opacity = canvas.opacity
        self.lockMode = LayerLockMode(rawValue: canvas.lockMode) ?? .free
        self.blendMode = canvas.blendMode
        self.labelColor = Color.red // default
    }
    
    init(id: UUID = UUID(), name: String, visible: Bool = true, opacity: Double = 1.0, lockMode: LayerLockMode = .free, blendMode: String = "Normal", labelColor: Color = .red) {
        self.id = id
        self.name = name
        self.visible = visible
        self.opacity = opacity
        self.lockMode = lockMode
        self.blendMode = blendMode
        self.labelColor = labelColor
    }
}

// MARK: - Audio Clip
struct AudioClip: Identifiable {
    let id: String
    var soundName: String
    var track: Int
    var startTime: Double
    var duration: Double
    var volume: Double = 0.8
}

// MARK: - Sound Effect
struct SoundEffect: Identifiable {
    let id: String
    let name: String
    let duration: String
    let tag: String
    let waveform: [CGFloat]
    
    init(id: String = UUID().uuidString, name: String, duration: String, tag: String) {
        self.id = id
        self.name = name
        self.duration = duration
        self.tag = tag
        self.waveform = (0..<8).map { _ in CGFloat.random(in: 0.2...1.0) }
    }
}

// MARK: - Sticker
struct Sticker: Identifiable {
    let id: String
    let name: String
    let emoji: String
}

// MARK: - Share Target
struct ShareTarget: Identifiable {
    let id: String
    let name: String
    let icon: String
    let isPro: Bool
    var isEnabled: Bool
}

// MARK: - Export Enums
enum ExportFormat: String, CaseIterable {
    case mp4 = "MP4", gif = "GIF", png = "PNG", spritesheet = "Spritesheet"
    var icon: String {
        switch self { case .mp4: return "🎬"; case .gif: return "🎞"; case .png: return "🖼"; case .spritesheet: return "⊞" }
    }
    var subtitle: String {
        switch self { case .mp4: return "Video · social media"; case .gif: return "Animated · loops forever"; case .png: return "Individual frames"; case .spritesheet: return "All frames in one" }
    }
}

enum ExportQuality: String, CaseIterable {
    case standard = "Standard", hd = "HD", fullHD = "Full HD"
    var resolution: String {
        switch self { case .standard: return "480p"; case .hd: return "720p"; case .fullHD: return "1080p" }
    }
}

// MARK: - Lock Mode
enum LockMode: String, CaseIterable {
    case free = "Free", full = "Full", position = "Pos", alpha = "Alpha"
    var icon: String {
        switch self { case .free: return "🔓"; case .full: return "🔒"; case .position: return "📌"; case .alpha: return "🎨" }
    }
}

// MARK: - Blend Mode
enum SDBlendMode: String, CaseIterable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
    case darken = "Darken", lighten = "Lighten", colorDodge = "Color Dodge", colorBurn = "Color Burn"
}

// MARK: - Social
struct Post: Codable, Identifiable {
    let id: Int
    var userID: String?
    var username: String?
    var content: String?
    var mediaURL: String?
    var likeCount: Int
    var commentCount: Int
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, content
        case userID = "user_id"
        case mediaURL = "media_url"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        mediaURL = try c.decodeIfPresent(String.self, forKey: .mediaURL)
        likeCount = (try? c.decode(Int.self, forKey: .likeCount)) ?? 0
        commentCount = (try? c.decode(Int.self, forKey: .commentCount)) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct Comment: Codable, Identifiable {
    let id: Int
    var postID: Int
    var userID: String
    var content: String
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, content
        case postID = "post_id"
        case userID = "user_id"
        case createdAt = "created_at"
    }
}

// MARK: - Messaging
struct ChatRoom: Codable, Identifiable {
    let id: Int
    var name: String?
    var type: String?         // "dm", "group", "channel"
    var emoji: String?
    var jitsiRoomID: String?  // legacy, now LiveKit room name
    var lastMessage: String?
    var lastMessageAt: String?
    var memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, type, emoji
        case jitsiRoomID = "jitsi_room_id"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case memberCount = "member_count"
    }
}

enum MessageType: String, Codable {
    case text, voice, image, video, location, contact, document, poll, animation, system
}

enum MessageReadStatus: String, Codable {
    case sent, delivered, read
}

struct ReactionData: Codable {
    var count: Int
    var reacted: Bool
}

struct ReplyRef: Codable {
    var sender: String
    var content: String
}

struct ChatMessage: Codable, Identifiable {
    let id: Int
    var roomID: Int
    var senderID: String
    var senderUsername: String?
    var content: String
    var createdAt: String?
    var mediaURL: String?
    var type: MessageType?
    var reactions: [String: ReactionData]
    var replyTo: ReplyRef?
    var readStatus: MessageReadStatus?
    var edited: Bool?
    var voiceDuration: Int?
    var threadCount: Int?

    var timeString: String {
        // Parse ISO date or return time
        guard let created = createdAt else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: created) {
            let tf = DateFormatter()
            tf.dateFormat = "h:mm a"
            return tf.string(from: date)
        }
        return ""
    }

    enum CodingKeys: String, CodingKey {
        case id, content, type, reactions, edited
        case roomID = "room_id"
        case senderID = "sender_id"
        case senderUsername = "sender_username"
        case createdAt = "created_at"
        case mediaURL = "media_url"
        case replyTo = "reply_to"
        case readStatus = "read_status"
        case voiceDuration = "voice_duration"
        case threadCount = "thread_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        roomID = try container.decode(Int.self, forKey: .roomID)
        senderID = try container.decode(String.self, forKey: .senderID)
        senderUsername = try container.decodeIfPresent(String.self, forKey: .senderUsername)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        mediaURL = try container.decodeIfPresent(String.self, forKey: .mediaURL)
        type = try container.decodeIfPresent(MessageType.self, forKey: .type)
        reactions = try container.decodeIfPresent([String: ReactionData].self, forKey: .reactions) ?? [:]
        replyTo = try container.decodeIfPresent(ReplyRef.self, forKey: .replyTo)
        readStatus = try container.decodeIfPresent(MessageReadStatus.self, forKey: .readStatus)
        edited = try container.decodeIfPresent(Bool.self, forKey: .edited)
        voiceDuration = try container.decodeIfPresent(Int.self, forKey: .voiceDuration)
        threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount)
    }
}

// MARK: - Challenges
struct Challenge: Codable, Identifiable {
    let id: Int
    var title: String
    var description: String?
    var thumbnailURL: String?
    var startDate: String?
    var endDate: String?
    var status: ChallengeStatus?
    var submissionCount: Int?
    var prizeDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case thumbnailURL = "thumbnail_url"
        case startDate = "start_date"
        case endDate = "end_date"
        case submissionCount = "submission_count"
        case prizeDescription = "prize_description"
    }

    enum ChallengeStatus: String, Codable {
        case upcoming, active, ended
    }
}

// MARK: - Tip
struct Tip: Codable, Identifiable {
    let id: Int
    var senderID: String
    var receiverID: String
    var amount: Double
    var type: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, amount, type
        case senderID = "sender_id"
        case receiverID = "receiver_id"
        case createdAt = "created_at"
    }
}

// MARK: - Export Result
struct StudioExportResult: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let format: ExportFormat
    let quality: ExportQuality
    let createdAt: Date
    let fileSize: Int64?
    let thumbnailURL: URL?

    init(
        id: String = UUID().uuidString,
        fileURL: URL,
        format: ExportFormat,
        quality: ExportQuality,
        createdAt: Date = Date(),
        fileSize: Int64? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.format = format
        self.quality = quality
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.thumbnailURL = thumbnailURL
    }
}

// MARK: - Publish Job
struct PublishJob: Identifiable, Codable, Sendable {
    let id: String
    let exportResultID: String
    var status: PublishJobStatus
    var metadata: PublishMetadata
    var serverJobID: String?
    var idempotencyKey: String
    var createdAt: Date
    var updatedAt: Date
    var publishedVideoURL: String?
    var publishedVideoID: String?
    var errorMessage: String?
    var retryCount: Int

    init(
        id: String = UUID().uuidString,
        exportResultID: String,
        status: PublishJobStatus = .preparing,
        metadata: PublishMetadata,
        serverJobID: String? = nil,
        idempotencyKey: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        publishedVideoURL: String? = nil,
        publishedVideoID: String? = nil,
        errorMessage: String? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.exportResultID = exportResultID
        self.status = status
        self.metadata = metadata
        self.serverJobID = serverJobID
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publishedVideoURL = publishedVideoURL
        self.publishedVideoID = publishedVideoID
        self.errorMessage = errorMessage
        self.retryCount = retryCount
    }

    enum CodingKeys: String, CodingKey {
        case id, status, metadata
        case exportResultID = "export_result_id"
        case serverJobID = "server_job_id"
        case idempotencyKey = "idempotency_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case publishedVideoURL = "published_video_url"
        case publishedVideoID = "published_video_id"
        case errorMessage = "error_message"
        case retryCount = "retry_count"
    }
}

// MARK: - Publish Job Status
enum PublishJobStatus: String, Codable, Sendable {
    case preparing
    case uploading
    case queued
    case processing
    case published
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .preparing: return "Preparing"
        case .uploading: return "Uploading"
        case .queued: return "In Queue"
        case .processing: return "Processing"
        case .published: return "Published"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var icon: String {
        switch self {
        case .preparing: return "arrow.up.circle"
        case .uploading: return "icloud.and.arrow.up"
        case .queued: return "clock"
        case .processing: return "gearshape.2"
        case .published: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .published, .failed, .cancelled: return true
        default: return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .preparing, .uploading, .queued: return true
        default: return false
        }
    }
}

// MARK: - Publish Metadata
struct PublishMetadata: Codable, Sendable {
    var title: String
    var description: String
    var tags: [String]
    var thumbnailDataURL: Data?
    var visibility: PublishVisibility
    var audience: PublishAudience

    init(
        title: String = "",
        description: String = "",
        tags: [String] = [],
        thumbnailDataURL: Data? = nil,
        visibility: PublishVisibility = .unlisted,
        audience: PublishAudience = .allAges
    ) {
        self.title = title
        self.description = description
        self.tags = tags
        self.thumbnailDataURL = thumbnailDataURL
        self.visibility = visibility
        self.audience = audience
    }
}

// MARK: - Publish Visibility
enum PublishVisibility: String, Codable, Sendable, CaseIterable {
    case `public`
    case unlisted
    case `private`

    var displayName: String {
        switch self {
        case .public: return "Public"
        case .unlisted: return "Unlisted"
        case .private: return "Private"
        }
    }

    var icon: String {
        switch self {
        case .public: return "globe"
        case .unlisted: return "link"
        case .private: return "lock"
        }
    }

    var description: String {
        switch self {
        case .public: return "Anyone can search for and view"
        case .unlisted: return "Anyone with the link can view"
        case .private: return "Only you can view"
        }
    }
}

// MARK: - Publish Audience
enum PublishAudience: String, Codable, Sendable, CaseIterable {
    case allAges = "all"
    case over13 = "over_13"
    case over18 = "over_18"

    var displayName: String {
        switch self {
        case .allAges: return "Made for Kids / All Ages"
        case .over13: return "Not Made for Kids (13+)"
        case .over18: return "Mature (18+)"
        }
    }
}

// MARK: - R3 Call State
struct R3CallState {
    var isActive = false
    var rateTier: AppConfig.CallRateTier = .standard
    var duration: TimeInterval = 0
    var currentCost: Double = 0
    var spendLimit: Double = 50.0
    var isIdle = false
    var personalityLine: String? = nil
}
