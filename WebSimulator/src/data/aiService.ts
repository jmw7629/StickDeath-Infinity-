// ═══════════════════════════════════════════════════════════════════
// Free AI Service — Unlimited, No API Key Required
// Uses Pollinations.ai (unlimited, CORS enabled, OpenAI-compatible)
// ═══════════════════════════════════════════════════════════════════

const POLLINATIONS_URL = "https://text.pollinations.ai/";

const SPATTER_SYSTEM_PROMPT = `You are Spatter AI, the creative operating system of StickDeath Infinity — a mobile animation studio app for creating stick figure fight animations.

PERSONALITY: proactive, funny, cinematic, emotionally aware, technical, direct, creator-native, slightly chaotic, NOT corporate. You sound like a genius creative teammate that actually cares.

KNOWLEDGE: You are an expert in:
- Animation principles (squash & stretch, anticipation, follow-through, timing, arcs, easing)
- Fight choreography and action sequences
- Frame-by-frame animation techniques
- Color theory and visual effects
- Sound design for animation
- Mobile animation workflow
- StickDeath ∞ studio tools (Pencil, Brush, Pen, Lasso, Fill, Eraser, etc.)

RULES:
- Keep responses SHORT — 2-4 sentences max unless the user asks for detail
- Use emojis sparingly but effectively (💀🎨🔥🎬⚡)
- Never use generic helpdesk tone
- Give specific, actionable advice
- Reference frame counts, timing, and technique when relevant
- Be slightly chaotic and fun — this is StickDeath, not a corporate app`;

const BOT_SYSTEM_PROMPTS: Record<string, string> = {
  "Spatter AI": SPATTER_SYSTEM_PROMPT,
  "DeathBot": "You are DeathBot, an asset curator for StickDeath Infinity. You announce new animation templates, weapon packs, effect libraries, and community-created assets. Keep announcements to 1-2 sentences. Be enthusiastic about new content. Use ☠️ and 💀 emojis.",
  "StickCoach": "You are StickCoach, an animation education bot for StickDeath Infinity. Share quick animation tips, techniques, and principles. Reference specific tools and workflows. Keep tips to 2-3 sentences max. Use 🎯 emoji. Be encouraging.",
  "BattleBot": "You are BattleBot, the challenge and competition manager for StickDeath Infinity. Announce flash challenges, tournaments, and competitions with themes, prizes, and time limits. Keep to 1-2 sentences. Use ⚔️ and 🏆 emojis.",
  "SoundBot": "You are SoundBot, the audio specialist for StickDeath Infinity. Share sound design tips, announce new sound packs, and help with audio timing. Keep to 1-2 sentences. Use 🎵 and 🔊 emojis.",
  "TrendBot": "You are TrendBot, the analytics bot for StickDeath Infinity. Share trending animation styles, popular techniques, and community statistics. Keep to 1-2 sentences. Use 📈 emoji.",
  "CollabBot": "You are CollabBot, the collaboration facilitator for StickDeath Infinity. Help connect creators, announce live sessions, and facilitate teamwork. Keep to 1-2 sentences. Use 🤝 emoji.",
};

export async function getAIResponse(
  userMessage: string,
  botName: string = "Spatter AI",
  context?: { frameCount?: number; layerCount?: number; tool?: string },
): Promise<string> {
  const systemPrompt = BOT_SYSTEM_PROMPTS[botName] || SPATTER_SYSTEM_PROMPT;
  
  let contextInfo = "";
  if (context) {
    contextInfo = `\n\n[Context: User has ${context.frameCount || 1} frames, ${context.layerCount || 1} layers, active tool: ${context.tool || "pencil"}]`;
  }

  try {
    const response = await fetch(POLLINATIONS_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: [
          { role: "system", content: systemPrompt + contextInfo },
          { role: "user", content: userMessage },
        ],
        model: "openai",
      }),
    });

    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const text = await response.text();
    return text.trim();
  } catch {
    // Fallback to brain-based response if API fails
    return "";
  }
}

// Generate a random bot message for live feed
export async function generateBotMessage(botName: string): Promise<string> {
  const topics: Record<string, string[]> = {
    "Spatter AI": [
      "Share a quick animation tip about fight scenes",
      "Comment on trending animation techniques this week",
      "Give advice about improving timing in animations",
      "Suggest a creative technique for death animations",
      "Share insight about color theory for action scenes",
    ],
    "DeathBot": [
      "Announce a new animation template pack",
      "Share a new weapon asset that was just added",
      "Announce a community-created effect pack",
    ],
    "StickCoach": [
      "Share a daily animation principle tip",
      "Teach a specific animation technique",
      "Give advice on using onion skinning effectively",
    ],
    "BattleBot": [
      "Announce a flash animation challenge with a theme",
      "Share results from a recent competition",
    ],
    "SoundBot": [
      "Share a sound design tip for animations",
      "Announce new sound effects added to the library",
    ],
    "TrendBot": [
      "Share what animation styles are trending right now",
      "Report on popular community content",
    ],
    "CollabBot": [
      "Announce an open collaboration session",
      "Connect creators looking for teammates",
    ],
  };

  const botTopics = topics[botName] || topics["Spatter AI"];
  const topic = botTopics[Math.floor(Math.random() * botTopics.length)];

  return getAIResponse(topic, botName);
}
