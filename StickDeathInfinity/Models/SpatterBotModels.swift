// ═══════════════════════════════════════════════════════════════════
// SpatterBotModels — Data types for Spatter Command Center
// Matches: spatter-admin Viktor Space data layer exactly
// Owner-only social autopilot for STICKDEATH ∞
// ═══════════════════════════════════════════════════════════════════

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Bot Platform

enum BotPlatform: String, CaseIterable, Identifiable, Codable {
    case twitter   = "twitter"
    case instagram = "instagram"
    case tiktok    = "tiktok"
    case youtube   = "youtube"
    case reddit    = "reddit"
    case facebook  = "facebook"
    case tumblr    = "tumblr"
    case scambait  = "scambait"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twitter:   return "Twitter / X"
        case .instagram: return "Instagram"
        case .tiktok:    return "TikTok"
        case .youtube:   return "YouTube"
        case .reddit:    return "Reddit"
        case .facebook:  return "Facebook"
        case .tumblr:    return "Tumblr"
        case .scambait:  return "ScamBait"
        }
    }

    var icon: String {
        switch self {
        case .twitter:   return "𝕏"
        case .instagram: return "📸"
        case .tiktok:    return "🎵"
        case .youtube:   return "▶️"
        case .reddit:    return "🤖"
        case .facebook:  return "👤"
        case .tumblr:    return "📝"
        case .scambait:  return "🛡️"
        }
    }

    var tagline: String {
        switch self {
        case .twitter:   return "Auto-post tweets, engage with animation community, surf trending topics"
        case .instagram: return "Post content, stories, reels. Engagement automation with follows/DMs/comments"
        case .tiktok:    return "TikGrow RPA automation for video posting and engagement"
        case .youtube:   return "Full channel automation — scripts, thumbnails, upload, SEO optimization"
        case .reddit:    return "Gemini-powered comment agent engaging in animation subreddits"
        case .facebook:  return "Page management, auto-post, group engagement, comment replies"
        case .tumblr:    return "Visual content posting, reblog automation, tag optimization"
        case .scambait:  return "Anti-scam bot that wastes scammers' time with AI responses"
        }
    }

    var shortDescription: String {
        switch self {
        case .twitter:   return "3-4 tweets/day + engagement"
        case .instagram: return "1 post + stories daily"
        case .tiktok:    return "1 video/day"
        case .youtube:   return "2-3 videos/week"
        case .reddit:    return "10-15 comments/day"
        case .facebook:  return "1 post/day + auto-replies"
        case .tumblr:    return "1 post/day"
        case .scambait:  return "Always-on"
        }
    }

    var credentialFields: [BotCredentialField] {
        switch self {
        case .twitter:
            return [
                BotCredentialField(key: "api_key", label: "API Key", placeholder: "Your Twitter API key..."),
                BotCredentialField(key: "api_secret", label: "API Secret", placeholder: "Your Twitter API secret..."),
                BotCredentialField(key: "access_token", label: "Access Token", placeholder: "Your access token..."),
                BotCredentialField(key: "access_token_secret", label: "Access Token Secret", placeholder: "Your access token secret..."),
            ]
        case .instagram:
            return [
                BotCredentialField(key: "username", label: "Username", placeholder: "Your Instagram username..."),
                BotCredentialField(key: "password", label: "Password", placeholder: "Your Instagram password..."),
            ]
        case .tiktok:
            return [
                BotCredentialField(key: "session_id", label: "Session ID", placeholder: "Your TikTok session cookie..."),
            ]
        case .youtube:
            return [
                BotCredentialField(key: "api_key", label: "YouTube API Key", placeholder: "Your YouTube Data API key..."),
                BotCredentialField(key: "oauth_client_id", label: "OAuth Client ID", placeholder: "Your OAuth client ID..."),
                BotCredentialField(key: "oauth_client_secret", label: "OAuth Client Secret", placeholder: "Your OAuth client secret..."),
            ]
        case .reddit:
            return [
                BotCredentialField(key: "client_id", label: "Client ID", placeholder: "Your Reddit app client ID..."),
                BotCredentialField(key: "client_secret", label: "Client Secret", placeholder: "Your Reddit app secret..."),
                BotCredentialField(key: "username", label: "Username", placeholder: "Your Reddit username..."),
                BotCredentialField(key: "password", label: "Password", placeholder: "Your Reddit password..."),
            ]
        case .facebook:
            return [
                BotCredentialField(key: "page_token", label: "Page Access Token", placeholder: "Your Facebook page token..."),
                BotCredentialField(key: "page_id", label: "Page ID", placeholder: "Your Facebook page ID..."),
            ]
        case .tumblr:
            return [
                BotCredentialField(key: "consumer_key", label: "Consumer Key", placeholder: "Your Tumblr consumer key..."),
                BotCredentialField(key: "consumer_secret", label: "Consumer Secret", placeholder: "Your Tumblr consumer secret..."),
                BotCredentialField(key: "token", label: "OAuth Token", placeholder: "Your OAuth token..."),
                BotCredentialField(key: "token_secret", label: "OAuth Token Secret", placeholder: "Your OAuth token secret..."),
            ]
        case .scambait:
            return [
                BotCredentialField(key: "bait_email", label: "Bait Email", placeholder: "The bait email address..."),
                BotCredentialField(key: "email_password", label: "Email Password", placeholder: "Email password..."),
            ]
        }
    }

    var scheduleOptions: [BotScheduleOption] {
        switch self {
        case .twitter:
            return [
                BotScheduleOption(name: "Standard", description: "4 tweets/day (9AM, 1PM, 5PM, 9PM)", cron: "0 9,13,17,21 * * *"),
                BotScheduleOption(name: "Aggressive", description: "8 tweets/day", cron: "0 8,10,12,14,16,18,20,22 * * *"),
            ]
        case .instagram:
            return [
                BotScheduleOption(name: "Standard", description: "1 post/day at 11AM", cron: "0 11 * * *"),
                BotScheduleOption(name: "With Stories", description: "1 post + 2 stories/day", cron: "0 11,15,20 * * *"),
            ]
        case .tiktok:
            return [
                BotScheduleOption(name: "Standard", description: "1 video/day at 5PM", cron: "0 17 * * *"),
                BotScheduleOption(name: "Peak Hours", description: "2 videos/day", cron: "0 12,19 * * *"),
            ]
        case .youtube:
            return [
                BotScheduleOption(name: "Standard", description: "3 videos/week (Mon/Wed/Fri 2PM)", cron: "0 14 * * 1,3,5"),
                BotScheduleOption(name: "Weekly", description: "1 video/week (Wednesday 2PM)", cron: "0 14 * * 3"),
            ]
        case .reddit:
            return [
                BotScheduleOption(name: "Standard", description: "Every 30 min during active hours", cron: "*/30 9-22 * * *"),
                BotScheduleOption(name: "Light", description: "3 engagement windows/day", cron: "0 10,14,18 * * *"),
            ]
        case .facebook:
            return [
                BotScheduleOption(name: "Standard", description: "1 post/day at 10AM", cron: "0 10 * * *"),
                BotScheduleOption(name: "Active", description: "2 posts + engagement", cron: "0 10,18 * * *"),
            ]
        case .tumblr:
            return [
                BotScheduleOption(name: "Standard", description: "1 post/day at 3PM", cron: "0 15 * * *"),
                BotScheduleOption(name: "Active", description: "2 posts/day", cron: "0 11,19 * * *"),
            ]
        case .scambait:
            return [
                BotScheduleOption(name: "Always On", description: "Check every 5 minutes", cron: "*/5 * * * *"),
                BotScheduleOption(name: "Hourly", description: "Check every hour", cron: "0 * * * *"),
            ]
        }
    }

    var botFeatures: [BotFeature] {
        switch self {
        case .twitter:
            return [
                BotFeature(name: "Auto-Tweet", description: "Post AI-generated tweets on schedule"),
                BotFeature(name: "Engagement", description: "Like and reply to animation community"),
                BotFeature(name: "Trending Surf", description: "Jump on trending topics with stick figure content"),
                BotFeature(name: "Thread Builder", description: "Create multi-tweet story threads"),
            ]
        case .instagram:
            return [
                BotFeature(name: "Auto-Post", description: "Upload and caption posts automatically"),
                BotFeature(name: "Stories", description: "Auto-generate and post stories"),
                BotFeature(name: "Engagement", description: "Like, comment, follow in niche"),
                BotFeature(name: "Hashtags", description: "AI-optimized hashtag sets"),
            ]
        case .tiktok:
            return [
                BotFeature(name: "Auto-Post Videos", description: "Upload and post videos automatically"),
                BotFeature(name: "Trending Sounds", description: "Use trending audio in posts"),
                BotFeature(name: "Hashtag Optimizer", description: "AI-selected hashtags for reach"),
                BotFeature(name: "Duet Finder", description: "Find duet opportunities"),
            ]
        case .youtube:
            return [
                BotFeature(name: "Script Generator", description: "AI-written video scripts"),
                BotFeature(name: "Thumbnail AI", description: "Auto-generate click-worthy thumbnails"),
                BotFeature(name: "SEO Optimizer", description: "Title, description, tag optimization"),
                BotFeature(name: "Auto-Upload", description: "Render and upload on schedule"),
            ]
        case .reddit:
            return [
                BotFeature(name: "Comment Agent", description: "Engage naturally in animation subreddits"),
                BotFeature(name: "Post Scheduler", description: "Share content at peak times"),
                BotFeature(name: "Karma Builder", description: "Build reputation through helpful comments"),
                BotFeature(name: "Subreddit Monitor", description: "Track mentions and discussions"),
            ]
        case .facebook:
            return [
                BotFeature(name: "Page Posts", description: "Auto-post to your Facebook page"),
                BotFeature(name: "Auto-Reply", description: "AI responses to comments and messages"),
                BotFeature(name: "Group Engagement", description: "Share content in animation groups"),
            ]
        case .tumblr:
            return [
                BotFeature(name: "Auto-Post", description: "Visual content with optimized tags"),
                BotFeature(name: "Reblog Network", description: "Auto-reblog from tracked accounts"),
                BotFeature(name: "Queue Manager", description: "Keep a steady content queue"),
            ]
        case .scambait:
            return [
                BotFeature(name: "Auto-Detect", description: "Scan emails for scam patterns"),
                BotFeature(name: "AI Responses", description: "Waste scammers' time with convincing replies"),
                BotFeature(name: "Escalation Chains", description: "Multi-step bait conversations"),
                BotFeature(name: "Report Generator", description: "Document scam attempts"),
            ]
        }
    }

    #if canImport(SwiftUI)
    var color: Color {
        switch self {
        case .twitter:   return Color(hex: "1DA1F2")
        case .instagram: return Color(hex: "E4405F")
        case .tiktok:    return Color(hex: "00F2EA")
        case .youtube:   return Color(hex: "FF0000")
        case .reddit:    return Color(hex: "FF4500")
        case .facebook:  return Color(hex: "1877F2")
        case .tumblr:    return Color(hex: "35465C")
        case .scambait:  return Color(hex: "00C853")
        }
    }
    #endif
}

// MARK: - Supporting Types

struct BotCredentialField: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let placeholder: String
}

struct BotScheduleOption: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let cron: String
}

struct BotFeature: Identifiable {
    let id = UUID()
    let name: String
    let description: String
}

// MARK: - Bot Configuration (persisted to Supabase)

struct BotConfiguration: Codable, Identifiable {
    var id: Int?
    var platform: String
    var isActive: Bool
    var credentials: [String: String]
    var selectedSchedule: String?
    var enabledFeatures: [String]
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, credentials
        case isActive = "is_active"
        case selectedSchedule = "selected_schedule"
        case enabledFeatures = "enabled_features"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Content Queue Item

enum ContentStatus: String, Codable, CaseIterable {
    case draft   = "draft"
    case queued  = "queued"
    case posted  = "posted"
    case failed  = "failed"
}

struct ContentQueueItem: Codable, Identifiable {
    let id: Int
    var platform: String
    var content: String
    var status: ContentStatus
    var scheduledAt: String?
    var postedAt: String?
    var engagement: ContentEngagement?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, platform, content, status, engagement
        case scheduledAt = "scheduled_at"
        case postedAt = "posted_at"
        case createdAt = "created_at"
    }
}

struct ContentEngagement: Codable {
    var likes: Int
    var comments: Int
    var shares: Int
    var views: Int
}

// MARK: - Platform Analytics

struct PlatformAnalytics: Identifiable {
    let id = UUID()
    var platform: BotPlatform
    var followers: Int
    var posts: Int
    var likes: Int
    var comments: Int
    var shares: Int
    var views: Int
    var engagementRate: Double // percentage
}

// MARK: - Seeded Content Queue (matches admin panel exactly)

extension ContentQueueItem {
    static let seeded: [ContentQueueItem] = [
        ContentQueueItem(
            id: 1, platform: "twitter",
            content: "POV: your stick figure just learned about gravity 💀⬇️ #StickDeath #Animation #IndieAnimation #GameDev",
            status: .queued, scheduledAt: "2026-05-25T22:57:00Z"
        ),
        ContentQueueItem(
            id: 2, platform: "tiktok",
            content: "Watch this stick figure try to survive... (spoiler: he doesn't) 💀 #StickDeath #Animation #FYP #IndieCreator",
            status: .queued, scheduledAt: "2026-05-26T00:57:00Z"
        ),
        ContentQueueItem(
            id: 3, platform: "reddit",
            content: "Just released our free stick figure animation studio — would love feedback from the community!",
            status: .draft, scheduledAt: "2026-05-26T01:57:00Z"
        ),
        ContentQueueItem(
            id: 4, platform: "youtube",
            content: "How to Animate Stick Figure Fight Scenes (Tutorial) | StickDeath ∞ Studio",
            status: .draft, scheduledAt: "2026-05-26T08:57:00Z"
        ),
        ContentQueueItem(
            id: 5, platform: "twitter",
            content: "Animation tip: the best deaths are the ones with 3+ bounces. Trust me on this one. #AnimationTips #StickDeath",
            status: .queued, scheduledAt: "2026-05-26T09:00:00Z"
        ),
        ContentQueueItem(
            id: 6, platform: "instagram",
            content: "New animation drop 🎨💀 Swipe to watch the full fight scene → #StickDeath #Animation #ArtOfTheDay",
            status: .queued, scheduledAt: "2026-05-26T11:00:00Z"
        ),
        ContentQueueItem(
            id: 7, platform: "twitter",
            content: "\"Why is your animation so violent?\" Me: *shows them stickdeath.com from 2002* 💀🔥 #Nostalgia #StickDeath",
            status: .queued, scheduledAt: "2026-05-26T13:00:00Z"
        ),
        ContentQueueItem(
            id: 8, platform: "tiktok",
            content: "POV: you just discovered you can animate your own stick figure fights for FREE 💀✨ #StickDeath #Tutorial",
            status: .queued, scheduledAt: "2026-05-26T17:00:00Z"
        ),
        ContentQueueItem(
            id: 9, platform: "twitter",
            content: "Frame 1: stick figure standing\nFrame 2: stick figure still standing\nFrame 3: CHAOS\n\nThat's how animation works. #StickDeath",
            status: .queued, scheduledAt: "2026-05-26T17:00:00Z"
        ),
        ContentQueueItem(
            id: 10, platform: "reddit",
            content: "[OC] Built a mobile animation studio that makes FlipaClip look like MS Paint — here's a demo of the frame-by-frame workflow",
            status: .draft, scheduledAt: "2026-05-26T18:00:00Z"
        ),
        ContentQueueItem(
            id: 11, platform: "facebook",
            content: "🎨 New feature alert! The StickDeath Infinity studio now has 25 drawing tools including airbrush, neon, and calligraphy pens. Try it free!",
            status: .draft, scheduledAt: "2026-05-26T10:00:00Z"
        ),
        ContentQueueItem(
            id: 12, platform: "tumblr",
            content: "the old internet remembers stickdeath.com. we're bringing it back, but this time YOU make the animations. 💀🩸",
            status: .draft, scheduledAt: "2026-05-26T15:00:00Z"
        ),
        ContentQueueItem(
            id: 13, platform: "twitter",
            content: "Every great animator started with stick figures. We just made the tools to turn those stick figures into legends. #StickDeath #IndieAnimation",
            status: .queued, scheduledAt: "2026-05-26T21:00:00Z"
        ),
        ContentQueueItem(
            id: 14, platform: "youtube",
            content: "10 Animation Tricks Pro Animators Don't Want You to Know | StickDeath ∞ Tips",
            status: .draft, scheduledAt: "2026-05-28T14:00:00Z"
        ),
        ContentQueueItem(
            id: 15, platform: "instagram",
            content: "Behind the scenes of our latest collab room session 🎬💀 4 animators, 1 canvas, pure chaos #StickDeath #CollabArt",
            status: .queued, scheduledAt: "2026-05-27T11:00:00Z"
        ),
        ContentQueueItem(
            id: 16, platform: "tiktok",
            content: "When Spatter AI suggests making your stick figure do a triple backflip into a volcano 🌋💀 #SpatterAI #StickDeath",
            status: .queued, scheduledAt: "2026-05-27T17:00:00Z"
        ),
        ContentQueueItem(
            id: 17, platform: "twitter",
            content: "Our AI (Spatter 💀) just roasted a user's animation so hard they re-did the whole thing. It turned out incredible. AI coaching works. #StickDeath",
            status: .queued, scheduledAt: "2026-05-27T09:00:00Z"
        ),
        ContentQueueItem(
            id: 18, platform: "reddit",
            content: "I built an AI animation assistant that gives feedback like a sarcastic art director — and it actually makes your animations better",
            status: .draft, scheduledAt: "2026-05-27T14:00:00Z"
        ),
        ContentQueueItem(
            id: 19, platform: "twitter",
            content: "The most satisfying thing in animation: when the ragdoll physics hit *just right* 💀✨ #StickDeath #AnimationSatisfying",
            status: .queued, scheduledAt: "2026-05-27T17:00:00Z"
        ),
    ]
}
