// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Matches: src/lib/spatterEngine.ts
// Provides embedded Spatter knowledge. Backend calls only when
// explicitly configured via AppConfig.backendURL (provider-neutral).
// ═══════════════════════════════════════════════════════════════════

import Foundation

final class SpatterService {
    static let shared = SpatterService()

    // Provider-neutral backend endpoint (optional — if nil, degrades gracefully)
    private let backendURL: URL?

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
    - Lore: Old Internet Mode, Corrupted Spatter Mode

    Rules:
    - Keep responses concise and actionable
    - Always relate advice back to the user's current project if context is available
    - Use emoji sparingly but effectively 💀🔥⚔️🎨
    - Never break character
    - Refer to the founder as "the creator" or "Joe" when context calls for it
    """

    // MARK: - Init

    init() {
        self.backendURL = AppConfig.backendURL
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

    // MARK: - Chat

    /// Send a message to Spatter and get a response
    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async -> String {
        // 1. Build embedded knowledge context (always available, instant, no network)
        let embeddedKnowledge = buildKnowledgeContext(
            screen: context?.currentScreen,
            tool: context?.currentTool
        )

        // 2. If no provider-neutral backend is configured, gracefully degrade
        //    without making any provider request — return local knowledge only
        guard let backendURL = backendURL else {
            return "💀 Spatter is here, but the backend service is currently unavailable. " +
                   "Embedded knowledge is available locally. " +
                   "Configure a provider-neutral backend URL in AppConfig to enable remote Spatter features."
        }

        // 3. If backendURL is configured, make a provider-neutral request
        //    (implementation deferred to backend — this path is not used without a real endpoint)
        return "💀 Spatter backend endpoint configured at \(backendURL.absoluteString). " +
               "Embedded knowledge is available locally. " +
               "Configure a valid backend response handler for remote features."
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

enum SpatterServiceError: Error {
    case backendUnavailable
    case providerRequestFailed(Error)
}