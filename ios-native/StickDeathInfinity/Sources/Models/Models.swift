// ═══════════════════════════════════════════════════════════════════
// Models — All data types for StickDeath Infinity
// Matches: Supabase schema + React TypeScript types exactly
// ═══════════════════════════════════════════════════════════════════

import Foundation

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

struct CanvasLayer: Codable, Identifiable {
    let id: String
    var name: String
    var visible: Bool
    var locked: Bool
    var opacity: Double
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
