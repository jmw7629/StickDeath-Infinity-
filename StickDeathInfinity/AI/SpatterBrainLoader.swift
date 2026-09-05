import Foundation

/// Spatter AI Brain Loader
/// Loads 51,100+ knowledge modules from the on-device brain database.
/// Brain categories: animation, physics, combat, effects, ai_storytelling,
/// character_design, sound_design, color_theory, world_building, game_mechanics,
/// motion_graphics, cinematography, typography, ui_ux, coding, art_history,
/// music_theory, psychology, narrative, social_media
///
/// Architecture:
///   - Brain modules stored as JSONL on device (bundled in app)
///   - Indexed by category + subcategory for fast lookup
///   - Used by Spatter AI to provide contextual animation help
///   - AI queries use free/unlimited models (no API cost)

struct BrainModule: Codable, Identifiable {
    let id: String
    let category: String
    let subcategory: String
    let title: String
    let content: String
    let tags: [String]
    let difficulty: String?
    let relatedModules: [String]?

    enum CodingKeys: String, CodingKey {
        case id, category, subcategory, title, content, tags, difficulty
        case relatedModules = "related_modules"
    }
}

class SpatterBrainLoader {
    static let shared = SpatterBrainLoader()

    private var modules: [BrainModule] = []
    private var categoryIndex: [String: [BrainModule]] = [:]
    private var loaded = false

    // MARK: - Loading

    func loadBrain() async {
        guard !loaded else { return }

        // Load from bundled JSONL file
        guard let url = Bundle.main.url(forResource: "spatter_brain_50000", withExtension: "jsonl") else {
            print("[SpatterBrain] Brain file not found in bundle")
            return
        }

        do {
            let data = try String(contentsOf: url, encoding: .utf8)
            let lines = data.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let decoder = JSONDecoder()

            for line in lines {
                guard let lineData = line.data(using: .utf8) else { continue }
                if let module = try? decoder.decode(BrainModule.self, from: lineData) {
                    modules.append(module)
                    categoryIndex[module.category, default: []].append(module)
                }
            }

            loaded = true
            print("[SpatterBrain] Loaded \(modules.count) modules across \(categoryIndex.count) categories")
        } catch {
            print("[SpatterBrain] Error loading brain: \(error)")
        }
    }

    // MARK: - Querying

    var categories: [String] {
        Array(categoryIndex.keys).sorted()
    }

    var totalModules: Int {
        modules.count
    }

    func modules(forCategory category: String) -> [BrainModule] {
        categoryIndex[category] ?? []
    }

    func search(query: String, limit: Int = 20) -> [BrainModule] {
        let lowered = query.lowercased()
        let results = modules.filter { module in
            module.title.lowercased().contains(lowered) ||
            module.content.lowercased().contains(lowered) ||
            module.tags.contains(where: { $0.lowercased().contains(lowered) })
        }
        return Array(results.prefix(limit))
    }

    func contextFor(query: String, maxTokens: Int = 2000) -> String {
        let relevant = search(query: query, limit: 5)
        var context = "=== Spatter AI Knowledge Base ===\n"
        for module in relevant {
            context += "\n[\(module.category)/\(module.subcategory)] \(module.title)\n"
            context += module.content + "\n"
        }
        // Trim to maxTokens (rough estimate: 4 chars per token)
        if context.count > maxTokens * 4 {
            context = String(context.prefix(maxTokens * 4))
        }
        return context
    }

    func randomTip(category: String? = nil) -> BrainModule? {
        let pool = category.flatMap { categoryIndex[$0] } ?? modules
        return pool.randomElement()
    }

    /// Quick response from brain knowledge base (no API call)
    func getResponse(for query: String) -> String {
        let relevant = search(query: query, limit: 3)
        if let best = relevant.first {
            return "🎨 *\(best.title)*\n\n\(best.content)\n\n💡 Tip: \(relevant.dropFirst().first?.title ?? "Try different keywords for more tips!")"
        }
        // Fallback responses
        let tips = [
            "Great question! Try using the brush tool with pressure sensitivity for more natural-looking strokes. Hold and drag slowly for smooth lines!",
            "For stick figure combat, use 12 FPS for standard animation and 24 FPS for smooth slow-motion effects. Add smear frames for impact!",
            "Pro tip: Use the onion skin feature to see your previous frame while drawing. It helps keep your animation consistent!",
            "Want better effects? Try using the marker tool with low opacity for energy blasts, then layer them for a glowing look!",
            "For smooth walking cycles, you need about 8-12 frames. Start with the contact poses, then add the passing and down positions.",
        ]
        return tips.randomElement() ?? "I'm here to help with your animation! Ask me about techniques, effects, or any creative ideas."
    }
}

// MARK: - Spatter AI Chat Engine (Backend-only)

class SpatterAIEngine {
    static let shared = SpatterAIEngine()

    private let brain = SpatterBrainLoader.shared

    private let backendURL: String = {
        AppConfig.spatterBackendURL
    }()

    private var conversationHistory: [(role: String, content: String)] = []

    func chat(userMessage: String) async -> String {
        // Get relevant brain context
        let brainContext = brain.contextFor(query: userMessage)

        conversationHistory.append((role: "user", content: userMessage))

        // All cloud AI must use the configured backend endpoint
        guard !backendURL.isEmpty, let url = URL(string: "\(backendURL)/v1/chat") else {
            // Backend unavailable — fall back to local brain knowledge
            let localResponse = brain.getResponse(for: userMessage)
            return localResponse
        }

        let systemPrompt = """
        You are Spatter AI, the creative assistant inside StickDeath ∞.
        You help users create amazing stick figure animations.
        You have deep knowledge of animation, physics, combat choreography, effects, and art.

        Use this knowledge base to inform your responses:
        \(brainContext)

        Be concise, helpful, and creative. Reference specific techniques when relevant.
        """

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in conversationHistory.suffix(10) {
            messages.append(["role": msg.role, "content": msg.content])
        }

        let body: [String: Any] = [
            "messages": messages,
            "stream": false
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return brain.getResponse(for: userMessage)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        // Attach auth session token if available
        if let session = try? await SupabaseManager.shared.client.auth.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = String(data: data, encoding: .utf8) ?? "No response"
            conversationHistory.append((role: "assistant", content: response))
            return response
        } catch {
            // Network error — fall back to local brain knowledge
            return brain.getResponse(for: userMessage)
        }
    }

    func clearHistory() {
        conversationHistory.removeAll()
    }
}
