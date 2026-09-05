// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Matches: src/lib/spatterEngine.ts
//
// Uses a configurable public backend endpoint (no provider secrets).
// If no backend endpoint is configured, reports cloud-unavailable state
// and falls back to embedded knowledge only.
//
// Knowledge is embedded permanently via SpatterKnowledgeBase.swift
// (120 modules: 100 brain + 20 core) — no external JSON needed.
// Also queries Supabase spatter_knowledge table for runtime additions.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

final class SpatterService {
    static let shared = SpatterService()

    /// Whether the cloud AI backend is configured and available.
    var isCloudAvailable: Bool {
        guard let endpoint = backendURL else { return false }
        return !endpoint.absoluteString.isEmpty
    }

    private var backendURL: URL? {
        guard let urlString = AppConfig.spatterBackendEndpoint,
              !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

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
        do {
            let entries: [SupabaseKnowledgeEntry] = try await SupabaseManager.shared.client
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

    /// Send a message to Spatter and get a response.
    /// If no backend is configured, returns an explicit cloud-unavailable state.
    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async throws -> String {
        guard let backendURL else {
            throw SpatterError.cloudUnavailable
        }

        // 1. Build embedded knowledge context (always available, instant)
        let embeddedKnowledge = buildKnowledgeContext(
            screen: context?.currentScreen,
            tool: context?.currentTool
        )

        // 2. Optionally fetch Supabase knowledge (non-blocking fallback)
        let supabaseKnowledge = await fetchSupabaseKnowledge()

        // 3. Build context string
        var contextStr = ""
        if let ctx = context {
            contextStr = "\n\nCurrent context: Screen=\(ctx.currentScreen), Tool=\(ctx.currentTool ?? "none"), User=\(ctx.userName)"
        }

        // 4. Build API messages
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

        // 5. Call configurable backend endpoint (no provider secret in client)
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "messages": apiMessages,
            "max_tokens": 500,
            "temperature": 0.8
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(BackendResponse.self, from: data)

        return response.choices.first?.message.content ?? "..."
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

struct BackendResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String
    }
}

enum SpatterError: LocalizedError {
    case cloudUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            return "Cloud AI is not available. Using embedded knowledge only."
        }
    }
}
