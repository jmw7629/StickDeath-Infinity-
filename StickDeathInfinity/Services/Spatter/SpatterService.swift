// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Matches: src/lib/spatterEngine.ts
// Talks to provider-neutral backend with StickDeath personality + knowledge
//
// Knowledge is embedded permanently via SpatterKnowledgeBase.swift
// (120 modules: 100 brain + 20 core) — no external JSON needed.
// Also queries Supabase spatter_knowledge table for runtime additions.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

@MainActor
final class SpatterService {
    static let shared = SpatterService()

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
    - Collaboration: invitation-based Studio project rooms, Watch Together and Calendar; no chat or calls
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

    /// Send a message to Spatter and get a response (reply text only).
    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async throws -> String {
        try await chatReply(messages: messages, context: context).reply
    }

    /// The historical personality literal above is pinned by a source gate and
    /// still names retired collaboration features. The composed prompt that
    /// actually reaches the backend is built by SpatterCloudPrompt, which removes
    /// retired messaging/call lines; see Tests/SpatterConversation for the check.
    func chatReply(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil,
        suggestedPromptID: String? = nil,
        ownKeyEligible: Bool = false
    ) async throws -> SpatterCloudReply {
        guard AppConfig.backendURL != nil else { throw SpatterClientError.notConfigured }
        let supabase = try SupabaseManager.shared.client
        // Obtain an SDK-managed authenticated session before any optional knowledge request.
        guard let sessionToken = try? await supabase.auth.session.accessToken,
              !sessionToken.isEmpty else { throw SpatterClientError.notAuthenticated }
        // Own AI key (Creator/Pro, owner decision 2026-10-14): only when the server
        // last reported a paid plan and this account saved a key on this device.
        var ownKey: SpatterOwnKeyCredential?
        if ownKeyEligible, let account = try? await supabase.auth.session.user.id.uuidString.lowercased() {
            ownKey = (try? Self.ownKeyStore.load(account: account)) ?? nil
        }
        try Task.checkCancellation()

        let embeddedKnowledge = buildKnowledgeContext(
            screen: context?.currentScreen, tool: context?.currentTool
        )
        let supabaseKnowledge = await fetchSupabaseKnowledge()
        let fullSystem = SpatterCloudPrompt.compose(
            personality: systemPrompt, embeddedKnowledge: embeddedKnowledge, runtimeKnowledge: supabaseKnowledge,
            contextSummary: try context?.promptSummary(), capabilities: SpatterAIViewModel.currentStudioCapabilities)
        var apiMessages = [SpatterChatMessage(role: .system, content: fullSystem)]
        for message in messages.suffix(20) {
            guard let role = SpatterChatMessage.Role(rawValue: message.role), role != .system else {
                throw SpatterClientError.invalidRequest
            }
            apiMessages.append(SpatterChatMessage(role: role, content: message.content))
        }
        if let ownKey {
            // Device-to-provider with the member's key; the backend never sees it
            // and the prompt does not count against the plan allowance.
            let current = try await SupabaseManager.shared.client.auth.session.accessToken
            guard current == sessionToken else { throw SpatterClientError.notAuthenticated }
            return try await SpatterDirectProviderClient().complete(messages: apiMessages, credential: ownKey)
        }
        let client = SpatterBackendClient(sessionToken: {
            // Refuse an account/session change while optional knowledge was loading.
            let current = try await SupabaseManager.shared.client.auth.session.accessToken
            guard current == sessionToken else { throw SpatterClientError.notAuthenticated }
            return current
        })
        return try await client.completeReply(messages: apiMessages, suggestedPromptID: suggestedPromptID)
    }

    /// Device-only own-key storage (Keychain, this device only, never synced).
    static let ownKeyStore: SpatterOwnKeyStore = KeychainSpatterOwnKeyStore()

    /// The signed-in account's Spatter allowance as the server reports it
    /// (`public.sdi_spatter_my_usage`). The device never counts prompts itself.
    func myUsage() async throws -> SpatterAllowance {
        guard AppConfig.backendURL != nil else { throw SpatterClientError.notConfigured }
        let supabase = try SupabaseManager.shared.client
        guard let token = try? await supabase.auth.session.accessToken, !token.isEmpty else {
            throw SpatterClientError.notAuthenticated
        }
        let response = try await supabase.rpc("sdi_spatter_my_usage").execute()
        return try SpatterAllowance.decodeUsage(response.data)
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

// The default app integration is kept outside the injectable coordinator so its
// actual production behavior can be tested without an SDK or network substitute.
extension SpatterAIViewModel {
    convenience init() {
        self.init(promptResponder: { request in
            try await SpatterService.shared.chatReply(
                messages: request.messages.map { (role: $0.role.rawValue, content: $0.content) }, context: request.context,
                suggestedPromptID: request.suggestedPromptID, ownKeyEligible: request.ownKeyEligible)
        }, usageLoader: { try await SpatterService.shared.myUsage() })
    }
}
