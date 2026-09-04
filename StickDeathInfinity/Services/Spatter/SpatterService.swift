// ═══════════════════════════════════════════════════════════════════
// SpatterService — Spatter AI backend service
// Matches: src/lib/spatterEngine.ts
// Talks to server-side AI proxy — no client-side API keys.
//
// Knowledge is embedded permanently via SpatterKnowledgeBase.swift
// (120 modules: 100 brain + 20 core) — no external JSON needed.
// Also queries Supabase spatter_knowledge table for runtime additions.
// ═══════════════════════════════════════════════════════════════════

import Foundation
import Supabase

final class SpatterService {
    static let shared = SpatterService()

    // No API keys in client — all AI calls go through server-side proxy
    private let endpoint = URL(string: "https://api.stickdeath.com/functions/v1/spatter-chat")!

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

    Rules:
    - Keep responses concise and actionable
    - Always relate advice back to the user's current project if context is available
    - Use emoji sparingly but effectively 💀🔥⚔️🎨
    - Never break character
    - Refer to the founder as "the creator" or "Joe" when context calls for it
    """

    // MARK: - Build Knowledge Context

    private func buildKnowledgeContext(screen: String?, tool: String?) -> String {
        return SpatterKnowledgeBase.buildContext(
            for: screen ?? "general",
            tool: tool,
            maxTokens: 3000
        )
    }

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
            return ""
        }
    }

    // MARK: - Chat (via server-side proxy)

    func chat(
        messages: [(role: String, content: String)],
        context: SpatterContext? = nil
    ) async throws -> String {
        let embeddedKnowledge = buildKnowledgeContext(
            screen: context?.currentScreen,
            tool: context?.currentTool
        )

        let supabaseKnowledge = await fetchSupabaseKnowledge()

        var contextStr = ""
        if let ctx = context {
            contextStr = "\n\nCurrent context: Screen=\(ctx.currentScreen), Tool=\(ctx.currentTool ?? "none"), User=\(ctx.userName)"
        }

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

        // Call server-side AI proxy (no client API keys)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "messages": apiMessages,
            "max_tokens": 500,
            "temperature": 0.8
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ServerAIResponse.self, from: data)

        return response.choices.first?.message.content ?? "..."
    }

    // MARK: - Quick Knowledge Lookup

    func toolKnowledge(for tool: String) -> SpatterKnowledgeModule? {
        SpatterKnowledgeBase.search(tool).first
    }

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

struct ServerAIResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String
    }
}
