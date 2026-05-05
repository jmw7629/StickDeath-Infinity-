// Models.swift
// All data models matching the Supabase database schema
// v3: Added PlacedObject, SoundClip, user personalization, achievement models

import Foundation
import SwiftUI

// MARK: - User Profile (with personalization fields)
struct UserProfile: Codable, Identifiable {
    let id: String
    var username: String?
    var email: String?
    var bio: String?
    var avatar_url: String?
    var role: String
    var banned: Bool?
    var subscription_tier: String?
    var subscription_status: String?
    var created_at: String?

    // Personalization (stored in user_preferences JSONB or separate table)
    var skill_level: String?       // beginner, intermediate, advanced
    var interests: [String]?       // ["action", "comedy", "scifi", ...]
    var theme_accent: String?      // hex color
    var preferred_fps: Int?
    var preferred_canvas: String?  // "portrait", "landscape", "square"
}

// MARK: - Studio Project (from DB)
// v4.3: CodingKeys map 'title' ↔ DB column 'name'
struct StudioProject: Codable, Identifiable {
    let id: Int
    let user_id: String
    var title: String        // Maps to DB column "name"
    var description: String?
    var canvas_width: Int?
    var canvas_height: Int?
    var fps: Int?
    var status: String?
    var created_at: String?
    var updated_at: String?
    var thumbnail_url: String?
    var background_type: String?
    var background_value: String?

    // Convenience display name
    var name: String { title }

    enum CodingKeys: String, CodingKey {
        case id, user_id
        case title = "name"  // DB column is "name", Swift uses "title"
        case description, canvas_width, canvas_height, fps
        case status, created_at, updated_at, thumbnail_url
        case background_type, background_value
    }
}

struct StudioProjectInsert: Encodable {
    let userId: String
    let title: String
    let canvasWidth: Int
    let canvasHeight: Int
    let fps: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case title = "name"  // DB column is "name"
        case canvasWidth = "canvas_width"
        case canvasHeight = "canvas_height"
        case fps
    }
}

// MARK: - Feed Item (project + user info)
// v4.3: CodingKeys map 'title' ↔ DB column 'name' (queries studio_projects)
struct FeedItem: Codable, Identifiable {
    let id: Int
    let title: String
    let status: String?
    let created_at: String?
    let thumbnail_url: String?
    let like_count: Int?
    let view_count: Int?
    let users: FeedUser?

    // Display-only fields (not from DB)
    var authorName: String
    var authorEmoji: String
    var timeAgo: String
    var duration: String
    var frameCount: Int
    var likes: Int
    var comments: Int
    var views: Int

    enum CodingKeys: String, CodingKey {
        case id
        case title = "name"  // DB column is "name"
        case status, created_at, thumbnail_url
        case like_count, view_count, users
    }

    // DB initializer (from Codable)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        thumbnail_url = try c.decodeIfPresent(String.self, forKey: .thumbnail_url)
        like_count = try c.decodeIfPresent(Int.self, forKey: .like_count)
        view_count = try c.decodeIfPresent(Int.self, forKey: .view_count)
        users = try c.decodeIfPresent(FeedUser.self, forKey: .users)
        authorName = users?.username ?? "Unknown"
        authorEmoji = "💀"
        timeAgo = ""
        duration = "0:00"
        frameCount = 0
        likes = like_count ?? 0
        comments = 0
        views = view_count ?? 0
    }

    // Local display initializer
    init(id: Int, title: String, authorName: String, authorEmoji: String,
         timeAgo: String, duration: String, frameCount: Int,
         likes: Int, comments: Int, views: Int) {
        self.id = id
        self.title = title
        self.status = nil
        self.created_at = nil
        self.thumbnail_url = nil
        self.like_count = likes
        self.view_count = views
        self.users = nil
        self.authorName = authorName
        self.authorEmoji = authorEmoji
        self.timeAgo = timeAgo
        self.duration = duration
        self.frameCount = frameCount
        self.likes = likes
        self.comments = comments
        self.views = views
    }
}

struct FeedUser: Codable {
    let username: String?
    let avatar_url: String?
}

// MARK: - Animation Data (stored as JSON)
struct AnimationData: Codable {
    var frames: [AnimationFrame]
    var figures: [StickFigure]
    var soundTimeline: [SoundClip]?
}

struct AnimationFrame: Codable, Identifiable {
    let id: UUID
    var figureStates: [FigureState]
    var duration: Double
    var placedObjects: [PlacedObject]  // v3: props from asset library
    var drawnElements: [DrawnElement]   // v9: freehand drawing, shapes, text
    var importedImages: [ImportedImage] // v9: photos imported to canvas
}

// MARK: - Imported Image (photo on canvas — draggable/resizable)
struct ImportedImage: Identifiable {
    let id: UUID
    var image: UIImage
    var position: CGPoint     // Center position in canvas coords
    var size: CGSize           // Display size in canvas coords
    var rotation: Double       // Degrees
    var opacity: Double
}

// Codable conformance for ImportedImage (stores as PNG data)
extension ImportedImage: Codable {
    enum CodingKeys: String, CodingKey {
        case id, position, size, rotation, opacity, imageData
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(position, forKey: .position)
        try container.encode(size, forKey: .size)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(opacity, forKey: .opacity)
        if let data = image.pngData() {
            try container.encode(data, forKey: .imageData)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        position = try container.decode(CGPoint.self, forKey: .position)
        size = try container.decode(CGSize.self, forKey: .size)
        rotation = try container.decode(Double.self, forKey: .rotation)
        opacity = try container.decode(Double.self, forKey: .opacity)
        if let data = try container.decodeIfPresent(Data.self, forKey: .imageData),
           let img = UIImage(data: data) {
            image = img
        } else {
            image = UIImage()
        }
    }
}

struct FigureState: Codable, Identifiable {
    let id: UUID
    var figureId: UUID
    var joints: [String: CGPoint]
    var visible: Bool
}

// MARK: - Placed Object (asset dropped on canvas)
struct PlacedObject: Codable, Identifiable {
    let id: UUID
    var assetId: String              // Reference to studio_assets.id
    var sfSymbol: String             // SF Symbol name for rendering
    var name: String
    var position: CGPoint
    var size: CGFloat                // Base size
    var rotation: Double             // Degrees
    var opacity: Double
    var tint: String                 // Hex color
    var zIndex: Int                  // Layer order
    var locked: Bool
}

// MARK: - Sound Clip (placed on sound timeline)
struct SoundClip: Codable, Identifiable {
    let id: UUID
    var assetId: String              // Reference to studio_assets.id
    var name: String
    var startFrame: Int              // Frame index where sound begins
    var durationFrames: Int          // How many frames it plays
    var volume: Float                // 0.0 - 1.0
    var category: String
}

// MARK: - Stick Figure
struct StickFigure: Codable, Identifiable {
    let id: UUID
    var name: String
    var color: CodableColor
    var lineWidth: CGFloat
    var headRadius: CGFloat
    var joints: [String: CGPoint]

    static let defaultJoints: [String: CGPoint] = [
        "head":          CGPoint(x: 0, y: -60),
        "neck":          CGPoint(x: 0, y: -40),
        "leftShoulder":  CGPoint(x: -25, y: -35),
        "rightShoulder": CGPoint(x: 25, y: -35),
        "leftElbow":     CGPoint(x: -40, y: -15),
        "rightElbow":    CGPoint(x: 40, y: -15),
        "leftHand":      CGPoint(x: -50, y: 5),
        "rightHand":     CGPoint(x: 50, y: 5),
        "hip":           CGPoint(x: 0, y: 0),
        "leftKnee":      CGPoint(x: -15, y: 30),
        "rightKnee":     CGPoint(x: 15, y: 30),
        "leftFoot":      CGPoint(x: -20, y: 60),
        "rightFoot":     CGPoint(x: 20, y: 60),
    ]

    static let bones: [(String, String)] = [
        ("head", "neck"),
        ("neck", "leftShoulder"), ("neck", "rightShoulder"),
        ("leftShoulder", "leftElbow"), ("rightShoulder", "rightElbow"),
        ("leftElbow", "leftHand"), ("rightElbow", "rightHand"),
        ("neck", "hip"),
        ("hip", "leftKnee"), ("hip", "rightKnee"),
        ("leftKnee", "leftFoot"), ("rightKnee", "rightFoot"),
    ]

    static func newFigure(name: String = "Figure", color: Color = .white) -> StickFigure {
        StickFigure(
            id: UUID(),
            name: name,
            color: CodableColor(color),
            lineWidth: 3,
            headRadius: 12,
            joints: defaultJoints
        )
    }
}

// MARK: - Codable Color Wrapper
struct CodableColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    init(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = r; self.green = g; self.blue = b; self.opacity = a
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: opacity)
    }
}

// MARK: - Messages
struct Conversation: Codable, Identifiable {
    let id: Int
    let created_at: String?
    var last_message: String?
    var other_user: UserProfile?
}

struct Message: Codable, Identifiable {
    let id: Int
    let conversation_id: Int
    let sender_id: String
    let content: String
    let created_at: String
}

// MARK: - Achievements
struct Achievement: Identifiable {
    let id: String
    let title: String
    let description: String
    let icon: String
    let color: Color
    let unlocked: Bool
    let progress: Double   // 0.0 - 1.0

    static let all: [Achievement] = [
        Achievement(id: "first_frame", title: "First Frame", description: "Create your first animation frame", icon: "1.circle.fill", color: .red, unlocked: false, progress: 0),
        Achievement(id: "ten_frames", title: "Animator", description: "Create an animation with 10+ frames", icon: "10.circle.fill", color: .cyan, unlocked: false, progress: 0),
        Achievement(id: "first_publish", title: "Publisher", description: "Publish your first animation", icon: "paperplane.circle.fill", color: .green, unlocked: false, progress: 0),
        Achievement(id: "community_star", title: "Community Star", description: "Get 100 likes on an animation", icon: "star.circle.fill", color: .yellow, unlocked: false, progress: 0),
        Achievement(id: "prolific", title: "Prolific Creator", description: "Create 10 projects", icon: "flame.circle.fill", color: .red, unlocked: false, progress: 0),
        Achievement(id: "social_butterfly", title: "Social Butterfly", description: "Connect 3+ social accounts", icon: "person.2.circle.fill", color: .purple, unlocked: false, progress: 0),
        Achievement(id: "streak_7", title: "On Fire", description: "Use the app 7 days in a row", icon: "flame.fill", color: .red, unlocked: false, progress: 0),
        Achievement(id: "asset_collector", title: "Asset Collector", description: "Use 50 different objects in your animations", icon: "cube.fill", color: .indigo, unlocked: false, progress: 0),
    ]
}

// MARK: - Animation Template
struct AnimationTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let category: String
    let description: String
    let figureCount: Int
    let frameCount: Int
    let isPro: Bool
}

// MARK: - Challenge Status
enum ChallengeStatus: String, Codable {
    case active, voting, completed

    var label: String {
        switch self {
        case .active: return "ACTIVE"
        case .voting: return "VOTING"
        case .completed: return "COMPLETED"
        }
    }

    var color: Color {
        switch self {
        case .active: return .green
        case .voting: return .yellow
        case .completed: return Color(hex: "#5a5a6e")
        }
    }
}

// MARK: - Challenge (Supabase: challenges table)
struct Challenge: Codable, Identifiable, Hashable {
    let id: Int
    var title: String
    var description: String
    var theme: String?
    var start_date: String?
    var end_date: String?
    var prize_description: String?
    var entry_count: Int?
    var thumbnail_url: String?
    var created_by: String?

    // Display fields
    var entries: Int
    var prize: String
    var endDate: String
    var status: ChallengeStatus

    enum CodingKeys: String, CodingKey {
        case id, title, description, theme, start_date, end_date
        case prize_description, entry_count, thumbnail_url, created_by
    }

    // DB initializer
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        start_date = try c.decodeIfPresent(String.self, forKey: .start_date)
        end_date = try c.decodeIfPresent(String.self, forKey: .end_date)
        prize_description = try c.decodeIfPresent(String.self, forKey: .prize_description)
        entry_count = try c.decodeIfPresent(Int.self, forKey: .entry_count)
        thumbnail_url = try c.decodeIfPresent(String.self, forKey: .thumbnail_url)
        created_by = try c.decodeIfPresent(String.self, forKey: .created_by)
        entries = entry_count ?? 0
        prize = prize_description ?? ""
        endDate = end_date ?? ""
        status = .active
    }

    // Local display initializer
    init(id: Int, title: String, description: String, entries: Int,
         prize: String, endDate: String, status: ChallengeStatus) {
        self.id = id
        self.title = title
        self.description = description
        self.theme = nil
        self.start_date = nil
        self.end_date = endDate
        self.prize_description = prize
        self.entry_count = entries
        self.thumbnail_url = nil
        self.created_by = nil
        self.entries = entries
        self.prize = prize
        self.endDate = endDate
        self.status = status
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Challenge, rhs: Challenge) -> Bool { lhs.id == rhs.id }
}

struct ChallengeEntry: Codable, Identifiable {
    let id: Int
    let challenge_id: Int
    let project_id: Int?
    var user_id: String?
    var user: FeedUser?
    var project_title: String?
    var thumbnail_url: String?
    var vote_count: Int?
    var created_at: String?
}

// MARK: - Notification (Supabase: notifications table)
struct AppNotification: Codable, Identifiable {
    let id: Int
    var type: String            // "like", "comment", "follow", "challenge", "system"
    var title: String
    var body: String?
    var read: Bool
    var created_at: String?
    var related_post_id: Int?
    var related_user_id: String?
    var related_challenge_id: Int?
}

// MARK: - Comment (Supabase: comments table)
struct PostComment: Codable, Identifiable {
    let id: Int
    let post_id: Int
    let user_id: String
    var content: String
    var created_at: String?
    var user: FeedUser?
}

// MARK: - Hashable conformance for navigation destinations
extension FeedItem: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FeedItem, rhs: FeedItem) -> Bool { lhs.id == rhs.id }
}

extension StudioProject: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: StudioProject, rhs: StudioProject) -> Bool { lhs.id == rhs.id }
}
