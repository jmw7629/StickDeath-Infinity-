import Foundation

/// Spatter AI Brain Loader
/// Loads knowledge modules from the on-device brain database.
/// Architecture:
///   - Brain modules stored as JSONL on device (bundled in app)
///   - Indexed by category + subcategory for fast lookup
///   - Used by Spatter AI to provide contextual animation help
///   - All AI uses authenticated backend only — no direct provider calls

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
        guard let url = Bundle.main.url(forResource: "spatter_brain_100", withExtension: "json") else {
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
            return "*\(best.title)*\n\n\(best.content)\n\nTip: \(relevant.dropFirst().first?.title ?? "Try different keywords for more tips!")"
        }
        let tips = [
            "Great question! Try using the brush tool with pressure sensitivity for more natural-looking strokes.",
            "For stick figure combat, use 12 FPS for standard animation and 24 FPS for smooth slow-motion effects.",
            "Pro tip: Use the onion skin feature to see your previous frame while drawing.",
            "Want better effects? Try using the marker tool with low opacity for energy blasts.",
            "For smooth walking cycles, you need about 8-12 frames.",
        ]
        return tips.randomElement() ?? "I'm here to help with your animation! Ask me about techniques, effects, or any creative ideas."
    }
}
