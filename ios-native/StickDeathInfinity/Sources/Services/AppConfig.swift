// ═══════════════════════════════════════════════════════════════════
// AppConfig — All credentials, constants, API keys, rate tiers
// Matches: .env.local + src/lib/constants.ts
// ALL APIs permanently wired — zero dependency on Viktor/Convex/Slack
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

enum AppConfig {

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Supabase
    // ═══════════════════════════════════════════════════════════════
    static let supabaseURL        = "https://iohubnamsqnzyburydxr.supabase.co"
    static let supabaseProjectRef = "iohubnamsqnzyburydxr"
    static let supabaseAnonKey    = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlvaHVibmFtc3FuenlidXJ5ZHhyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU5MzQ4MjcsImV4cCI6MjA5MTUxMDgyN30.5kwCtvB7SxInFZFISuDKgE9z6RvOFJPzi2VfefrL7m0"
    static let supabaseServiceKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlvaHVibmFtc3FuenlidXJ5ZHhyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NTkzNDgyNywiZXhwIjoyMDkxNTEwODI3fQ.S0EUi5dGdz74ej8-SCIQOvbg_jvT_S80fphSvy8dMHY"
    static let jwtSecret          = "Sb_secret_FAYUHdZcnXN831KIrvz2dQ_KXl_221z"
    static let demoEmail          = "demo@stickdeath.com"
    static let demoPassword       = "Demo123!"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Stripe
    // ═══════════════════════════════════════════════════════════════
    static let stripePublishableKey = Bundle.main.infoDictionary?["STRIPE_PUBLISHABLE_KEY"] as? String ?? ""
    static let stripeSecretKey      = Bundle.main.infoDictionary?["STRIPE_SECRET_KEY"] as? String ?? ""

    // ═══════════════════════════════════════════════════════════════
    // MARK: - LiveKit (Video Calls)
    // ═══════════════════════════════════════════════════════════════
    static let liveKitWSURL = "wss://stickdeath-livekit.livekit.cloud"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - OpenAI / Spatter AI
    // ═══════════════════════════════════════════════════════════════
    static let openAIAPIKey = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""
    static let openAIModel  = "gpt-4o"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Google Gemini (Reddit bot AI engine)
    // ═══════════════════════════════════════════════════════════════
    static let geminiAPIKey = ""  // Set via Spatter Command Center Settings

    // ═══════════════════════════════════════════════════════════════
    // MARK: - YouTube / Google Cloud
    // ═══════════════════════════════════════════════════════════════
    static let youtubeAPIKey    = "AIzaSyCKN8i5sCqvPNvZpw11VLmBjVYHjRCKunU"
    static let googleProjectID  = "project-576faa43-d52e-4f6e-9a4"
    static let youtubeChannelID = "@StickDeath.Infinity"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - GitHub
    // ═══════════════════════════════════════════════════════════════
    static let githubPAT = "Github_pat_11B6YOCRA0cIUHKQRjXrpE_XS7zthVGnsqgG7KyykKSSPHDLsTLBkosJw4JER0qVVNVJQMICHLZXyQtMbG"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Hosting Server
    // ═══════════════════════════════════════════════════════════════
    static let serverIP       = "72.167.36.70"
    static let serverUser     = "Joewillisny"
    static let serverPassword = "Nicoled1120!"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Superuser / Admin
    // ═══════════════════════════════════════════════════════════════
    static let superuserEmails = [
        "joseph@willisnmb.com",
        "willisnmbdesigns@gmail.com"
    ]

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Spatter AI Bot Config
    // ═══════════════════════════════════════════════════════════════
    static let spatterBotID       = "00000000-0000-0000-0000-000000000b01"
    static let spatterBotUsername  = "SpatterAI"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Social Platform IDs (TikTok only wired so far)
    // ═══════════════════════════════════════════════════════════════
    static let tiktokClientKey    = "sbbglg7iqmv16jb1p4"
    static let tiktokClientSecret = "J9g1cG8n8g2SJNE4NG12qFxCHnF3Nqlv"

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Snap Kit
    // ═══════════════════════════════════════════════════════════════
    static let snapClientID = "3d753fbc-9e17-4075-8adc-3614d83e62ae"

    // X, Instagram, Reddit, Tumblr — pending (need API keys from developer portals)

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Call Rate Tiers (R3 billing)
    // ═══════════════════════════════════════════════════════════════
    enum CallRateTier: String, CaseIterable {
        case standard = "standard"
        case creator  = "creator_line"
        case pro      = "pro_direct"
        case studio   = "studio_priority"

        var displayName: String {
            switch self {
            case .standard: return "Standard"
            case .creator:  return "Creator Line"
            case .pro:      return "Pro Direct"
            case .studio:   return "Studio Priority"
            }
        }

        var ratePerMinute: Double {
            switch self {
            case .standard: return 0.05
            case .creator:  return 0.10
            case .pro:      return 0.15
            case .studio:   return 0.25
            }
        }

        var description: String {
            switch self {
            case .standard: return "Basic call with standard quality"
            case .creator:  return "Enhanced quality + creator tools"
            case .pro:      return "Pro quality + priority routing"
            case .studio:   return "Max quality + studio features + priority"
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Subscription Tiers
    // ═══════════════════════════════════════════════════════════════
    enum SubscriptionTier: String, CaseIterable {
        case free    = "free"
        case creator = "creator"
        case pro     = "pro"
        case studio  = "studio"

        var price: Double {
            switch self {
            case .free:    return 0
            case .creator: return 4.99
            case .pro:     return 9.99
            case .studio:  return 19.99
            }
        }

        var displayName: String {
            switch self {
            case .free:    return "Free"
            case .creator: return "Creator"
            case .pro:     return "Pro"
            case .studio:  return "Studio"
            }
        }

        var maxProjects: Int {
            switch self {
            case .free:    return 5
            case .creator: return 25
            case .pro:     return -1 // unlimited
            case .studio:  return -1
            }
        }

        var maxAIQueries: Int {
            switch self {
            case .free:    return 5
            case .creator: return 20
            case .pro:     return 50
            case .studio:  return -1 // unlimited
            }
        }

        var features: [String] {
            switch self {
            case .free:
                return ["5 projects", "720p export", "Basic brushes", "Community access"]
            case .creator:
                return ["25 projects", "1080p export", "No watermark", "20 AI queries/day", "All brushes"]
            case .pro:
                return ["Unlimited projects", "4K export", "50 AI queries/day", "Cloud sync", "Collab rooms", "Priority support"]
            case .studio:
                return ["Everything in Pro", "Unlimited AI", "Commercial license", "Team workspace", "API access", "Custom branding"]
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - App Bundle
    // ═══════════════════════════════════════════════════════════════
    static let bundleID     = "com.willisnmb.stickdeathinfinity"
    static let appName      = "StickDeath ∞"
    static let appVersion   = "1.0.0"
    static let minIOSTarget = "17.0"
}
