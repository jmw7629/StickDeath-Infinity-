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
        if messages.isEmpty { return "Ready to create" }
        return "Online"
    }

    func sendMessage(_ content: String) async {
        let userMsg = SpatterMessage(id: UUID().uuidString, role: .user, content: content, timestamp: Date())
        messages.append(userMsg)
        isThinking = true

        // TODO: Connect to Spatter AI backend
        let reply = SpatterMessage(id: UUID().uuidString, role: .assistant, content: "I'm Spatter, your creative AI assistant! 🎨", timestamp: Date())
        messages.append(reply)
        isThinking = false
    }

    func toggleOrb() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isOrbVisible.toggle()
        }
    }
}
