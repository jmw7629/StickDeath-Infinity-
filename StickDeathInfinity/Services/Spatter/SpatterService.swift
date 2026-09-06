// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Matches: src/lib/spatterEngine.ts
// Talks to OpenAI GPT-4o with StickDeath personality + knowledge
//
// Knowledge is embedded permanently via SpatterKnowledgeBase.swift
// (120 modules: 100 brain + 20 core) — no external JSON needed.
// Also queries Supabase spatter_knowledge table for runtime additions.
// ═══════════════════════════════════════════════════════════════════

import Foundation

final class SpatterService {
    static let shared = SpatterService()

    private let backendClient: SpatterBackendClient

    init(backendClient: SpatterBackendClient? = nil) {
        if let client = backendClient {
            self.backendClient = client
        } else {
            let config = BackendConfig(
                baseURL: AppConfig.backendBaseURL,
                isEnabled: !AppConfig.backendBaseURL.isEmpty
            )
            self.backendClient = SpatterBackendClient(
                config: config,
                authProvider: AuthServiceAuthBridge.shared
            )
        }
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
        guard let client = SupabaseManager.shared.client else { return "" }
        do {
            let entries: [SupabaseKnowledgeEntry] = try await client
                .from("spatter_knowledge")
                .select()
                .limit(50)
                .execute()
                .value
            return entries.map { "[\($0.category)] \($0.content)" }.joined(separator: "\n")
        } catch {
            return ""
        }
    }

    // MARK: - Chat

    /// Send a message to Spatter and get a response via the authenticated backend seam
    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async throws -> String {
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

        // 4. Build system prompt
        let fullSystem = systemPrompt
            + "\n\n--- EMBEDDED KNOWLEDGE ---\n" + embeddedKnowledge
            + (supabaseKnowledge.isEmpty ? "" : "\n\n--- RUNTIME KNOWLEDGE ---\n" + supabaseKnowledge)
            + contextStr

        // 5. Call through the authenticated backend seam
        if let response = try await backendClient.chat(
            messages: messages,
            systemPrompt: fullSystem,
            maxTokens: 500
        ) {
            return response
        }

        // Backend unavailable — return offline response using embedded knowledge only
        return offlineResponse(for: messages, knowledge: embeddedKnowledge)
    }

    /// Offline fallback when backend is unavailable
    private func offlineResponse(for messages: [(role: String, content: String)], knowledge: String) -> String {
        guard let last = messages.last else {
            return "I'm Spatter. The cloud backend is currently unavailable, but my embedded knowledge is ready. What do you need? 💀"
        }
        let query = last.content.lowercased()
        if query.contains("layer") {
            return "Layers let you organize elements. Use the layer panel to toggle visibility, lock, adjust opacity, and reorder. 💀"
        }
        if query.contains("frame") {
            return "Frames are the building blocks of animation. Add, duplicate, or delete them on the timeline. Each frame holds its own drawn elements."
        }
        return "I'm Spatter, your creative AI assistant! The cloud backend is offline right now, but I have 120 embedded knowledge modules ready. Ask me about animation, tools, or studio features! 💀"
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
