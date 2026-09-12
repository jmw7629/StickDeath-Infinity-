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
struct DrawnElement: Codable, Identifiable, Equatable {
    let id: String
    var tool: DrawingTool
    var points: [StrokePoint]
    var color: String       // hex color
    var width: CGFloat
    var opacity: Double
    var fillColor: String?  // for fill tool / shape fill
    var layerID: String?
    /// Absent on historical drawings: their original rendering stays unchanged.
    /// Width and opacity remain canonical above, never duplicated in this value.
    var brush: StudioBrushDescriptor? = nil
}

struct StudioBrushDescriptor: Codable, Equatable {
    var version = 1
    var family: StudioBrushFamily
    var seed: UInt64
    var smoothing: Double = 3
    var pressureEnabled = false
    var tipAngleDegrees: Double = 45
    var texture: Double = 0.5
    var grain: Double = 0.3
    var gradientEndColor: StudioBrushColor?

    func settings(width: Double, opacity: Double) throws -> StudioBrushSettings {
        guard version == 1 else { throw StudioBrushError.invalidSettings("This brush document version is unavailable.") }
        let result = StudioBrushSettings(family: family, size: width, opacity: opacity,
            smoothing: smoothing, pressureEnabled: pressureEnabled, tipAngleDegrees: tipAngleDegrees,
            texture: texture, grain: grain, gradientEndColor: gradientEndColor)
        try result.validate()
        // DrawnElement's current color is opaque RGB; picker alpha is captured
        // once into its canonical opacity. Unequal endpoint alpha is unsupported.
        if family == .gradient, gradientEndColor?.alpha != 1 {
            throw StudioBrushError.invalidSettings("Gradient endpoint transparency is unavailable. Choose an opaque end color.")
        }
        return result
    }
}

struct StrokePoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var pressure: CGFloat?
    var timestamp: TimeInterval?
}

/// Captures one touch operation's identity/settings and actual event times.
/// The same element is previewed and committed; copying it later retains seed.
struct StudioStrokeInput {
    let id: String
    let frameID: String
    let layerID: String
    let tool: DrawingTool
    let color: String
    let width: Double
    let opacity: Double
    let brush: StudioBrushDescriptor?
    let documentSize: CGSize
    let viewportSize: CGSize
    let startedAt: Date
    private(set) var points: [StrokePoint] = []

    mutating func append(location: CGPoint, time: Date) throws {
        guard location.x.isFinite, location.y.isFinite, viewportSize.width > 0, viewportSize.height > 0 else {
            throw StudioBrushError.invalidSettings("Touch coordinates are unavailable.")
        }
        let limit = brush == nil ? 100_000 : 8_192
        guard points.count < limit else {
            throw StudioBrushError.workLimit("Touch capture reached its \(limit) sample limit. This entire stroke was rejected; no shortened stroke was saved. Discard the draft and draw a shorter stroke.")
        }
        let elapsed = time.timeIntervalSince(startedAt)
        guard elapsed.isFinite, elapsed >= 0, elapsed >= (points.last?.timestamp ?? 0) else {
            throw StudioBrushError.invalidSettings("Touch event timing changed unexpectedly. The stroke was not committed.")
        }
        points.append(StrokePoint(x: min(max(location.x / viewportSize.width, 0), 1) * documentSize.width,
            y: min(max(location.y / viewportSize.height, 0), 1) * documentSize.height,
            pressure: nil, timestamp: elapsed))
    }
    var element: DrawnElement {
        let shape = [.line, .rectangle, .circle].contains(tool)
        let rendered = shape && points.count > 1 ? [points[0], points[points.count - 1]] : points
        return DrawnElement(id: id, tool: tool, points: rendered, color: color,
            width: width, opacity: opacity, layerID: layerID, brush: brush)
    }
}

enum DrawingTool: String, Codable, CaseIterable {
    case pen, pencil, marker, brush, crayon, eraser, fill, eyedropper
    case line, rectangle, circle, text, lasso, wand
    case arrow, image, ruler, gradient, blur
    case airbrush, watercolor, neon, calligraphy
    case smudge, sharpen, move, hand, zoom
}

struct AnimationFrame: Codable, Identifiable, Equatable {
    let id: String
    var elements: [DrawnElement]
    // An immutable original frame record (pixels and/or opaque layer metadata)
    // is retained separately from editable strokes.
    var rasterAssetID: String? = nil
    var rasterLayerID: String? = nil
    /// Version 3 managed still placement. Nil keeps historical full-canvas stretch.
    var rasterPlacement: StudioRasterPlacement? = nil
}

struct StudioRasterPlacement: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static func aspectFit(imageWidth: Int, imageHeight: Int, canvasWidth: Int, canvasHeight: Int) -> Self {
        let scale = min(Double(canvasWidth) / Double(imageWidth), Double(canvasHeight) / Double(imageHeight))
        // Division followed by multiplication can exceed the fitted edge by
        // one ULP (for example 147 pixels fitted to 160). Keep a valid image
        // centered inside the canvas rather than producing a negative origin.
        let width = min(Double(canvasWidth), Double(imageWidth) * scale)
        let height = min(Double(canvasHeight), Double(imageHeight) * scale)
        return .init(x: (Double(canvasWidth) - width) / 2, y: (Double(canvasHeight) - height) / 2, width: width, height: height)
    }
}

// Lock mode enum for type safety
enum LayerLockMode: String, Codable, CaseIterable {
    case free, full, position, alpha
}

struct CanvasLayer: Codable, Identifiable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case id, name, visible, locked, opacity, lockMode, blendMode
        case glowEnabled, glowColor, colorLabel
    }

    init(id: String, name: String, visible: Bool = true, locked: Bool = false, opacity: Double = 1,
         lockMode: String = "free", blendMode: String = "normal", glowEnabled: Bool = false,
         glowColor: String? = nil, colorLabel: String? = nil) {
        self.id = id; self.name = name; self.visible = visible; self.locked = locked
        self.opacity = opacity; self.lockMode = locked ? "full" : lockMode
        self.blendMode = blendMode; self.glowEnabled = glowEnabled
        self.glowColor = glowColor; self.colorLabel = colorLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        lockMode = locked ? "full" : (try c.decodeIfPresent(String.self, forKey: .lockMode) ?? "free")
        blendMode = try c.decodeIfPresent(String.self, forKey: .blendMode) ?? "normal"
        glowEnabled = try c.decodeIfPresent(Bool.self, forKey: .glowEnabled) ?? false
        glowColor = try c.decodeIfPresent(String.self, forKey: .glowColor)
        colorLabel = try c.decodeIfPresent(String.self, forKey: .colorLabel)
    }

    var isFullyLocked: Bool { locked || lockMode == "full" }
}

// MARK: - Audio Clip
struct AudioClip: Codable, Identifiable, Equatable {
    let id: String
    var soundName: String
    var track: Int
    var startTime: Double
    var duration: Double
    var volume: Double = 0.8
    /// Immutable audio bytes in the same AnimationProject snapshot; nil for legacy clips.
    var assetID: UUID? = nil
    /// Source time is independent of placement on the animation timeline.
    var sourceOffset: Double = 0
    var isMuted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, soundName, track, startTime, duration, volume, assetID, sourceOffset, isMuted
    }
    init(id: String, soundName: String, track: Int, startTime: Double, duration: Double,
         volume: Double = 0.8, assetID: UUID? = nil, sourceOffset: Double = 0, isMuted: Bool = false) {
        self.id = id; self.soundName = soundName; self.track = track; self.startTime = startTime
        self.duration = duration; self.volume = volume; self.assetID = assetID
        self.sourceOffset = sourceOffset; self.isMuted = isMuted
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); soundName = try c.decode(String.self, forKey: .soundName)
        track = try c.decode(Int.self, forKey: .track); startTime = try c.decode(Double.self, forKey: .startTime)
        duration = try c.decode(Double.self, forKey: .duration)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        assetID = try c.decodeIfPresent(UUID.self, forKey: .assetID)
        sourceOffset = try c.decodeIfPresent(Double.self, forKey: .sourceOffset) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }
}

/// One validated command is committed per finished gesture, never per drag tick.
enum StudioAudioClipEdit: Equatable {
    case place(start: Double, track: Int)
    case trim(sourceOffset: Double, duration: Double)
    case volume(Double)
    case mute(Bool)
}

enum StudioAudioTimelineGeometry {
    static func snapped(_ time: Double, fps: Int, enabled: Bool) -> Double? {
        guard time.isFinite, (1...60).contains(fps), time >= 0, time <= 1000 else { return nil }
        return enabled ? (time * Double(fps)).rounded() / Double(fps) : time
    }
    static func time(at x: Double, pointsPerSecond: Double, fps: Int, snap: Bool) -> Double? {
        guard x.isFinite, pointsPerSecond.isFinite, pointsPerSecond > 0 else { return nil }
        return snapped(max(0, x / pointsPerSecond), fps: fps, enabled: snap)
    }
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
        self.waveform = [] // Catalog labels have no licensed/decoded audio asset yet.
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

    init(
        id: Int, roomID: Int, senderID: String, senderUsername: String? = nil,
        content: String, createdAt: String? = nil, mediaURL: String? = nil,
        type: MessageType? = nil, reactions: [String: ReactionData] = [:],
        replyTo: ReplyRef? = nil, readStatus: MessageReadStatus? = nil,
        edited: Bool? = nil, voiceDuration: Int? = nil, threadCount: Int? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.senderUsername = senderUsername
        self.content = content
        self.createdAt = createdAt
        self.mediaURL = mediaURL
        self.type = type
        self.reactions = reactions
        self.replyTo = replyTo
        self.readStatus = readStatus
        self.edited = edited
        self.voiceDuration = voiceDuration
        self.threadCount = threadCount
    }

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
