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
struct StudioProject: Codable, Identifiable {
    let id: Int
    let user_id: String
    var title: String
    var canvas_width: Int?
    var canvas_height: Int?
    var fps: Int?
    var status: String?
    var created_at: String?
    var updated_at: String?
    var thumbnail_url: String?
    var view_count: Int?
    var like_count: Int?
}

struct StudioProjectInsert: Encodable {
    let userId: String
    let title: String
    let canvasWidth: Int
    let canvasHeight: Int
    let fps: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case title
        case canvasWidth = "canvas_width"
        case canvasHeight = "canvas_height"
        case fps
    }
}

// MARK: - Feed Item (project + user info)
struct FeedItem: Codable, Identifiable {
    let id: Int
    let title: String
    let status: String?
    let created_at: String?
    let thumbnail_url: String?
    let view_count: Int?
    let like_count: Int?
    let users: FeedUser?
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
        Achievement(id: "first_frame", title: "First Frame", description: "Create your first animation frame", icon: "1.circle.fill", color: .orange, unlocked: false, progress: 0),
        Achievement(id: "ten_frames", title: "Animator", description: "Create an animation with 10+ frames", icon: "10.circle.fill", color: .cyan, unlocked: false, progress: 0),
        Achievement(id: "first_publish", title: "Publisher", description: "Publish your first animation", icon: "paperplane.circle.fill", color: .green, unlocked: false, progress: 0),
        Achievement(id: "community_star", title: "Community Star", description: "Get 100 likes on an animation", icon: "star.circle.fill", color: .yellow, unlocked: false, progress: 0),
        Achievement(id: "prolific", title: "Prolific Creator", description: "Create 10 projects", icon: "flame.circle.fill", color: .red, unlocked: false, progress: 0),
        Achievement(id: "social_butterfly", title: "Social Butterfly", description: "Connect 3+ social accounts", icon: "person.2.circle.fill", color: .purple, unlocked: false, progress: 0),
        Achievement(id: "streak_7", title: "On Fire", description: "Use the app 7 days in a row", icon: "flame.fill", color: .orange, unlocked: false, progress: 0),
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
