/**
 * ai-assist — Supabase Edge Function
 *
 * AI assistant endpoint for StickDeath Infinity.
 * Takes a prompt + current project state, calls OpenAI API to generate:
 *   - Pose suggestions
 *   - Animation tips
 *   - Auto-tween between keyframes
 *   - Scene composition advice
 *
 * Purchase-gated: checks subscription status and ai_limits table.
 * Free users get limited daily calls; Pro users get higher caps.
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { verifyAuth, AuthError } from '../_shared/auth.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

type AssistMode =
  | 'pose_suggest'
  | 'animation_tips'
  | 'auto_tween'
  | 'scene_compose'
  | 'general';

interface AssistRequest {
  mode: AssistMode;
  prompt?: string;
  project_state?: ProjectState;
  tween_config?: TweenConfig;
}

interface ProjectState {
  frame_count: number;
  current_frame_index: number;
  figures: FigureState[];
  canvas_size: { width: number; height: number };
  fps: number;
}

interface FigureState {
  id: string;
  joints: Record<string, { x: number; y: number }>;
  position: { x: number; y: number };
  scale: number;
  color: string;
}

interface TweenConfig {
  start_frame: number;
  end_frame: number;
  figure_id: string;
  start_joints: Record<string, { x: number; y: number }>;
  end_joints: Record<string, { x: number; y: number }>;
  easing?: string;
  num_intermediate_frames?: number;
}

interface AiResponse {
  mode: AssistMode;
  suggestions?: unknown;
  tween_frames?: unknown[];
  tips?: string[];
  message?: string;
}

// ─── Constants ───────────────────────────────────────────────────────────────

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY')!;
const OPENAI_MODEL = 'gpt-4o';

const DAILY_LIMITS: Record<string, number> = {
  free: 5,
  pro: 100,
  admin: 999,
};

// ─── System Prompts ──────────────────────────────────────────────────────────

const SYSTEM_PROMPTS: Record<AssistMode, string> = {
  pose_suggest: `You are StickDeath AI, an expert stick figure animator. 
Given the current pose of a stick figure (joint positions), suggest creative and dynamic poses.
Return your suggestions as an array of pose objects, each with:
- name: short descriptive name
- description: what the pose looks like
- joints: Record<joint_name, {x, y}> with relative positions
- difficulty: "easy" | "medium" | "hard"
Joint names: head, neck, left_shoulder, right_shoulder, left_elbow, right_elbow, 
left_hand, right_hand, torso, hip, left_knee, right_knee, left_foot, right_foot.
Return valid JSON only.`,

  animation_tips: `You are StickDeath AI, an animation expert specializing in stick figure animation.
Given the current project state, provide actionable animation tips.
Focus on: timing, spacing, squash & stretch, anticipation, follow-through, arcs, secondary action.
Return as JSON: { "tips": [{ "title": string, "description": string, "priority": "high"|"medium"|"low" }] }`,

  auto_tween: `You are StickDeath AI, a motion interpolation expert.
Given start and end joint positions for a stick figure, generate intermediate frames
that create smooth, natural-looking motion with proper easing.
Apply principles of: ease-in/out, arc motion, overlapping action, and secondary motion.
Return as JSON: { "frames": [{ "index": number, "joints": Record<string, {x, y}> }] }
Each frame should represent one intermediate position.`,

  scene_compose: `You are StickDeath AI, a scene composition expert.
Given the current canvas and figures, suggest scene improvements:
- Camera angles and framing
- Figure placement for visual impact
- Action sequences and choreography
- Environmental elements
Return as JSON: { "suggestions": [{ "type": string, "description": string, "changes": object }] }`,

  general: `You are StickDeath AI, a helpful assistant for stick figure animation.
Help the user with any animation-related question. Be concise and practical.
If the question involves specific poses or movements, include joint coordinates.
Return as JSON: { "message": string, "suggestions"?: any[] }`,
};

// ─── Rate Limiting ───────────────────────────────────────────────────────────

async function checkAndUpdateLimits(
  adminClient: ReturnType<typeof createAdminClient>,
  userId: string,
  userRole: string,
): Promise<{ allowed: boolean; remaining: number; limit: number }> {
  const today = new Date().toISOString().split('T')[0];
  const limit = DAILY_LIMITS[userRole] ?? DAILY_LIMITS.free;

  // Get or create today's usage record
  const { data: usage } = await adminClient
    .from('ai_limits')
    .select('*')
    .eq('user_id', userId)
    .eq('date', today)
    .single();

  if (!usage) {
    // First use today — create record
    await adminClient.from('ai_limits').insert({
      user_id: userId,
      date: today,
      calls_used: 1,
      calls_limit: limit,
    });
    return { allowed: true, remaining: limit - 1, limit };
  }

  if (usage.calls_used >= limit) {
    return { allowed: false, remaining: 0, limit };
  }

  // Increment usage
  await adminClient
    .from('ai_limits')
    .update({ calls_used: usage.calls_used + 1 })
    .eq('user_id', userId)
    .eq('date', today);

  return { allowed: true, remaining: limit - usage.calls_used - 1, limit };
}

// ─── OpenAI Call ─────────────────────────────────────────────────────────────

async function callOpenAI(
  systemPrompt: string,
  userMessage: string,
  maxTokens = 2000,
): Promise<string> {
  const response = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userMessage },
      ],
      max_tokens: maxTokens,
      temperature: 0.7,
      response_format: { type: 'json_object' },
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`OpenAI API error: ${err}`);
  }

  const data = await response.json();
  return data.choices?.[0]?.message?.content ?? '{}';
}

// ─── Build User Message ──────────────────────────────────────────────────────

function buildUserMessage(body: AssistRequest): string {
  const parts: string[] = [];

  if (body.prompt) {
    parts.push(`User request: ${body.prompt}`);
  }

  if (body.project_state) {
    const ps = body.project_state;
    parts.push(`\nProject state:`);
    parts.push(`- Canvas: ${ps.canvas_size.width}x${ps.canvas_size.height}`);
    parts.push(`- Frames: ${ps.frame_count} at ${ps.fps}fps`);
    parts.push(`- Current frame: ${ps.current_frame_index}`);
    parts.push(`- Figures: ${JSON.stringify(ps.figures)}`);
  }

  if (body.tween_config && body.mode === 'auto_tween') {
    const tc = body.tween_config;
    parts.push(`\nTween configuration:`);
    parts.push(`- Frame range: ${tc.start_frame} to ${tc.end_frame}`);
    parts.push(`- Figure ID: ${tc.figure_id}`);
    parts.push(`- Easing: ${tc.easing ?? 'ease-in-out'}`);
    parts.push(`- Intermediate frames requested: ${tc.num_intermediate_frames ?? 'auto'}`);
    parts.push(`- Start joints: ${JSON.stringify(tc.start_joints)}`);
    parts.push(`- End joints: ${JSON.stringify(tc.end_joints)}`);
  }

  return parts.join('\n') || 'Help me with stick figure animation.';
}

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  try {
    if (req.method !== 'POST') {
      return errorResponse('Method not allowed', 405);
    }

    const { user, adminClient } = await verifyAuth(req);
    const body: AssistRequest = await req.json();

    const mode = body.mode ?? 'general';

    // Validate mode
    if (!SYSTEM_PROMPTS[mode]) {
      return errorResponse(`Invalid mode: ${mode}`);
    }

    // Check rate limits
    const { allowed, remaining, limit } = await checkAndUpdateLimits(
      adminClient,
      user.id,
      user.role ?? 'free',
    );

    if (!allowed) {
      const isPro = user.role === 'pro' || user.role === 'admin';
      return jsonResponse(
        {
          error: 'Daily AI limit reached',
          limit,
          remaining: 0,
          upgrade_hint: isPro
            ? undefined
            : 'Upgrade to Pro for 100 AI assists per day!',
        },
        429,
      );
    }

    // Build the prompt and call OpenAI
    const systemPrompt = SYSTEM_PROMPTS[mode];
    const userMessage = buildUserMessage(body);

    const maxTokens = mode === 'auto_tween' ? 4000 : 2000;
    const aiResult = await callOpenAI(systemPrompt, userMessage, maxTokens);

    // Parse the JSON response
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(aiResult);
    } catch {
      parsed = { message: aiResult };
    }

    // Log usage for analytics
    await adminClient.from('ai_jobs').insert({
      user_id: user.id,
      mode,
      prompt_length: userMessage.length,
      response_length: aiResult.length,
      created_at: new Date().toISOString(),
    });

    return jsonResponse({
      mode,
      ...parsed,
      _meta: {
        remaining_today: remaining,
        daily_limit: limit,
      },
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.message, err.status);
    }
    console.error('ai-assist error:', err);
    return errorResponse('Internal server error', 500);
  }
});
