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
}

// MARK: - Spatter AI Chat Engine

class SpatterAIEngine {
    static let shared = SpatterAIEngine()
    
    private let brain = SpatterBrainLoader.shared
    
    /// Free AI endpoint — no API key needed
    private let aiEndpoint = "https://text.pollinations.ai/"
    
    struct ChatMessage {
        let role: String // "user" or "assistant"
        let content: String
    }
    
    private var conversationHistory: [ChatMessage] = []
    
    func chat(userMessage: String) async -> String {
        // Get relevant brain context
        let brainContext = brain.contextFor(query: userMessage)
        
        // Build messages array
        let systemPrompt = """
        You are Spatter AI, the creative assistant inside StickDeath ∞.
        You help users create amazing stick figure animations.
        You have deep knowledge of animation, physics, combat choreography, effects, and art.
        
        Use this knowledge base to inform your responses:
        \(brainContext)
        
        Be concise, helpful, and creative. Reference specific techniques when relevant.
        """
        
        conversationHistory.append(ChatMessage(role: "user", content: userMessage))
        
        // Call free AI endpoint
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in conversationHistory.suffix(10) {
            messages.append(["role": msg.role, "content": msg.content])
        }
        
        let body: [String: Any] = [
            "messages": messages,
            "model": "openai",
            "stream": false
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: aiEndpoint) else {
            return "Sorry, I couldn't process that. Try again!"
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = String(data: data, encoding: .utf8) ?? "No response"
            conversationHistory.append(ChatMessage(role: "assistant", content: response))
            return response
        } catch {
            return "Connection error. Check your internet and try again."
        }
    }
    
    func clearHistory() {
        conversationHistory.removeAll()
    }
}
