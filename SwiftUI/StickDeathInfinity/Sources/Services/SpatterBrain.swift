import Foundation

// Spatter Brain — 1,100 knowledge modules for Spatter AI
struct BrainModule: Codable {
    let id: String
    let category: String
    let title: String
    let description: String
    let tags: [String]?
    let depth: String?
    let content: String?
}

class SpatterBrain {
    static let shared = SpatterBrain()
    private var modules: [BrainModule] = []
    
    func loadModules(from jsonData: Data) {
        do {
            modules = try JSONDecoder().decode([BrainModule].self, from: jsonData)
            print("SpatterBrain loaded \(modules.count) modules")
        } catch {
            print("SpatterBrain load error: \(error)")
        }
    }
    
    func search(query: String, limit: Int = 5) -> [BrainModule] {
        let q = query.lowercased()
        let scored = modules.map { m -> (BrainModule, Int) in
            var score = 0
            if m.title.lowercased().contains(q) { score += 10 }
            if m.description.lowercased().contains(q) { score += 5 }
            if m.category.lowercased().contains(q) { score += 3 }
            if let tags = m.tags {
                for tag in tags where tag.lowercased().contains(q) { score += 4 }
            }
            // Keyword matching
            let words = q.split(separator: " ")
            for word in words {
                let w = String(word)
                if m.title.lowercased().contains(w) { score += 2 }
                if m.description.lowercased().contains(w) { score += 1 }
            }
            return (m, score)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
    
    func getResponse(for query: String) -> String {
        let results = search(query: query, limit: 3)
        guard !results.isEmpty else {
            return "I'm thinking about that one... Ask me about animation techniques, studio tools, effects, or anything creative! 🎨"
        }
        let top = results[0]
        var response = "\(top.title): \(top.description)"
        if results.count > 1 {
            response += "\n\nRelated: \(results[1].title)"
        }
        return response
    }
}
