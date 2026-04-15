/**
 * render-video — Supabase Edge Function
 *
 * Takes a project ID, fetches all frames from Supabase storage,
 * sends them to an FFmpeg rendering service to produce an MP4.
 * Stores the result in Supabase storage and updates render_jobs table.
 *
 * Supports watermark overlay — the render worker produces both a
 * watermarked and a clean version. The watermarked copy is used for
 * official StickDeath channels; the clean copy for Pro user exports.
 *
 * Architecture: Since edge functions can't run FFmpeg directly, we
 * delegate to an external render worker service (self-hosted or cloud).
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { verifyAuth, AuthError } from '../_shared/auth.ts';
import { WATERMARK_TEXT, WATERMARK_TAGLINE } from '../_shared/official-channels.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

interface RenderRequest {
  project_id: string;
  fps?: number;
  resolution?: '720p' | '1080p' | '4k';
  format?: 'mp4' | 'webm' | 'gif';
  quality?: 'draft' | 'standard' | 'high';
  /** Whether to produce a watermarked copy (default: true) */
  watermark?: boolean;
  /** Override watermark text */
  watermark_text?: string;
}

interface Frame {
  index: number;
  storage_path: string;
  duration_ms: number;
}

interface RenderWorkerPayload {
  job_id: string;
  frames: Array<{
    url: string;
    duration_ms: number;
    index: number;
  }>;
  fps: number;
  resolution: string;
  format: string;
  quality: string;
  output_bucket: string;
  output_path: string;
  /** Path for the watermarked version (separate file) */
  output_path_watermarked: string;
  webhook_url: string;
  /** Watermark configuration for the render worker */
  watermark: {
    enabled: boolean;
    text: string;
    position: 'bottom-right';
    opacity: number;
    font_size: number;
    include_stick_figure: boolean;
  };
}

// ─── Constants ───────────────────────────────────────────────────────────────

const RENDER_WORKER_URL = Deno.env.get('RENDER_WORKER_URL') ?? 'http://render-worker:8080';
const RENDER_WEBHOOK_SECRET = Deno.env.get('RENDER_WEBHOOK_SECRET') ?? '';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const FUNCTIONS_URL = `${SUPABASE_URL}/functions/v1`;

const RESOLUTION_MAP: Record<string, { width: number; height: number }> = {
  '720p': { width: 1280, height: 720 },
  '1080p': { width: 1920, height: 1080 },
  '4k': { width: 3840, height: 2160 },
};

const MAX_FRAMES_FREE = 100;
const MAX_FRAMES_PRO = 1000;

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  // Handle webhook callbacks from the render worker
  if (req.method === 'POST' && new URL(req.url).searchParams.get('webhook') === 'true') {
    return handleRenderWebhook(req);
  }

  try {
    const { user, adminClient } = await verifyAuth(req);
    const body: RenderRequest = await req.json();

    const {
      project_id,
      fps = 24,
      resolution = '1080p',
      format = 'mp4',
      quality = 'standard',
      watermark = true,
      watermark_text,
    } = body;

    if (!project_id) {
      return errorResponse('project_id is required');
    }

    if (!RESOLUTION_MAP[resolution]) {
      return errorResponse(`Invalid resolution: ${resolution}. Use 720p, 1080p, or 4k`);
    }

    // 4k requires Pro
    if (resolution === '4k') {
      const { data: sub } = await adminClient
        .from('subscriptions')
        .select('status')
        .eq('user_id', user.id)
        .in('status', ['active', 'trialing'])
        .single();

      if (!sub) {
        return errorResponse('4K rendering requires a Pro subscription', 403);
      }
    }

    // Verify project belongs to this user
    const { data: project, error: projError } = await adminClient
      .from('studio_projects')
      .select('id, user_id, title, frame_count')
      .eq('id', project_id)
      .single();

    if (projError || !project) return errorResponse('Project not found', 404);

    if (project.user_id !== user.id && user.role !== 'admin') {
      return errorResponse('Not authorized to render this project', 403);
    }

    // Check for existing active render
    const { data: activeJob } = await adminClient
      .from('render_jobs')
      .select('id, status')
      .eq('project_id', project_id)
      .in('status', ['queued', 'rendering'])
      .single();

    if (activeJob) {
      return errorResponse(
        `A render is already in progress (${activeJob.id}). Wait for it to complete.`,
        409,
      );
    }

    // Fetch frames
    const { data: frames, error: framesError } = await adminClient
      .from('studio_project_versions')
      .select('index, storage_path, duration_ms')
      .eq('project_id', project_id)
      .order('index', { ascending: true });

    if (framesError || !frames || frames.length === 0) {
      return errorResponse('No frames found for this project', 400);
    }

    // Check frame limits
    const isPro = user.role === 'pro' || user.role === 'admin';
    const maxFrames = isPro ? MAX_FRAMES_PRO : MAX_FRAMES_FREE;
    if (frames.length > maxFrames) {
      return errorResponse(
        `Frame limit exceeded (${frames.length}/${maxFrames}). ${isPro ? '' : 'Upgrade to Pro for up to 1000 frames.'}`,
        400,
      );
    }

    // Generate signed URLs for each frame
    const frameUrls = await Promise.all(
      (frames as Frame[]).map(async (frame) => {
        const { data: signedUrl } = await adminClient.storage
          .from('studio_project_versions')
          .createSignedUrl(frame.storage_path, 3600);

        return {
          index: frame.index,
          url: signedUrl?.signedUrl ?? '',
          duration_ms: frame.duration_ms || Math.round(1000 / fps),
        };
      }),
    );

    const validFrames = frameUrls.filter((f) => f.url !== '');
    if (validFrames.length === 0) {
      return errorResponse('Failed to generate frame URLs', 500);
    }

    // Output paths — clean version + watermarked version
    const ts = Date.now();
    const outputPath = `renders/${user.id}/${project_id}/${ts}.${format}`;
    const outputPathWatermarked = `renders/${user.id}/${project_id}/${ts}_wm.${format}`;

    // Create render job record
    const { data: renderJob, error: rjError } = await adminClient
      .from('render_jobs')
      .insert({
        project_id,
        user_id: user.id,
        status: 'queued',
        fps,
        width: RESOLUTION_MAP[resolution].width,
        height: RESOLUTION_MAP[resolution].height,
        format,
        frame_count: validFrames.length,
        output_path: outputPath,
      })
      .select()
      .single();

    if (rjError || !renderJob) {
      return errorResponse(`Failed to create render job: ${rjError?.message}`, 500);
    }

    // Build render worker payload with watermark config
    const workerPayload: RenderWorkerPayload = {
      job_id: renderJob.id,
      frames: validFrames,
      fps,
      resolution,
      format,
      quality,
      output_bucket: 'rendered-videos',
      output_path: outputPath,
      output_path_watermarked: outputPathWatermarked,
      webhook_url: `${FUNCTIONS_URL}/render-video?webhook=true`,
      watermark: {
        enabled: watermark,
        text: watermark_text || WATERMARK_TAGLINE,
        position: 'bottom-right',
        opacity: 0.6,
        font_size: 14,
        include_stick_figure: true,
      },
    };

    // Send to render worker
    const workerResponse = await fetch(`${RENDER_WORKER_URL}/render`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Webhook-Secret': RENDER_WEBHOOK_SECRET,
      },
      body: JSON.stringify(workerPayload),
    });

    if (!workerResponse.ok) {
      await adminClient
        .from('render_jobs')
        .update({ status: 'failed', error_message: 'Render worker rejected the job' })
        .eq('id', renderJob.id);

      console.error('Render worker error:', await workerResponse.text());
      return errorResponse('Render service is unavailable. Please try again later.', 503);
    }

    // Update job to rendering status
    await adminClient
      .from('render_jobs')
      .update({ status: 'rendering', started_at: new Date().toISOString() })
      .eq('id', renderJob.id);

    return jsonResponse({
      render_job_id: renderJob.id,
      status: 'rendering',
      watermark_enabled: watermark,
      estimated_duration_s: Math.ceil(validFrames.length / fps) * 2,
      message: 'Render started. You will be notified when complete.',
    });
  } catch (err) {
    if (err instanceof AuthError) return errorResponse(err.message, err.status);
    console.error('render-video error:', err);
    return errorResponse('Internal server error', 500);
  }
});

// ─── Webhook Handler (called by render worker on completion) ─────────────────

async function handleRenderWebhook(req: Request): Promise<Response> {
  try {
    const webhookSecret = req.headers.get('x-webhook-secret');
    if (webhookSecret !== RENDER_WEBHOOK_SECRET) {
      return errorResponse('Invalid webhook secret', 403);
    }

    const body = await req.json();
    const {
      job_id,
      status,
      output_url,
      output_url_watermarked,
      error: renderError,
      duration_s,
    } = body;

    if (!job_id) return errorResponse('job_id is required');

    const adminClient = createAdminClient();

    if (status === 'completed' && output_url) {
      // Update render job as completed — store both URLs
      await adminClient
        .from('render_jobs')
        .update({
          status: 'completed',
          output_url,
          output_url_watermarked: output_url_watermarked ?? null,
          completed_at: new Date().toISOString(),
        })
        .eq('id', job_id);

      // Notify the user
      const { data: job } = await adminClient
        .from('render_jobs')
        .select('project_id, user_id')
        .eq('id', job_id)
        .single();

      if (job) {
        await adminClient.from('notifications').insert({
          user_id: job.user_id,
          type: 'render_completed',
          message: 'Your animation has been rendered! Tap to view and publish.',
        });
      }
    } else {
      await adminClient
        .from('render_jobs')
        .update({
          status: 'failed',
          error_message: renderError ?? 'Unknown render error',
          completed_at: new Date().toISOString(),
        })
        .eq('id', job_id);
    }

    return jsonResponse({ received: true });
  } catch (err) {
    console.error('render webhook error:', err);
    return errorResponse('Internal server error', 500);
  }
}
