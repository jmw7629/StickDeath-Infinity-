// ═══════════════════════════════════════════════════════════════════
// OfflineSpatterProvider — Local/embedded Spatter AI provider
// Uses SpatterKnowledgeBase + SpatterBrainLoader for offline responses.
// No network calls. No API keys. No secrets.
// ═══════════════════════════════════════════════════════════════════

import Foundation

final class OfflineSpatterProvider: SpatterAIProvider {

    static let shared = OfflineSpatterProvider()

    var isAvailable: Bool { true }
    var providerName: String { "Spatter Offline" }

    func chat(
        messages: [SpatterChatMessage],
        context: SpatterStudioContext?,
        tools: [SpatterToolDefinition]?
    ) async throws -> SpatterResponse {
        guard let lastMessage = messages.last else {
            return SpatterResponse(text: "Ask me anything about animation or your Studio project.", toolCalls: [], providerName: providerName, modelID: nil, finishReason: "stop")
        }

        let query = lastMessage.content
        let screen = context?.navigation.currentScreen ?? "general"
        let tool = context?.tool.selectedTool

        // 1. Check for "how do I" questions
        if query.lowercased().hasPrefix("how do i") || query.lowercased().hasPrefix("how to") {
            if let answer = SpatterCapabilityRegistry.answerHowTo(query) {
                return SpatterResponse(text: answer, toolCalls: [], providerName: providerName, modelID: nil, finishReason: "stop")
            }
        }

        // 2. Try knowledge base
        let knowledgeContext = SpatterKnowledgeBase.buildContext(for: screen, tool: tool, maxTokens: 2000)
        let brainContext = SpatterBrainLoader.shared.contextFor(query: query, maxTokens: 1500)

        // 3. Check for local deterministic commands
        if let localResponse = handleLocalCommand(query: query, context: context) {
            return SpatterResponse(text: localResponse, toolCalls: [], providerName: providerName, modelID: nil, finishReason: "stop")
        }

        // 4. Build embedded response
        let personality = buildOfflineResponse(query: query, knowledge: knowledgeContext + "\n" + brainContext, context: context)
        return SpatterResponse(text: personality, toolCalls: [], providerName: providerName, modelID: "offline-embedded", finishReason: "stop")
    }

    func streamChat(
        messages: [SpatterChatMessage],
        context: SpatterStudioContext?,
        tools: [SpatterToolDefinition]?,
        onToken: @escaping (String) -> Void
    ) async throws -> SpatterResponse {
        let response = try await chat(messages: messages, context: context, tools: tools)
        // Simulate streaming by yielding the full response
        if let text = response.text {
            let words = text.split(separator: " ")
            for word in words {
                onToken(String(word) + " ")
                try await Task.sleep(nanoseconds: 15_000_000) // 15ms per word
            }
        }
        return response
    }

    // MARK: - Local Deterministic Commands

    private func handleLocalCommand(query: String, context: SpatterStudioContext?) -> String? {
        let q = query.lowercased()

        if q.contains("how many frames") || q.contains("total frames") {
            guard let ctx = context else { return nil }
            return "You have **\(ctx.timeline.totalFrames)** frames in your timeline. Current frame: \(ctx.timeline.currentFrameIndex + 1)."
        }

        if q.contains("what tool") || q.contains("current tool") {
            guard let ctx = context else { return nil }
            return "You're currently using the **\(ctx.tool.selectedTool)** tool with width \(String(format: "%.1f", ctx.tool.strokeWidth)) and opacity \(Int(ctx.tool.strokeOpacity * 100))%."
        }

        if q.contains("layers") && (q.contains("how many") || q.contains("list")) {
            guard let ctx = context else { return nil }
            let names = ctx.layers.map { $0.name }.joined(separator: ", ")
            return "You have **\(ctx.layers.count)** layer(s): \(names)."
        }

        if q.contains("canvas size") || q.contains("resolution") {
            guard let ctx = context else { return nil }
            return "Canvas is **\(ctx.canvas.width)×\(ctx.canvas.height)** at **\(ctx.canvas.fps)** FPS."
        }

        if q.contains("project name") || q.contains("what project") {
            guard let ctx = context else { return nil }
            return "Current project: **\(ctx.project.name)**."
        }

        if q.contains("colors") || q.contains("current color") {
            guard let ctx = context else { return nil }
            return "Stroke color: **\(ctx.colors.strokeColorHex)**. Grid: \(ctx.canvas.gridEnabled ? "on" : "off")."
        }

        if q.contains("export") || q.contains("how do i export") {
            guard let ctx = context else { return nil }
            return "Export format: **\(ctx.export.format)** at **\(ctx.export.quality)** quality. Tap the export button in the header bar to start exporting."
        }

        if q.contains("play") || q.contains("playback") {
            guard let ctx = context else { return nil }
            return ctx.timeline.isPlaying ? "Animation is **playing** at \(ctx.canvas.fps) FPS." : "Animation is **paused**. Tap play to preview."
        }

        return nil
    }

    // MARK: - Offline Response Builder

    private func buildOfflineResponse(query: String, knowledge: String, context: SpatterStudioContext?) -> String {
        let hasContext = context != nil
        var response = ""

        if hasContext {
            response += "💡 *Offline mode — embedded knowledge*\n\n"
        }

        // Find relevant knowledge
        let relevantModules = SpatterKnowledgeBase.search(query)
        if let best = relevantModules.first {
            response += "**\(best.title)**\n\(best.knowledge.joined(separator: ". "))\n\n"
            if let tip = relevantModules.dropFirst().first {
                response += "*Related: \(tip.title)* — \(tip.summary)"
            }
        } else {
            response += "I'm Spatter 💀, your animation AI. I'm currently offline, but I can still help with:\n\n"
            response += "• **Frame count & project info** — Ask \"how many frames?\"\n"
            response += "• **Tool info** — Ask \"what tool am I using?\"\n"
            response += "• **Layer info** — Ask \"list my layers\"\n"
            response += "• **Animation tips** — Ask about any animation technique\n"
            response += "• **How do I...?** — I know all Studio controls\n\n"
            response += "Connect to the internet for full AI capabilities."
        }

        return response
    }
}
