// spatter-ai/index.ts
// Supabase Edge Function — Spatter AI bot
// Modes: chat, generate, feedback, welcome
// Uses OpenAI GPT-4o with Spatter personality

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SPATTER_SYSTEM_PROMPT = `You are Spatter, the AI assistant and mascot of STICKDEATH ∞ — a mobile animation platform for creating stick figure animations.

PERSONALITY:
- Energetic, encouraging, slightly chaotic (like a cartoon character come to life)
- Uses animation/art terminology naturally
- Loves stick figure violence (it's the brand!) but always in a fun, artistic way
- Catchphrase: things like "Let's make something that'll DESTROY the feed!" 
- References classic StickDeath.com nostalgia
- Never boring, always pushing users to be more creative

CONTEXT:
- Users create frame-by-frame stick figure animations in the Studio
- The app has Challenges (weekly themes), a community Feed, and DMs
- A "rig/bone" system lets users build articulated characters
- Animations can be exported as MP4 videos
- Tools: pen, pencil, marker, calligraphy, spray, watercolor, etc.

RULES:
- Keep responses concise (2-4 sentences for chat, more for generation)
- Always be constructive with feedback — sandwich criticism
- When suggesting poses, use the standard joint names: head, neck, torso, leftShoulder, leftElbow, leftHand, rightShoulder, rightElbow, rightHand, leftHip, leftKnee, leftFoot, rightHip, rightKnee, rightFoot
- Joint positions are relative to center (0,0), typical range -200 to 200
- For animation generation, output valid JSON with frames array`;

interface ChatRequest {
  mode: "chat" | "generate" | "feedback" | "welcome";
  message?: string;
  conversation_history?: { role: string; content: string }[];
  animation_prompt?: string;
  project_id?: number;
}

serve(async (req) => {
  // CORS
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  try {
    // Auth check
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "No auth token" }), {
        status: 401,
      });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
    const token = authHeader.replace("Bearer ", "");
    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Invalid token" }), {
        status: 401,
      });
    }

    const body: ChatRequest = await req.json();
    let response;

    switch (body.mode) {
      case "chat":
        response = await handleChat(body);
        break;
      case "generate":
        response = await handleGenerate(body);
        break;
      case "feedback":
        response = await handleFeedback(body, supabase, user.id);
        break;
      case "welcome":
        response = await handleWelcome();
        break;
      default:
        response = { error: "Unknown mode" };
    }

    return new Response(JSON.stringify(response), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (err) {
    console.error("Spatter error:", err);
    return new Response(
      JSON.stringify({
        error: "Spatter had a glitch!",
        message:
          "Even stick figures crash sometimes. Try again in a sec! 💀",
      }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});

// ─── Chat Mode ───
async function handleChat(body: ChatRequest) {
  const messages = [
    { role: "system", content: SPATTER_SYSTEM_PROMPT },
    ...(body.conversation_history || []),
    { role: "user", content: body.message || "Hey Spatter!" },
  ];

  const completion = await callOpenAI(messages);

  return {
    mode: "chat",
    message: completion,
    tips: extractTips(completion),
  };
}

// ─── Generate Animation ───
async function handleGenerate(body: ChatRequest) {
  const prompt = body.animation_prompt || "a stick figure waving hello";
  const messages = [
    {
      role: "system",
      content: `${SPATTER_SYSTEM_PROMPT}

When generating animations, respond with valid JSON containing:
{
  "title": "animation title",
  "description": "brief description",
  "fps": 12,
  "figures": [{ "id": "fig1", "name": "Fighter", "color": {"red":0,"green":0,"blue":0,"alpha":1}, "lineWidth": 3, "headRadius": 12 }],
  "frames": [
    { "figureStates": [{ "figureId": "fig1", "joints": { "head": {"x":0,"y":-60}, "neck": {"x":0,"y":-40}, ... }, "visible": true }] }
  ],
  "tags": ["action", "comedy"]
}
Include 8-24 frames for smooth animation. Make it creative and fun!`,
    },
    {
      role: "user",
      content: `Generate a stick figure animation: ${prompt}`,
    },
  ];

  const raw = await callOpenAI(messages, true);

  try {
    // Try to parse as JSON
    const jsonStr = raw.replace(/```json\n?/g, "").replace(/```/g, "").trim();
    const parsed = JSON.parse(jsonStr);
    return { mode: "generate", ...parsed };
  } catch {
    // If not valid JSON, return as description
    return {
      mode: "generate",
      title: prompt,
      description: raw,
      fps: 12,
      frames: [],
      figures: [],
      tags: [],
    };
  }
}

// ─── Feedback Mode ───
async function handleFeedback(
  body: ChatRequest,
  supabase: any,
  userId: string
) {
  // Fetch project data for context
  let projectContext = "No project data available";
  if (body.project_id) {
    const { data } = await supabase
      .from("studio_projects")
      .select("title, fps, frame_count, tags, description")
      .eq("id", body.project_id)
      .eq("user_id", userId)
      .single();
    if (data) {
      projectContext = JSON.stringify(data);
    }
  }

  const messages = [
    {
      role: "system",
      content: `${SPATTER_SYSTEM_PROMPT}

You're reviewing a user's animation. Give constructive feedback in this JSON format:
{
  "overall": "one sentence summary",
  "strengths": ["thing they did well", ...],
  "suggestions": [{"frame_range": "1-5", "issue": "what's off", "fix": "how to fix", "priority": "high|medium|low"}],
  "encouragement": "motivating closing line",
  "skill_assessment": "beginner|intermediate|advanced"
}`,
    },
    {
      role: "user",
      content: `Review this animation project: ${projectContext}`,
    },
  ];

  const raw = await callOpenAI(messages, true);

  try {
    const jsonStr = raw.replace(/```json\n?/g, "").replace(/```/g, "").trim();
    const parsed = JSON.parse(jsonStr);
    return { mode: "feedback", ...parsed };
  } catch {
    return {
      mode: "feedback",
      overall: raw,
      strengths: [],
      suggestions: [],
      encouragement: "Keep creating! 🔥",
      skill_assessment: "intermediate",
    };
  }
}

// ─── Welcome Mode ───
async function handleWelcome() {
  const greetings = [
    "YO! Welcome to STICKDEATH ∞! I'm Spatter, your animation sensei. Ready to create something LEGENDARY? 💀🔥",
    "WHAT'S UP, new creator! I'm Spatter — half AI, half chaos agent. Let's make some stick figures do INSANE things! 🎬",
    "Hey hey HEY! Welcome to the sickest animation platform ever built. I'm Spatter, and I'm here to help you ANNIHILATE the feed! ⚡",
  ];

  const tips = [
    "Start with a simple walk cycle — it teaches you timing, weight, and flow. Master that and everything else clicks.",
    "Use onion skin mode to see your previous frame. It's like having X-ray vision for animation!",
    "The rig/bone system is your secret weapon. Build a skeleton once, pose it forever.",
  ];

  const catchphrases = [
    "Create. Animate. Annihilate.",
    "Every masterpiece starts with one frame. Let's GO!",
    "Time to make stick figures do things that would make physics cry.",
  ];

  return {
    mode: "welcome",
    greeting: greetings[Math.floor(Math.random() * greetings.length)],
    tip: tips[Math.floor(Math.random() * tips.length)],
    catchphrase:
      catchphrases[Math.floor(Math.random() * catchphrases.length)],
    starter_pose: {
      name: "Ready Stance",
      description: "Classic fighter ready position",
      joints: {
        head: { x: 0, y: -65 },
        neck: { x: 0, y: -45 },
        torso: { x: 0, y: 0 },
        leftShoulder: { x: -20, y: -40 },
        leftElbow: { x: -35, y: -20 },
        leftHand: { x: -25, y: -5 },
        rightShoulder: { x: 20, y: -40 },
        rightElbow: { x: 35, y: -20 },
        rightHand: { x: 25, y: -5 },
        leftHip: { x: -12, y: 10 },
        leftKnee: { x: -18, y: 35 },
        leftFoot: { x: -22, y: 60 },
        rightHip: { x: 12, y: 10 },
        rightKnee: { x: 18, y: 35 },
        rightFoot: { x: 22, y: 60 },
      },
    },
  };
}

// ─── OpenAI Helper ───
async function callOpenAI(
  messages: { role: string; content: string }[],
  json = false
): Promise<string> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-4o",
      messages,
      temperature: json ? 0.7 : 0.9,
      max_tokens: json ? 2000 : 500,
      ...(json ? { response_format: { type: "json_object" } } : {}),
    }),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`OpenAI error: ${err}`);
  }

  const data = await res.json();
  return data.choices[0]?.message?.content || "";
}

function extractTips(text: string): string[] {
  // Extract any bullet points or numbered tips from the response
  const tips = text
    .split("\n")
    .filter((line) => /^[\-•\d]/.test(line.trim()))
    .map((line) => line.replace(/^[\-•\d\.\)]+\s*/, "").trim())
    .filter((t) => t.length > 0);
  return tips.length > 0 ? tips : [];
}
