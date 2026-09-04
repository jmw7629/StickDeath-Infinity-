// ═══════════════════════════════════════════════════════════════════
// SDCore — Single production source of truth for persistence Codable types
// Foundation-only, Linux-compatible, consumed by both iOS app and Linux tests.
// ═══════════════════════════════════════════════════════════════════

import Foundation

// MARK: - Platform numeric compatibility

#if canImport(CoreGraphics)
import CoreGraphics
#else
public typealias CGFloat = Double
#endif

// MARK: - User Profile

public struct SDUserProfile: Codable, Identifiable, Sendable {
    public let id: String
    public var username: String?
    public var email: String?
    public var avatarURL: String?
    public var bio: String?
    public var role: SDUserRole?
    public var subscriptionTier: String?
    public var onboarded: Bool?
    public var skillLevel: String?
    public var interests: [String]?
    public var createdAt: String?

    public enum CodingKeys: String, CodingKey {
        case id, username, email, bio, role, onboarded, interests
        case avatarURL = "avatar_url"
        case subscriptionTier = "subscription_tier"
        case skillLevel = "skill_level"
        case createdAt = "created_at"
    }

    public init(id: String, username: String? = nil, email: String? = nil, avatarURL: String? = nil, bio: String? = nil, role: SDUserRole? = nil, subscriptionTier: String? = nil, onboarded: Bool? = nil, skillLevel: String? = nil, interests: [String]? = nil, createdAt: String? = nil) {
        self.id = id
        self.username = username
        self.email = email
        self.avatarURL = avatarURL
        self.bio = bio
        self.role = role
        self.subscriptionTier = subscriptionTier
        self.onboarded = onboarded
        self.skillLevel = skillLevel
        self.interests = interests
        self.createdAt = createdAt
    }
}

public enum SDUserRole: String, Codable, Sendable {
    case user, creator, moderator, superadmin
}

// MARK: - Studio Project

public struct SDStudioProject: Codable, Identifiable, Sendable {
    public let id: String
    public var userID: String
    public var name: String
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var frameCount: Int?
    public var thumbnailURL: String?
    public var createdAt: String?
    public var updatedAt: String?

    public enum CodingKeys: String, CodingKey {
        case id, name, width, height, fps
        case userID = "user_id"
        case frameCount = "frame_count"
        case thumbnailURL = "thumbnail_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: String, userID: String, name: String, width: Int? = nil, height: Int? = nil, fps: Int? = nil, frameCount: Int? = nil, thumbnailURL: String? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.userID = userID
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.frameCount = frameCount
        self.thumbnailURL = thumbnailURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Drawing Types

public struct DrawnElement: Codable, Identifiable, Sendable {
    public let id: String
    public var tool: DrawingTool
    public var points: [StrokePoint]
    public var color: String
    public var width: Double
    public var opacity: Double
    public var fillColor: String?
    public var layerID: String?

    public init(id: String, tool: DrawingTool, points: [StrokePoint], color: String, width: Double, opacity: Double, fillColor: String? = nil, layerID: String? = nil) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.width = width
        self.opacity = opacity
        self.fillColor = fillColor
        self.layerID = layerID
    }
}

public struct StrokePoint: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double?
    public var timestamp: TimeInterval?

    public init(x: Double, y: Double, pressure: Double? = nil, timestamp: TimeInterval? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

public enum DrawingTool: String, Codable, CaseIterable, Sendable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

public struct AnimationFrame: Codable, Identifiable, Sendable {
    public let id: String
    public var elements: [DrawnElement]

    public init(id: String, elements: [DrawnElement]) {
        self.id = id
        self.elements = elements
    }
}

// Lock mode enum
public enum LayerLockMode: String, Codable, CaseIterable, Sendable {
    case free, full, position, alpha
}

public struct CanvasLayer: Codable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var visible: Bool
    public var locked: Bool
    public var opacity: Double
    public var lockMode: String
    public var blendMode: String
    public var glowEnabled: Bool
    public var glowColor: String?
    public var colorLabel: String?

    public init(id: String, name: String, visible: Bool, locked: Bool, opacity: Double, lockMode: String = "free", blendMode: String = "normal", glowEnabled: Bool = false, glowColor: String? = nil, colorLabel: String? = nil) {
        self.id = id
        self.name = name
        self.visible = visible
        self.locked = locked
        self.opacity = opacity
        self.lockMode = lockMode
        self.blendMode = blendMode
        self.glowEnabled = glowEnabled
        self.glowColor = glowColor
        self.colorLabel = colorLabel
    }
}

// MARK: - Audio Clip

public struct AudioClip: Identifiable, Sendable {
    public let id: String
    public var soundName: String
    public var track: Int
    public var startTime: Double
    public var duration: Double
    public var volume: Double

    public init(id: String, soundName: String, track: Int, startTime: Double, duration: Double, volume: Double = 0.8) {
        self.id = id
        self.soundName = soundName
        self.track = track
        self.startTime = startTime
        self.duration = duration
        self.volume = volume
    }
}

// MARK: - Sound Effect

public struct SoundEffect: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let duration: String
    public let tag: String
    public let waveform: [Double]

    public init(id: String = UUID().uuidString, name: String, duration: String, tag: String) {
        self.id = id
        self.name = name
        self.duration = duration
        self.tag = tag
        self.waveform = (0..<8).map { _ in Double.random(in: 0.2...1.0) }
    }
}

// MARK: - Sticker

public struct Sticker: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let emoji: String

    public init(id: String, name: String, emoji: String) {
        self.id = id
        self.name = name
        self.emoji = emoji
    }
}

// MARK: - Share Target

public struct ShareTarget: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let icon: String
    public let isPro: Bool
    public var isEnabled: Bool

    public init(id: String, name: String, icon: String, isPro: Bool, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isPro = isPro
        self.isEnabled = isEnabled
    }
}

// MARK: - Export Enums

public enum ExportFormat: String, CaseIterable, Sendable {
    case mp4 = "MP4", gif = "GIF", png = "PNG", spritesheet = "Spritesheet"

    public var icon: String {
        switch self { case .mp4: return "🎬"; case .gif: return "🎞"; case .png: return "🖼"; case .spritesheet: return "⊞" }
    }

    public var subtitle: String {
        switch self { case .mp4: return "Video · social media"; case .gif: return "Animated · loops forever"; case .png: return "Individual frames"; case .spritesheet: return "All frames in one" }
    }
}

public enum ExportQuality: String, CaseIterable, Sendable {
    case standard = "Standard", hd = "HD", fullHD = "Full HD"

    public var resolution: String {
        switch self { case .standard: return "480p"; case .hd: return "720p"; case .fullHD: return "1080p" }
    }
}

// MARK: - Lock Mode

public enum LockMode: String, CaseIterable, Sendable {
    case free = "Free", full = "Full", position = "Pos", alpha = "Alpha"

    public var icon: String {
        switch self { case .free: return "🔓"; case .full: return "🔒"; case .position: return "📌"; case .alpha: return "🎨" }
    }
}

// MARK: - Blend Mode

public enum SDBlendMode: String, CaseIterable, Sendable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
    case darken = "Darken", lighten = "Lighten", colorDodge = "Color Dodge", colorBurn = "Color Burn"
}

// MARK: - Device Storage Persistence Types

public struct AnimationProject: Codable, Sendable {
    public let id: UUID
    public var metadata: AnimationMetadata
    public var frames: [StoredAnimationFrame]
    public var audioTracks: [AudioTrack]

    public init(id: UUID, metadata: AnimationMetadata, frames: [StoredAnimationFrame], audioTracks: [AudioTrack]) {
        self.id = id
        self.metadata = metadata
        self.frames = frames
        self.audioTracks = audioTracks
    }
}

public struct AnimationMetadata: Codable, Sendable {
    public let id: UUID
    public var title: String
    public var fps: Int
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var frameCount: Int
    public var layerCount: Int
    public var createdAt: Date
    public var modifiedAt: Date
    public var thumbnailData: Data?

    public init(id: UUID, title: String, fps: Int, canvasWidth: Int, canvasHeight: Int, frameCount: Int, layerCount: Int, createdAt: Date, modifiedAt: Date, thumbnailData: Data? = nil) {
        self.id = id
        self.title = title
        self.fps = fps
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameCount = frameCount
        self.layerCount = layerCount
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.thumbnailData = thumbnailData
    }
}

public struct StoredAnimationFrame: Codable, Sendable {
    public var imageData: Data?
    public var layerData: [LayerData]?

    public init(imageData: Data? = nil, layerData: [LayerData]? = nil) {
        self.imageData = imageData
        self.layerData = layerData
    }
}

public struct LayerData: Codable, Sendable {
    public let id: UUID
    public var name: String
    public var opacity: Double
    public var blendMode: String
    public var locked: Bool
    public var visible: Bool

    public init(id: UUID, name: String, opacity: Double, blendMode: String, locked: Bool, visible: Bool) {
        self.id = id
        self.name = name
        self.opacity = opacity
        self.blendMode = blendMode
        self.locked = locked
        self.visible = visible
    }
}

public struct AudioTrack: Codable, Sendable {
    public let id: UUID
    public var name: String
    public var format: String
    public var audioData: Data?
    public var startTime: Double
    public var duration: Double

    public init(id: UUID, name: String, format: String, audioData: Data? = nil, startTime: Double, duration: Double) {
        self.id = id
        self.name = name
        self.format = format
        self.audioData = audioData
        self.startTime = startTime
        self.duration = duration
    }
}

public struct StoredChatMessage: Codable, Sendable {
    public let id: UUID
    public let senderId: String
    public let recipientId: String
    public let text: String
    public let timestamp: Date
    public let mediaURL: String?

    public init(id: UUID, senderId: String, recipientId: String, text: String, timestamp: Date, mediaURL: String? = nil) {
        self.id = id
        self.senderId = senderId
        self.recipientId = recipientId
        self.text = text
        self.timestamp = timestamp
        self.mediaURL = mediaURL
    }
}

public enum MediaType: String, Sendable {
    case photo = "photos"
    case video = "videos"
    case audio = "audio"
    case animation = "animations"
}

// MARK: - Subscription & Call Rate Tiers (formerly in AppConfig)

public enum SubscriptionTier: String, CaseIterable, Codable, Sendable {
    case free = "free"
    case creator = "creator"
    case pro = "pro"
    case studio = "studio"

    public var price: Double {
        switch self {
        case .free:    return 0
        case .creator: return 4.99
        case .pro:     return 9.99
        case .studio:  return 19.99
        }
    }

    public var maxProjects: Int {
        switch self {
        case .free:    return 3
        case .creator: return 10
        case .pro:     return -1  // unlimited
        case .studio:  return -1
        }
    }

    public var maxAIQueries: Int {
        switch self {
        case .free:    return 10
        case .creator: return 50
        case .pro:     return 200
        case .studio:  return -1
        }
    }
}

public enum CallRateTier: String, CaseIterable, Codable, Sendable {
    case standard = "standard"
    case premium = "premium"
    case unlimited = "unlimited"

    public var ratePerMinute: Double {
        switch self {
        case .standard:  return 0.05
        case .premium:   return 0.15
        case .unlimited: return 0.25
        }
    }

    public var displayName: String {
        switch self {
        case .standard:  return "Standard"
        case .premium:   return "Premium"
        case .unlimited: return "Unlimited"
        }
    }
}
