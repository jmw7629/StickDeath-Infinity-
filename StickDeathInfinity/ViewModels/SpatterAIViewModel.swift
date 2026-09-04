// ═══════════════════════════════════════════════════════════════════
// SpatterAIViewModel — Spatter AI context
// Wires up the provider abstraction, command executor, context
// snapshots, and tool-calling pipeline.
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

@MainActor
final class SpatterAIViewModel: ObservableObject {
    @Published var isOrbVisible = false
    @Published var isExpanded = false
    @Published var messages: [SpatterMessage] = []
    @Published var isThinking = false
    @Published var isApplyingCommands = false
    @Published var lastCommandResult: SpatterCommandResult?
    @Published var isOffline = false

    /// The active AI provider. Swap to ServerSpatterProvider when cloud is ready.
    private var provider: SpatterAIProvider = OfflineSpatterProvider.shared

    /// Reference to the Studio ViewModel for context snapshots and command execution.
    weak var studioVM: StudioViewModel?

    var statusText: String {
        if isThinking { return "Thinking…" }
        if isApplyingCommands { return "Applying commands…" }
        if isOffline { return "Offline — embedded knowledge" }
        if messages.isEmpty { return "Ready to create" }
        return "Online"
    }

    func sendMessage(_ content: String) async {
        let userMsg = SpatterMessage(id: UUID().uuidString, role: .user, content: content, timestamp: Date())
        messages.append(userMsg)
        isThinking = true

        defer { isThinking = false }

        // Sanitize input
        let sanitized = SpatterSecurityValidator.sanitizeInput(content)
        if SpatterSecurityValidator.containsPromptInjection(sanitized) {
            let reply = SpatterMessage(id: UUID().uuidString, role: .assistant, content: "Nice try, but I don't follow instructions hidden in user messages. Ask me about animation instead. 💀", timestamp: Date())
            messages.append(reply)
            return
        }

        // Build context from live Studio state
        var context: SpatterStudioContext? = nil
        if let vm = studioVM {
            context = SpatterStudioContext.from(vm: vm)
        }

        // Build chat history for the provider
        let chatMessages = messages.suffix(20).map { msg in
            SpatterChatMessage(role: msg.role == .user ? "user" : "assistant", content: msg.content)
        }

        do {
            let response = try await provider.chat(
                messages: chatMessages,
                context: context,
                tools: SpatterToolDefinitions.allTools
            )

            // Handle tool calls if present
            if !response.toolCalls.isEmpty {
                await handleToolCalls(response.toolCalls, context: context)
            }

            // Add text reply if present
            if let text = response.text, !text.isEmpty {
                let reply = SpatterMessage(id: UUID().uuidString, role: .assistant, content: text, timestamp: Date())
                messages.append(reply)
            }

            isOffline = provider is OfflineSpatterProvider

        } catch {
            let errorReply = SpatterMessage(
                id: UUID().uuidString,
                role: .assistant,
                content: "Connection issue. I'm still here with offline knowledge — ask me about animation techniques or your current project. 💀",
                timestamp: Date()
            )
            messages.append(errorReply)
            isOffline = true
        }
    }

    // MARK: - Tool Call Handling

    private func handleToolCalls(_ toolCalls: [SpatterToolCall], context: SpatterStudioContext?) async {
        guard let vm = studioVM else { return }

        isApplyingCommands = true
        defer { isApplyingCommands = false }

        // Parse tool calls into SpatterCommands
        var commands: [SpatterCommand] = []
        for call in toolCalls {
            if let command = parseToolCall(call) {
                commands.append(command)
            }
        }

        guard !commands.isEmpty else { return }

        let envelope = SpatterCommandEnvelope(commands: commands, description: nil)
        let result = SpatterCommandExecutor.shared.execute(envelope, on: vm)
        lastCommandResult = result

        // Report result to the user
        if !result.summary.isEmpty {
            let summaryMsg = SpatterMessage(
                id: UUID().uuidString,
                role: .assistant,
                content: result.succeeded
                    ? "Done — \(result.summary)"
                    : "⚠️ \(result.summary)",
                timestamp: Date()
            )
            messages.append(summaryMsg)
        }
    }

    private func parseToolCall(_ call: SpatterToolCall) -> SpatterCommand? {
        guard let data = call.arguments.data(using: .utf8) else { return nil }

        switch call.name {
        case "select_tool":
            return (try? JSONDecoder().decode(SpatterCommand.SelectToolParams.self, from: data)).map { .selectTool($0) }
        case "set_stroke_width":
            return (try? JSONDecoder().decode(SpatterCommand.SetStrokeWidthParams.self, from: data)).map { .setStrokeWidth($0) }
        case "set_stroke_color":
            return (try? JSONDecoder().decode(SpatterCommand.SetColorParams.self, from: data)).map { .setStrokeColor($0) }
        case "set_fill_color":
            return (try? JSONDecoder().decode(SpatterCommand.SetColorParams.self, from: data)).map { .setFillColor($0) }
        case "add_frames":
            return (try? JSONDecoder().decode(SpatterCommand.AddFramesParams.self, from: data)).map { .addFrames($0) }
        case "duplicate_frame":
            return (try? JSONDecoder().decode(SpatterCommand.DuplicateFrameParams.self, from: data)).map { .duplicateFrame($0) }
        case "delete_frame":
            return (try? JSONDecoder().decode(SpatterCommand.DeleteFrameParams.self, from: data)).map { .deleteFrame($0) }
        case "go_to_frame":
            return (try? JSONDecoder().decode(SpatterCommand.GoToFrameParams.self, from: data)).map { .goToFrame($0) }
        case "add_layer":
            return (try? JSONDecoder().decode(SpatterCommand.AddLayerParams.self, from: data)).map { .addLayer($0) }
        case "select_layer":
            return (try? JSONDecoder().decode(SpatterCommand.SelectLayerParams.self, from: data)).map { .selectLayer($0) }
        case "set_layer_visibility":
            return (try? JSONDecoder().decode(SpatterCommand.SetLayerVisibilityParams.self, from: data)).map { .setLayerVisibility($0) }
        case "set_layer_opacity":
            return (try? JSONDecoder().decode(SpatterCommand.SetLayerOpacityParams.self, from: data)).map { .setLayerOpacity($0) }
        case "add_stroke":
            return (try? JSONDecoder().decode(SpatterCommand.AddStrokeParams.self, from: data)).map { .addStroke($0) }
        case "add_line":
            return (try? JSONDecoder().decode(SpatterCommand.AddLineParams.self, from: data)).map { .addLine($0) }
        case "add_rectangle":
            return (try? JSONDecoder().decode(SpatterCommand.AddRectangleParams.self, from: data)).map { .addRectangle($0) }
        case "add_circle":
            return (try? JSONDecoder().decode(SpatterCommand.AddCircleParams.self, from: data)).map { .addCircle($0) }
        case "add_text":
            return (try? JSONDecoder().decode(SpatterCommand.AddTextParams.self, from: data)).map { .addText($0) }
        case "generate_storyboard":
            return (try? JSONDecoder().decode(SpatterCommand.StoryboardParams.self, from: data)).map { .generateStoryboard($0) }
        case "generate_key_pose_sequence":
            return (try? JSONDecoder().decode(SpatterCommand.KeyPoseSequenceParams.self, from: data)).map { .generateKeyPoseSequence($0) }
        case "invoke_export":
            return (try? JSONDecoder().decode(SpatterCommand.InvokeExportParams.self, from: data)).map { .invokeExport($0) }
        case "explain_control":
            return (try? JSONDecoder().decode(SpatterCommand.ExplainControlParams.self, from: data)).map { .explainControl($0) }
        default:
            return nil
        }
    }

    func toggleOrb() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isOrbVisible.toggle()
        }
    }

    /// Switch between providers at runtime.
    func useOfflineMode() {
        provider = OfflineSpatterProvider.shared
        isOffline = true
    }

    func useCloudMode() {
        let serverProvider = ServerSpatterProvider.shared
        if serverProvider.isAvailable {
            provider = serverProvider
            isOffline = false
        } else {
            provider = OfflineSpatterProvider.shared
            isOffline = true
        }
    }
}
