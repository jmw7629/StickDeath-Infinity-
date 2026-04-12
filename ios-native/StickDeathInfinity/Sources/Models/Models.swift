// Models.swift
// All data models matching the Supabase database schema

import Foundation
import SwiftUI

// MARK: - User Profile
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
}

struct AnimationFrame: Codable, Identifiable {
    let id: UUID
    var figureStates: [FigureState]
    var duration: Double
}

struct FigureState: Codable, Identifiable {
    let id: UUID
    var figureId: UUID
    var joints: [String: CGPoint]
    var visible: Bool
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
