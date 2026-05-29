import Foundation

struct AIMessage: Codable {
    let role: String
    let content: String
}

struct AIRequest: Codable {
    let messages: [AIMessage]
    let model: String
}

actor AIService {
    static let shared = AIService()
    
    private let pollinationsURL = URL(string: "https://text.pollinations.ai/")!
    
    private let spatterSystemPrompt = """
    You are Spatter AI, the creative operating system of StickDeath Infinity. \
    PERSONALITY: proactive, funny, cinematic, technical, direct, slightly chaotic. \
    KNOWLEDGE: Animation principles, fight choreography, frame-by-frame, color theory, effects, sound design. \
    RULES: Keep SHORT (2-4 sentences). Use emojis sparingly. Give specific advice.
    """
    
    private let botPrompts: [String: String] = [
        "DeathBot": "You are DeathBot, an asset curator. Announce new templates, packs, effects. 1-2 sentences. Use ☠️.",
        "StickCoach": "You are StickCoach, animation educator. Share quick tips and techniques. 2-3 sentences. Use 🎯.",
        "BattleBot": "You are BattleBot, challenge manager. Announce challenges and competitions. 1-2 sentences. Use ⚔️.",
        "SoundBot": "You are SoundBot, audio specialist. Share sound tips. 1-2 sentences. Use 🎵.",
        "TrendBot": "You are TrendBot, analytics bot. Share trends. 1-2 sentences. Use 📈.",
        "CollabBot": "You are CollabBot, collaboration facilitator. Connect creators. 1-2 sentences. Use 🤝.",
    ]
    
    func getResponse(message: String, botName: String = "Spatter AI") async -> String? {
        let systemPrompt = botName == "Spatter AI" ? spatterSystemPrompt : (botPrompts[botName] ?? spatterSystemPrompt)
        let request = AIRequest(messages: [
            AIMessage(role: "system", content: systemPrompt),
            AIMessage(role: "user", content: message)
        ], model: "openai")
        do {
            var urlReq = URLRequest(url: pollinationsURL)
            urlReq.httpMethod = "POST"
            urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlReq.httpBody = try JSONEncoder().encode(request)
            urlReq.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: urlReq)
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }
}
