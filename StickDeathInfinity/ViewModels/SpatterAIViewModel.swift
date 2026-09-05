// ═══════════════════════════════════════════════════════════════════
// SpatterAIViewModel — Spatter AI context
// Matches: src/contexts/SpatterAIContext.tsx
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@MainActor
final class SpatterAIViewModel: ObservableObject {
    @Published var isOrbVisible = false
    @Published var isExpanded = false
    @Published var messages: [SpatterMessage] = []
    @Published var isThinking = false

    var statusText: String {
        if isThinking { return "Thinking…" }
        if !SpatterService.shared.isCloudAvailable {
            return "Cloud AI unavailable — local knowledge only"
        }
        if messages.isEmpty { return "Ready to create" }
        return "Online"
    }

    func sendMessage(_ content: String) async {
        let userMsg = SpatterMessage(id: UUID().uuidString, role: .user, content: content, timestamp: Date())
        messages.append(userMsg)
        isThinking = true

        do {
            let reply = try await SpatterService.shared.chat(
                messages: messages.map { (role: $0.role == .user ? "user" : "assistant", content: $0.content) }
            )
            let replyMsg = SpatterMessage(id: UUID().uuidString, role: .assistant, content: reply, timestamp: Date())
            messages.append(replyMsg)
        } catch {
            let errorMsg = SpatterMessage(
                id: UUID().uuidString, role: .assistant,
                content: "Connection error. Check your internet and try again.",
                timestamp: Date()
            )
            messages.append(errorMsg)
        }

        isThinking = false
    }

    func toggleOrb() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isOrbVisible.toggle()
        }
    }
}
