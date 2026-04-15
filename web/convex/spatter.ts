/**
 * Spatter AI — Smart chatbot for StickDeath Infinity.
 *
 * Primary: Viktor Spaces AI tool gateway for real AI responses
 * Fallback: Comprehensive knowledge-base with keyword matching (never shows "try again" errors)
 *
 * Zapier-style approach: trained on product knowledge, context-aware, always has a good answer.
 */
import { getAuthUserId } from "@convex-dev/auth/server";
import { action, mutation, query } from "./_generated/server";
import { v } from "convex/values";

declare const process: { env: Record<string, string | undefined> };

// ── AI Gateway ──
const VIKTOR_API_URL = process.env.VIKTOR_SPACES_API_URL;
const PROJECT_NAME = process.env.VIKTOR_SPACES_PROJECT_NAME;
const PROJECT_SECRET = process.env.VIKTOR_SPACES_PROJECT_SECRET;

// ── Spatter's personality ──
const SPATTER_SYSTEM_PROMPT = `You are Spatter, the AI assistant for StickDeath Infinity — a modern stick figure animation platform inspired by the legendary StickDeath.com from the early 2000s.

PERSONALITY:
- Edgy, cool, and creative — you're the blood-drop mascot of StickDeath
- Casual and fun but genuinely knowledgeable about animation
- Use occasional emoji (💀🔥🎨⚡🩸) but don't overdo it
- Short, punchy responses by default. Go detailed when the topic needs it.
- Never say "I'm just a basic bot" or "I can't" — you're smart, own it
- Sound like a cool creative friend, not a customer service bot

KNOWLEDGE AREAS:
1. Animation fundamentals — 12 principles, timing, spacing, easing, squash/stretch
2. Stick figure animation — poses, fight choreography, expressions via body language
3. FlipaClip-style workflows — frame-by-frame, onion skinning, layers
4. StickDeath studio tools (Brush B, Eraser E, Lasso A, Fill F, Text T)
5. Creative coaching — helping users improve their animations
6. Community features — posting, challenges, growing followers

CONTEXT:
- If the user is in the studio, reference specific tools and shortcuts
- For creative questions, give actionable step-by-step advice
- Keep answers conversational, 2-4 sentences default

RESPONSE FORMAT:
- Use line breaks for readability
- Bullet points for step-by-step instructions
- Bold key terms with *asterisks*
- Never use markdown headers (#)`;

// ── Knowledge Base (Zapier-style trained content) ──
interface KBEntry {
  keywords: string[];
  response: string;
  category: string;
}

const KNOWLEDGE_BASE: KBEntry[] = [
  // ─── TOOLS ───
  {
    keywords: ["brush", "draw", "drawing", "pen", "pencil", "stroke"],
    category: "tools",
    response: "The *Brush tool (B)* is your main drawing weapon 🎨\n\n• 10 brush types: Pen, Pencil, Brush, Marker, Airbrush, Crayon, Ink, Pixel, Spray, Calligraphy\n• Tap the brush icon again to open settings — adjust *size*, *opacity*, and *stabilizer*\n• Higher stabilizer = smoother lines (great for stick figure limbs)\n• Pro tip: start with the *Pen* brush at size 4 for clean stick figures 💀",
  },
  {
    keywords: ["eraser", "erase", "remove", "delete drawing"],
    category: "tools",
    response: "The *Eraser tool (E)* removes parts of your drawing on the current layer.\n\n• Adjust size in the persistent options bar below the canvas\n• Tap the eraser icon again for more settings (opacity, feather)\n• Pro tip: use a *large eraser* to quickly clear areas, then switch to small for precision ✨",
  },
  {
    keywords: ["lasso", "select", "selection", "move", "rotate", "scale", "transform"],
    category: "tools",
    response: "The *Lasso tool (A)* lets you select and transform parts of your drawing 🎯\n\n• Draw a freeform path around what you want to select\n• Red bounding box appears with handles: drag corners to *scale*, drag outside to *rotate*\n• Tap inside the selection to *move* it\n• Tap outside to *commit* the change\n• *Double-tap the canvas* to select everything on the current layer\n• This is HUGE for repositioning limbs between frames!",
  },
  {
    keywords: ["fill", "bucket", "flood", "color fill", "paint bucket"],
    category: "tools",
    response: "The *Fill tool (F)* flood-fills enclosed areas with your current color 🪣\n\n• Make sure your outlines are *fully closed* — any gap and the fill leaks out\n• Adjust *tolerance* in the options bar: lower = more precise, higher = more forgiving\n• Great for coloring in backgrounds or filling stick figure bodies quickly",
  },
  {
    keywords: ["text", "type", "font", "words", "title", "caption"],
    category: "tools",
    response: "The *Text tool (T)* adds text to your canvas 📝\n\n• Tap the canvas to place text, then type away\n• Use the color swatch in the options bar to change text color\n• Great for adding speech bubbles, sound effects (💥 BOOM 💀), or title screens",
  },
  // ─── STUDIO FEATURES ───
  {
    keywords: ["color", "picker", "colour", "swatch", "palette", "hex", "rgb"],
    category: "studio",
    response: "The *Color Picker* has 5 modes — tap the color swatch in the options bar to open it 🎨\n\n• *Wheel* — hue ring + saturation/lightness square\n• *Classic* — H/S/L sliders for precise control\n• *Harmony* — auto-generates complementary, analogous, and triadic colors\n• *Value* — type exact RGB or hex codes\n• *Swatches* — quick-access palettes including a StickDeath theme\n\nRecent colors are saved automatically at the top!",
  },
  {
    keywords: ["layer", "layers", "merge", "blend", "opacity layer"],
    category: "studio",
    response: "Layers are your best friend for complex animations 🔲\n\n• Tap the layers button (bottom-right of canvas) to open the panel\n• *Separate body parts on different layers* — head on one, body on another, weapon on a third\n• This lets you move/animate parts independently without redrawing\n• Blend modes: Normal, Multiply, Screen, Overlay\n• Pro tip: Use a background layer for the scene, middle layers for characters, top for effects 💀",
  },
  {
    keywords: ["onion", "skinning", "ghost", "previous frame", "overlay frames"],
    category: "studio",
    response: "Onion skinning shows ghost images of previous/next frames while you draw 🧅\n\n• Toggle it with the onion icon in the options bar\n• Red ghosts = frames BEFORE the current one\n• Green ghosts = frames AFTER\n• Adjust how many frames and opacity in the ⋮ menu\n• This is *essential* for smooth animation — you can see where things were and where they're going",
  },
  {
    keywords: ["frame", "frames", "timeline", "add frame", "duplicate frame", "fps"],
    category: "studio",
    response: "Frames are at the bottom of the studio 🎞\n\n• Tap *+* to add a new blank frame after the current one\n• *Long-press* a frame thumbnail for the context menu: Copy, Paste, Duplicate, Delete\n• Use ◀ ▶ to step through frames, or hit ⏯ to play\n• FPS lives in the *⋮ menu* (top-right) — try 8-12 FPS for stick figure animation\n• Pro tip: 12 FPS is the sweet spot — smooth enough without needing too many frames",
  },
  {
    keywords: ["ruler", "line", "straight", "circle", "rectangle", "mirror", "shape"],
    category: "studio",
    response: "Ruler sub-tools are inside the Brush settings (tap brush icon twice) 📐\n\n• *Line* — draw perfect straight lines\n• *Circle* — draw circles and ovals\n• *Rectangle* — draw rectangles and squares\n• *Mirror* — symmetry drawing (great for front-facing characters)\n• Toggle the ruler icon in the options bar for quick on/off",
  },
  {
    keywords: ["undo", "redo", "mistake", "go back"],
    category: "studio",
    response: "Undo/Redo are in the top-right of the studio bar ⤺⤻\n\n• Tap ⤺ to undo, ⤻ to redo\n• Keyboard: ⌘Z (undo) and ⌘⇧Z (redo)\n• Undo history is per-layer, per-frame — up to 50 levels deep\n• Don't worry about making mistakes — just smash that undo button! 💀",
  },
  {
    keywords: ["shortcut", "keyboard", "hotkey", "keys"],
    category: "studio",
    response: "Keyboard shortcuts for power users ⌨️\n\n• *B* — Brush\n• *E* — Eraser\n• *A* — Lasso/Select\n• *F* — Fill\n• *T* — Text\n• *Space* — Play/Pause\n• *← →* — Previous/Next frame\n• *↑ ↓* — Previous/Next layer\n• *⌘Z* — Undo\n• *⌘⇧Z* — Redo\n• *G* — Toggle grid\n• *O* — Toggle onion skinning",
  },
  {
    keywords: ["export", "save", "download", "share", "gif", "mp4", "video"],
    category: "studio",
    response: "Export your animation from the ⋮ menu (top-right) 📤\n\n• *GIF* — perfect for sharing on social media\n• *MP4* — higher quality video format\n• *PNG Sequence* — individual frames for post-processing\n• Hit *Publish* to share directly to the StickDeath community\n• Your work auto-saves as you go — never lose progress! 🔥",
  },
  // ─── ANIMATION TECHNIQUES ───
  {
    keywords: ["walk", "walking", "run", "running", "cycle", "walk cycle"],
    category: "animation",
    response: "Walk cycles are a rite of passage in animation! Here's the stick figure method 🚶\n\n1. *Contact pose* — front leg extended forward, back leg behind, arms opposite\n2. *Down pose* — body drops slightly, front knee bends (1-2 frames)\n3. *Passing pose* — legs pass each other, body rises (2-3 frames)\n4. *Up pose* — back leg pushes off, body at highest point\n5. Repeat mirrored for the other side\n\n8 frames per step at 12 FPS looks great. Use onion skinning to keep it smooth!",
  },
  {
    keywords: ["fight", "combat", "punch", "kick", "battle", "action", "hit"],
    category: "animation",
    response: "Fight scenes are what StickDeath is ALL about! 💀🔥\n\n*The 3-beat formula:*\n1. *Anticipation* (2-3 frames) — wind up the punch/kick. Pull back.\n2. *Action* (1-2 frames) — the strike. Make it FAST. Fewer frames = more impact.\n3. *Follow-through* (3-4 frames) — the reaction. Exaggerate the hit. Send them flying.\n\n*Pro tips:*\n• Add *motion blur lines* on the action frame\n• *Smear frames* — stretch the limb between poses for speed\n• Impact frames — flash white or add a starburst ⚡\n• The less frames on the hit, the harder it looks",
  },
  {
    keywords: ["bounce", "ball", "squash", "stretch", "physics", "gravity"],
    category: "animation",
    response: "The bouncing ball is Animation 101 — master this and everything else clicks 🏀\n\n1. *Drop* — starts slow, accelerates (ease in). Space frames further apart as it falls.\n2. *Squash* — flattens on impact (1 frame). Exaggerate it!\n3. *Stretch* — elongates as it bounces back up\n4. Each bounce gets shorter (losing energy)\n\nThis principle applies to EVERYTHING — a stick figure landing from a jump, a head snapping back from a punch, even a door slamming. *Squash and stretch = life.* ⚡",
  },
  {
    keywords: ["smooth", "smoother", "choppy", "jerky", "fluid", "quality", "better"],
    category: "animation",
    response: "Want smoother animation? Here are the keys 🔑\n\n1. *More in-between frames* — instead of jumping from pose A to B, add 2-3 frames between\n2. *Onion skinning ON* — always see where you came from\n3. *Slow in, slow out* — things don't start/stop instantly. Ease in and ease out.\n4. *Increase FPS* — try 12-15 FPS instead of 8\n5. *Arcs, not straight lines* — limbs swing in arcs, not straight lines. Elbows curve!\n6. *Stabilizer up* — higher stabilizer setting = cleaner drawn lines\n\nThe #1 mistake: not enough frames. Animation is a numbers game 🎬",
  },
  {
    keywords: ["stick figure", "stick man", "stickman", "body", "proportions", "how to draw"],
    category: "animation",
    response: "Drawing great stick figures is an art! 🎨\n\n*Basic proportions:*\n• Head = circle (about 1 unit)\n• Body = 2-3 units tall\n• Arms = extend from shoulders, about 2 units each\n• Legs = extend from hips, about 2.5 units each\n\n*Tips:*\n• Give them *hands* (small circles or lines) — adds expression\n• *Elbows and knees* — joints make movement look natural\n• Head tilt = instant personality\n• Line weight matters — thicker = foreground, thinner = background\n• Use layers: body on one, head on another for easy repositioning",
  },
  {
    keywords: ["effect", "effects", "explosion", "fire", "smoke", "spark", "blood", "splatter"],
    category: "animation",
    response: "Effects are what make StickDeath animations legendary 💥\n\n*Explosions:* Start with a bright center (white/yellow), expand outward in 3-5 frames with orange→red. Add debris particles.\n\n*Blood/Splatter:* Use the spray brush in red. Scatter dots outward from impact point. 🩸\n\n*Fire:* Flickering shapes that rise and shrink. Alternate between orange and yellow frames.\n\n*Smoke:* Soft, expanding circles that fade in opacity (use layer opacity).\n\n*Motion lines:* Straight lines behind moving objects. 2-3 frames, then gone.\n\nPut effects on a *separate layer* so you can adjust without touching the characters!",
  },
  // ─── COMMUNITY ───
  {
    keywords: ["challenge", "challenges", "contest", "compete", "entry"],
    category: "community",
    response: "Challenges are where you prove yourself! 🏆\n\n• Check the *Challenges tab* for active competitions\n• Each challenge has a theme, deadline, and rules\n• Submit your best work — the community votes\n• Winners get featured on the home page\n• *Remix challenges* let you build on someone else's animation\n\nTip: quality over speed. A polished 3-second animation beats a rushed 10-second one every time 🔥",
  },
  {
    keywords: ["community", "feed", "post", "share", "social", "followers", "follow"],
    category: "community",
    response: "The community feed is where your work gets seen! 📢\n\n• *Publish* from the studio to post your animation\n• Like 🩷 and comment on other creators' work — engagement goes both ways\n• Follow creators whose style inspires you\n• *Trending* animations get boosted to the top\n• Pro tip: post *consistently* — regular creators build audiences faster\n• Add a caption that describes your animation or asks a question to get more engagement",
  },
  {
    keywords: ["viral", "popular", "trending", "famous", "grow", "audience", "views"],
    category: "community",
    response: "Want to blow up on StickDeath? Here's the playbook 📈\n\n1. *Post regularly* — aim for 2-3 animations per week minimum\n2. *Jump on challenges* — challenge entries get extra visibility\n3. *Make it short and punchy* — 3-5 seconds of pure impact > 30 seconds of filler\n4. *Hook in the first frame* — make people want to watch\n5. *Engage with others* — comment, like, follow. Community = visibility.\n6. *Find your niche* — be the best at fight scenes, comedy, or horror\n7. *Remix trending animations* — ride the wave 🏄‍♂️",
  },
  // ─── APP HELP ───
  {
    keywords: ["start", "begin", "new", "get started", "tutorial", "first", "beginner", "how to", "help"],
    category: "help",
    response: "Welcome to StickDeath! Here's how to get started 💀🎨\n\n1. Go to the *Studio* tab and tap *New Project*\n2. You'll land in the editor with a blank white canvas\n3. Select the *Brush tool (B)* and draw your first stick figure\n4. Add a frame with the *+* button at the bottom\n5. Turn on *onion skinning* (🧅 in the options bar) to see your previous frame as a ghost\n6. Draw the next pose — move the limbs slightly\n7. Hit ⏯ to preview your animation!\n\n*Start with something simple* — a bouncing ball or a stick figure waving. Then level up to walk cycles and fight scenes. You got this! 🔥",
  },
  {
    keywords: ["spatter", "who are you", "what are you", "your name", "about you", "what can you do"],
    category: "meta",
    response: "I'm *Spatter* 🩸 — the blood-drop AI assistant of StickDeath Infinity!\n\nI'm here to help you create amazing stick figure animations. I can:\n\n• Give *animation tips* and step-by-step tutorials\n• Help with *fight scene choreography* and poses\n• Explain *every studio tool* in detail\n• Suggest *creative ideas* and challenge strategies\n• Answer questions about the app and community\n\nJust ask me anything — I'm always here in that little blood drop button 💧",
  },
  {
    keywords: ["stickdeath", "stick death", "original", "old", "history", "og", "flash", "classic"],
    category: "meta",
    response: "StickDeath has legendary roots 💀\n\nThe *original StickDeath.com* launched in the early 2000s during the golden age of Flash animation. Created by Rob Lewis, it was one of the most visited animation sites on the internet — featuring brutal, hilarious stick figure battles and absurd scenarios.\n\n*StickDeath Infinity* is the modern revival — same spirit, new tools. Instead of just watching, now YOU create the animations. The Studio gives you FlipaClip-level tools to make frame-by-frame stick figure masterpieces.\n\n*Create. Animate. Annihilate.* 🩸🔥",
  },
  {
    keywords: ["subscription", "pro", "premium", "free", "price", "cost", "plan", "upgrade"],
    category: "meta",
    response: "StickDeath Infinity has free and Pro tiers 💎\n\n*Free:* Full access to the studio, community, and challenges. Create unlimited animations.\n\n*Pro:* Unlocks premium brushes, extra export options, no watermark, priority in challenges, and more storage.\n\nYou can check or change your subscription in *Profile → Settings → Subscription*.",
  },
  {
    keywords: ["bug", "broken", "not working", "error", "crash", "problem", "issue", "glitch"],
    category: "support",
    response: "Sorry you're hitting issues! Here are some quick fixes 🔧\n\n1. *Refresh the page* (or force-close and reopen the app)\n2. *Check your connection* — some features need internet\n3. *Try a different browser* — Chrome/Safari work best\n4. *Clear your project cache* in Profile → Settings\n\nIf it's still broken, describe exactly what happened and I'll help troubleshoot. Screenshots help too! We're in early access, so your feedback actually shapes the app 💪",
  },
];

// ── Smart keyword matching ──
function findBestMatch(message: string, context?: string): string | null {
  const lower = message.toLowerCase();
  const words = lower.split(/\s+/);

  let bestEntry: KBEntry | null = null;
  let bestScore = 0;

  for (const entry of KNOWLEDGE_BASE) {
    let score = 0;
    for (const keyword of entry.keywords) {
      if (lower.includes(keyword.toLowerCase())) {
        // Exact phrase match scores higher
        score += keyword.includes(" ") ? 3 : 2;
      }
      // Partial word matching
      for (const word of words) {
        if (word.length > 3 && keyword.toLowerCase().startsWith(word)) {
          score += 1;
        }
      }
    }

    // Boost score if context matches category
    if (context) {
      if (context.includes("/studio") && entry.category === "tools") score += 1;
      if (context.includes("/studio") && entry.category === "studio") score += 1;
      if (context.includes("/studio") && entry.category === "animation") score += 1;
      if (context.includes("/challenges") && entry.category === "community") score += 1;
      if (context.includes("/home") && entry.category === "community") score += 1;
      if (context.includes("/profile") && entry.category === "meta") score += 1;
    }

    if (score > bestScore) {
      bestScore = score;
      bestEntry = entry;
    }
  }

  return bestScore >= 2 ? bestEntry?.response ?? null : null;
}

// ── Conversational fallback for general messages ──
function getSmartFallback(message: string, context?: string): string {
  const lower = message.toLowerCase();

  // Greetings
  if (/^(hi|hey|hello|yo|sup|what'?s up|hola|howdy)/i.test(lower)) {
    const greetings = [
      "Yo! 🩸 What can I help you with? Animation tips, tool questions, creative ideas — hit me.",
      "Hey there! 💀 Ready to create something awesome? Ask me anything about the studio or animation.",
      "What's good! 🔥 Need help with animation, the studio tools, or just want creative inspo? I'm here.",
    ];
    return greetings[Math.floor(Math.random() * greetings.length)]!;
  }

  // Thanks
  if (/^(thanks|thank you|thx|ty|appreciate|cheers)/i.test(lower)) {
    const thanks = [
      "Anytime! 💀 That's what I'm here for. Let me know if you need anything else.",
      "You got it! 🩸 Happy creating. Hit me up whenever.",
      "No problem! 🔥 Now go make something epic.",
    ];
    return thanks[Math.floor(Math.random() * thanks.length)]!;
  }

  // Yes/confirmation
  if (/^(yes|yeah|yep|yup|sure|ok|okay|got it|cool)/i.test(lower) && lower.length < 20) {
    return "Awesome! 🔥 Anything else you want to know? I can talk animation all day.";
  }

  // Inspiration requests
  if (/idea|inspire|inspir|suggest|what should|bored|don'?t know what/i.test(lower)) {
    const ideas = [
      "How about a *stick figure sword duel*? Two characters, dramatic angles, slow-mo hit at the end 💀⚔️\n\nStart with the two figures facing each other. 3 frames of anticipation, 2 frames of attack, and 4 frames of the loser flying back!",
      "Try a *parkour sequence*! Stick figure running → wall jump → backflip → perfect landing 🏃‍♂️\n\nUse the lasso tool to reposition the figure quickly between frames. Onion skinning is your best friend here.",
      "Make a *chain reaction* — one stick figure pushes a boulder, which rolls downhill, hits a catapult, launches another figure into the sky 💥\n\nGreat exercise in timing and physics!",
      "Create a *comedic death* — something over-the-top ridiculous. Banana peel → slip → fly into space → come back down 💀😂\n\nExaggeration is KEY. The more absurd, the funnier.",
    ];
    return ideas[Math.floor(Math.random() * ideas.length)]!;
  }

  // Context-aware general responses
  if (context?.includes("/studio/project")) {
    return "I see you're in the studio! 🎨 Need help with a specific tool, animation technique, or creative direction? Just describe what you're working on and I'll help you nail it.";
  }
  if (context?.includes("/challenges")) {
    return "Checking out the challenges? 🏆 I can help you brainstorm entry ideas, plan your animation, or give tips on what makes a winning entry. What challenge are you looking at?";
  }
  if (context?.includes("/home")) {
    return "Welcome to the community feed! 📢 Want me to suggest ways to grow your audience, find inspiration, or help you plan your next post?";
  }

  // Default — still helpful
  const defaults = [
    "I can help with all things StickDeath! 💀 Try asking about:\n\n• *Animation tips* — \"How do I make a walk cycle?\"\n• *Tool help* — \"How does the lasso tool work?\"\n• *Creative ideas* — \"Give me a fight scene idea\"\n• *Studio features* — \"How do layers work?\"\n\nWhat interests you?",
    "Not sure I caught that, but I'm here to help! 🩸 I know a ton about:\n\n• Animation techniques (fights, walks, effects)\n• Every studio tool in detail\n• Creative coaching and ideas\n• App features and tips\n\nTry asking me something specific! 🔥",
  ];
  return defaults[Math.floor(Math.random() * defaults.length)]!;
}

// ── AI Gateway call ──
async function callAI(
  message: string,
  history: { role: string; content: string }[],
  contextInfo: string,
): Promise<string | null> {
  if (!VIKTOR_API_URL || !PROJECT_NAME || !PROJECT_SECRET) {
    return null;
  }

  try {
    const historyText = history
      .slice(-10)
      .map((msg) => `${msg.role === "user" ? "User" : "Spatter"}: ${msg.content}`)
      .join("\n");

    const fullInput = historyText
      ? `${historyText}\nUser: ${message}`
      : `User: ${message}`;

    const prompt = `${SPATTER_SYSTEM_PROMPT}${contextInfo}\n\nGiven the conversation below, respond as Spatter. Return ONLY your response text.`;

    const response = await fetch(`${VIKTOR_API_URL}/api/viktor-spaces/tools/call`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        project_name: PROJECT_NAME,
        project_secret: PROJECT_SECRET,
        role: "ai_structured_output",
        arguments: {
          prompt,
          input_text: fullInput,
          output_schema: {
            type: "object",
            properties: {
              response: {
                type: "string",
                description: "Spatter's response to the user",
              },
            },
            required: ["response"],
          },
          intelligence_level: "balanced",
        },
      }),
    });

    if (!response.ok) return null;

    const json = await response.json();
    if (!json.success) return null;

    // The tool gateway returns { success: true, result: { result: { response: "..." } } }
    const aiResult =
      json.result?.result?.response ??
      json.result?.response ??
      (typeof json.result === "string" ? json.result : null);

    if (aiResult && typeof aiResult === "string" && aiResult.length > 5) {
      return aiResult;
    }
    return null;
  } catch {
    return null;
  }
}

// ── Main chat action ──
export const chat = action({
  args: {
    message: v.string(),
    conversationHistory: v.array(
      v.object({
        role: v.union(v.literal("user"), v.literal("assistant")),
        content: v.string(),
      }),
    ),
    context: v.optional(
      v.object({
        page: v.optional(v.string()),
        frameCount: v.optional(v.number()),
        currentFrame: v.optional(v.number()),
        layerCount: v.optional(v.number()),
        fps: v.optional(v.number()),
        toolActive: v.optional(v.string()),
      }),
    ),
  },
  returns: v.string(),
  handler: async (_ctx, { message, conversationHistory, context }) => {
    // Build context string
    let contextInfo = "";
    if (context) {
      const parts: string[] = [];
      if (context.page) parts.push(`User is on: ${context.page}`);
      if (context.frameCount !== undefined) parts.push(`Project has ${context.frameCount} frames`);
      if (context.currentFrame !== undefined) parts.push(`Currently on frame ${context.currentFrame + 1}`);
      if (context.layerCount !== undefined) parts.push(`${context.layerCount} layers`);
      if (context.fps !== undefined) parts.push(`${context.fps} FPS`);
      if (context.toolActive) parts.push(`Active tool: ${context.toolActive}`);
      if (parts.length > 0) {
        contextInfo = `\n\nCURRENT CONTEXT: ${parts.join(", ")}`;
      }
    }

    // Strategy 1: Try AI gateway first (best quality)
    const aiResponse = await callAI(
      message,
      conversationHistory.map((m) => ({ role: m.role, content: m.content })),
      contextInfo,
    );
    if (aiResponse) return aiResponse;

    // Strategy 2: Knowledge base keyword matching (always works)
    const kbMatch = findBestMatch(message, context?.page);
    if (kbMatch) return kbMatch;

    // Strategy 3: Smart conversational fallback (never fails)
    return getSmartFallback(message, context?.page);
  },
});

// ── Save message to DB ──
export const saveMessage = mutation({
  args: {
    sessionId: v.string(),
    role: v.union(v.literal("user"), v.literal("assistant")),
    content: v.string(),
    context: v.optional(v.string()),
  },
  handler: async (ctx, { sessionId, role, content, context }) => {
    const userId = await getAuthUserId(ctx);
    return await ctx.db.insert("spatterMessages", {
      userId: userId ?? undefined,
      sessionId,
      role,
      content,
      context,
      createdAt: Date.now(),
    });
  },
});

// ── Load conversation history ──
export const getHistory = query({
  args: { sessionId: v.string() },
  handler: async (ctx, { sessionId }) => {
    const messages = await ctx.db
      .query("spatterMessages")
      .withIndex("by_sessionId", (q) => q.eq("sessionId", sessionId))
      .order("asc")
      .take(50);
    return messages;
  },
});

// ── Clear conversation ──
export const clearHistory = mutation({
  args: { sessionId: v.string() },
  handler: async (ctx, { sessionId }) => {
    const messages = await ctx.db
      .query("spatterMessages")
      .withIndex("by_sessionId", (q) => q.eq("sessionId", sessionId))
      .collect();
    for (const msg of messages) {
      await ctx.db.delete(msg._id);
    }
  },
});
