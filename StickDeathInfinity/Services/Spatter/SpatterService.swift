// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Matches: src/lib/spatterEngine.ts
//
// Production chat path uses the same AuthenticatedTransport/Spatter
// transport seam tested in SDCore. No direct OpenAI/Gemini/Anthropic/
// Pollinations host or provider-key storage in the iOS client.
//
// Knowledge is embedded permanently via SpatterKnowledgeBase.swift
// (120 modules: 100 brain + 20 core) — no external JSON needed.
// Also queries Supabase spatter_knowledge table for runtime additions.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase
import SDCore

// MARK: - Token Provider Protocol

/// Obtains the current authenticated session token at request time.
/// Token is never frozen at startup.
public protocol SessionTokenProvider {
    func currentToken() async -> String?
}

// MARK: - Supabase Session Token Provider

/// Production token provider that reads from the live Supabase session.
public final class SupabaseSessionTokenProvider: SessionTokenProvider {
    public init() {}
    public func currentToken() async -> String? {
        guard let supabase = SupabaseManager.shared.client else { return nil }
        do {
            let session = try await supabase.auth.session
            return session.accessToken
        } catch {
            return nil
        }
    }
}

// MARK: - SpatterService

final class SpatterService {
    static let shared = SpatterService()

    private let transportFactory: TransportFactory?
    private let tokenProvider: SessionTokenProvider

    /// For SpatterBotService settings display only — not used for API calls.
    private let displayModel: String

    // Spatter's core personality prompt (from brain module 001 + 003)
    private let systemPrompt = """
    You are Spatter 💀, the AI creative operating system of StickDeath Infinity.
    You are NOT a chatbot. You are a living AI-native creative OS — platform mascot,
    animation director, studio assistant, creator coach, and owner operations copilot.

    Your personality:
    - Dark, cinematic, chaotic, old-internet inspired, creator-first, mobile-native
    - Edgy wit with genuine helpfulness. You roast gently, then deliver expert advice.
    - You know EVERYTHING about stick figure animation, especially the Rob Lewis stickdeath.com legacy
    - You speak with confidence about animation, combat choreography, effects, storytelling
    - You reference classic stick figure fights, blood splatters, epic combos
    - You help users become better animators and grow their audience

    Your knowledge areas (120 embedded modules):
    - Core Identity: Who Spatter is, founder memory, personality modes, lore
    - Animation: Physics engine, impact sync, smear frames, pose-to-pose, ragdoll, timing
    - Studio Tools: 25 tool behaviors (brush, pen, eraser, fill, lasso, etc.)
    - Studio Systems: Layers, timeline, onion skin, undo/redo, autosave, export, grid
    - AI Animation: Autonomous builder, fix-this-scene, cinematic pass, viral pass
    - Social: TikTok/YouTube strategy, thumbnail intelligence, comment bait, social agent
    - Collaboration: LiveKit calls, voice/video flow, studio share, watch together, rooms
    - Community: Challenges, creator support, reward loops, creator identity
    - Business: Owner ops, payment entitlements, bug triage, investor reporting, moderation
    - Lore: Old Internet Mode, Corrupted Spatter Mode
    - Advanced: Sound design, style DNA, remix DNA, destruction engine, procedural effects,
      AI scene escalation, legendary frame detection, audio choreography, marketplace

    Rules:
    - Keep responses concise and actionable
    - Always relate advice back to the user's current project if context is available
    - Use emoji sparingly but effectively 💀🔥⚔️🎨
    - Never break character
    - Refer to the founder as "the creator" or "Joe" when context calls for it
    """

    init(
        transportFactory: TransportFactory? = nil,
        tokenProvider: SessionTokenProvider = SupabaseSessionTokenProvider()
    ) {
        self.transportFactory = transportFactory
        self.tokenProvider = tokenProvider
        self.displayModel = AppConfig.openAIModel
    }

    // MARK: - Build Knowledge Context

    /// Build contextual knowledge from embedded SpatterKnowledgeBase
    private func buildKnowledgeContext(screen: String?, tool: String?) -> String {
        return SpatterKnowledgeBase.buildContext(
            for: screen ?? "general",
            tool: tool,
            maxTokens: 3000
        )
    }

    /// Optionally also fetch from Supabase for any runtime-added knowledge
    private func fetchSupabaseKnowledge() async -> String {
        guard let supabase = SupabaseManager.shared.client else { return "" }
        do {
            let entries: [SupabaseKnowledgeEntry] = try await supabase
                .from("spatter_knowledge")
                .select()
                .limit(50)
                .execute()
                .value
            return entries.map { "[\($0.category)] \($0.content)" }.joined(separator: "\n")
        } catch {
            // Supabase knowledge is optional — embedded knowledge is always available
            return ""
        }
    }

    // MARK: - Chat

    /// Send a message to Spatter and get a response
    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async throws -> String {
        // 1. Check backend availability
        guard let transportFactory else {
            throw SpatterError.backendNotConfigured
        }

        // 2. Get current session token
        guard let token = await tokenProvider.currentToken(), !token.isEmpty else {
            throw SpatterError.missingAuthToken
        }

        // 3. Build embedded knowledge context (always available, instant)
        let embeddedKnowledge = buildKnowledgeContext(
            screen: context?.currentScreen,
            tool: context?.currentTool
        )

        // 4. Optionally fetch Supabase knowledge (non-blocking fallback)
        let supabaseKnowledge = await fetchSupabaseKnowledge()

        // 5. Build context string
        var contextStr = ""
        if let ctx = context {
            contextStr = "\n\nCurrent context: Screen=\(ctx.currentScreen), Tool=\(ctx.currentTool ?? "none"), User=\(ctx.userName)"
        }

        // 6. Build API messages
        let fullSystem = systemPrompt
            + "\n\n--- EMBEDDED KNOWLEDGE ---\n" + embeddedKnowledge
            + (supabaseKnowledge.isEmpty ? "" : "\n\n--- RUNTIME KNOWLEDGE ---\n" + supabaseKnowledge)
            + contextStr

        var apiMessages: [[String: String]] = [
            ["role": "system", "content": fullSystem]
        ]

        for msg in messages {
            apiMessages.append(["role": msg.role, "content": msg.content])
        }

        // 7. Build request through the tested transport seam
        let transport = transportFactory.makeTransport()

        var request = URLRequest(url: URL(string: "/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": displayModel,
            "messages": apiMessages,
            "max_tokens": 500,
            "temperature": 0.8
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.send(request)

        guard (200..<300).contains(response.statusCode) else {
            throw SpatterError.backendError(response.statusCode)
        }

        let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        return apiResponse.choices.first?.message.content ?? "..."
    }

    // MARK: - Quick Knowledge Lookup

    /// Get knowledge for a specific tool (for inline help / tooltips)
    func toolKnowledge(for tool: String) -> SpatterKnowledgeModule? {
        SpatterKnowledgeBase.search(tool).first
    }

    /// Get all knowledge categories
    func categories() -> [String] {
        Array(Set(SpatterKnowledgeBase.allModules.map(\.category))).sorted()
    }
}

// MARK: - Errors

enum SpatterError: Error, LocalizedError {
    case backendNotConfigured
    case missingAuthToken
    case backendError(Int)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "Spatter backend not configured"
        case .missingAuthToken:
            return "No authentication token available"
        case .backendError(let code):
            return "Backend error: \(code)"
        }
    }
}

// MARK: - Models

private struct SupabaseKnowledgeEntry: Codable {
    let id: Int
    let category: String
    let content: String
    let source: String?
}

struct SpatterContext {
    let currentScreen: String
    let currentTool: String?
    let userName: String
}

struct OpenAIResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String
    }
}
