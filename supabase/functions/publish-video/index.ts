/**
 * publish-video — Supabase Edge Function
 *
 * Publishes a rendered video to:
 *   1. StickDeath OFFICIAL channels (YouTube, TikTok, Discord) — ALWAYS watermarked
 *   2. User's own connected social accounts — watermark depends on Pro status
 *
 * Accepts either a render_jobs completion webhook or a direct authenticated call.
 * Updates publish_jobs table with per-platform status.
 *
 * Watermark rule:
 *   - Official channels: ALWAYS watermarked (even for Pro users)
 *   - User channels:     watermark for Free users, removable for Pro
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { corsHeaders, handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { verifyAuth, AuthError } from '../_shared/auth.ts';
import {
  OFFICIAL_CHANNELS,
  WATERMARK_TEXT,
  WATERMARK_TAGLINE,
  shouldWatermark,
} from '../_shared/official-channels.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

type Platform = 'youtube' | 'tiktok' | 'instagram' | 'facebook' | 'discord';

interface PublishRequest {
  render_job_id: string;
  platforms?: Platform[];
  publish_to_own_channels?: boolean;
  title?: string;
  description?: string;
  account_type?: 'official' | 'user' | 'both';
  /** Pro users can request no watermark on their personal copy */
  watermark?: boolean;
}

interface PlatformResult {
  platform: string;
  target: 'official' | 'user';
  status: 'published' | 'failed';
  external_id?: string;
  external_url?: string;
  error?: string;
}

interface RenderJob {
  id: string;
  project_id: string;
  user_id: string;
  status: string;
  output_url: string;
  output_url_watermarked?: string;
}

interface Project {
  id: string;
  title: string;
  description: string | null;
  tags: string[] | null;
  user_id: string;
}

interface SocialToken {
  platform: Platform;
  access_token: string;
  refresh_token: string | null;
  token_expires_at: string | null;
  platform_user_id: string;
}

// ─── Platform Publishers ─────────────────────────────────────────────────────

async function publishToYouTube(
  videoUrl: string,
  title: string,
  description: string,
  tags: string[],
  accessToken: string,
  isOfficial: boolean,
): Promise<PlatformResult> {
  try {
    const videoRes = await fetch(videoUrl);
    if (!videoRes.ok) throw new Error('Failed to download video');
    const videoBlob = await videoRes.blob();

    const desc = isOfficial
      ? `${description}\n\n🎬 ${WATERMARK_TAGLINE}\n🔥 Download the app: stickdeath.com`
      : `${description}\n\n🎬 ${WATERMARK_TAGLINE}`;

    const initRes = await fetch(
      'https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status',
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
          'X-Upload-Content-Type': 'video/mp4',
          'X-Upload-Content-Length': String(videoBlob.size),
        },
        body: JSON.stringify({
          snippet: {
            title: title.slice(0, 100),
            description: desc,
            tags: [...tags, 'stickdeath', 'animation', 'stickfigure', 'stickdeathinf'],
            categoryId: '24', // Entertainment
          },
          status: {
            privacyStatus: 'public',
            selfDeclaredMadeForKids: false,
            madeForKids: false,
          },
        }),
      },
    );

    if (!initRes.ok) {
      const err = await initRes.text();
      throw new Error(`YouTube init failed: ${err}`);
    }

    const uploadUrl = initRes.headers.get('Location');
    if (!uploadUrl) throw new Error('No upload URL returned');

    const uploadRes = await fetch(uploadUrl, {
      method: 'PUT',
      headers: { 'Content-Type': 'video/mp4' },
      body: videoBlob,
    });

    if (!uploadRes.ok) throw new Error(`YouTube upload failed: ${await uploadRes.text()}`);
    const result = await uploadRes.json();

    return {
      platform: 'youtube',
      target: isOfficial ? 'official' : 'user',
      status: 'published',
      external_id: result.id,
      external_url: `https://youtube.com/shorts/${result.id}`,
    };
  } catch (err) {
    return {
      platform: 'youtube',
      target: isOfficial ? 'official' : 'user',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown YouTube error',
    };
  }
}

async function publishToTikTok(
  videoUrl: string,
  title: string,
  accessToken: string,
  isOfficial: boolean,
): Promise<PlatformResult> {
  try {
    const caption = isOfficial
      ? `${title} 🔥 ${WATERMARK_TAGLINE} #stickdeath #animation #stickfigure`
      : `${title} #stickdeath #animation`;

    const initRes = await fetch(
      'https://open.tiktokapis.com/v2/post/publish/video/init/',
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          post_info: {
            title: caption.slice(0, 150),
            privacy_level: 'PUBLIC_TO_EVERYONE',
            disable_duet: false,
            disable_comment: false,
            disable_stitch: false,
          },
          source_info: {
            source: 'PULL_FROM_URL',
            video_url: videoUrl,
          },
        }),
      },
    );

    if (!initRes.ok) throw new Error(`TikTok init failed: ${await initRes.text()}`);
    const result = await initRes.json();

    return {
      platform: 'tiktok',
      target: isOfficial ? 'official' : 'user',
      status: 'published',
      external_id: result.data?.publish_id,
    };
  } catch (err) {
    return {
      platform: 'tiktok',
      target: isOfficial ? 'official' : 'user',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown TikTok error',
    };
  }
}

async function publishToInstagram(
  videoUrl: string,
  caption: string,
  accessToken: string,
  igUserId: string,
  isOfficial: boolean,
): Promise<PlatformResult> {
  try {
    const fullCaption = isOfficial
      ? `${caption}\n\n🎬 ${WATERMARK_TAGLINE}\n🔥 Download the app!\n#stickdeath #animation #stickfigure #shorts`
      : `${caption}\n\n🎬 ${WATERMARK_TAGLINE} #stickdeath #animation`;

    const containerRes = await fetch(
      `https://graph.facebook.com/v18.0/${igUserId}/media`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          media_type: 'REELS',
          video_url: videoUrl,
          caption: fullCaption,
          access_token: accessToken,
        }),
      },
    );

    if (!containerRes.ok) throw new Error(`IG container failed: ${await containerRes.text()}`);
    const container = await containerRes.json();
    const containerId = container.id;

    let ready = false;
    for (let i = 0; i < 30; i++) {
      const statusRes = await fetch(
        `https://graph.facebook.com/v18.0/${containerId}?fields=status_code&access_token=${accessToken}`,
      );
      const statusData = await statusRes.json();
      if (statusData.status_code === 'FINISHED') { ready = true; break; }
      if (statusData.status_code === 'ERROR') throw new Error('IG processing failed');
      await new Promise((r) => setTimeout(r, 2000));
    }
    if (!ready) throw new Error('IG processing timed out');

    const publishRes = await fetch(
      `https://graph.facebook.com/v18.0/${igUserId}/media_publish`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ creation_id: containerId, access_token: accessToken }),
      },
    );

    if (!publishRes.ok) throw new Error(`IG publish failed: ${await publishRes.text()}`);
    const result = await publishRes.json();

    return {
      platform: 'instagram',
      target: isOfficial ? 'official' : 'user',
      status: 'published',
      external_id: result.id,
    };
  } catch (err) {
    return {
      platform: 'instagram',
      target: isOfficial ? 'official' : 'user',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown IG error',
    };
  }
}

async function publishToFacebook(
  videoUrl: string,
  title: string,
  description: string,
  accessToken: string,
  pageId: string,
  isOfficial: boolean,
): Promise<PlatformResult> {
  try {
    const initRes = await fetch(
      `https://graph.facebook.com/v18.0/${pageId}/videos`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          file_url: videoUrl,
          title: title.slice(0, 100),
          description: `${description}\n\n🎬 ${WATERMARK_TAGLINE}`,
          access_token: accessToken,
        }),
      },
    );

    if (!initRes.ok) throw new Error(`FB upload failed: ${await initRes.text()}`);
    const result = await initRes.json();

    return {
      platform: 'facebook',
      target: isOfficial ? 'official' : 'user',
      status: 'published',
      external_id: result.id,
      external_url: `https://facebook.com/${result.id}`,
    };
  } catch (err) {
    return {
      platform: 'facebook',
      target: isOfficial ? 'official' : 'user',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown FB error',
    };
  }
}

/**
 * Post to the official StickDeath Discord channel via webhook.
 * Uses Discord's execute webhook endpoint.
 */
async function publishToDiscord(
  videoUrl: string,
  title: string,
  creatorName: string,
  webhookUrl: string,
): Promise<PlatformResult> {
  try {
    if (!webhookUrl) throw new Error('Discord webhook URL not configured');

    const res = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        username: 'StickDeath ∞',
        avatar_url: 'https://iohubnamsqnzyburydxr.supabase.co/storage/v1/object/public/app-assets/stickdeath-avatar.png',
        embeds: [
          {
            title: `🎬 ${title}`,
            description: `New animation by **${creatorName}**!\n\nMade with StickDeath Infinity`,
            color: 0xff2d55, // brandPink
            video: { url: videoUrl },
            thumbnail: {
              url: 'https://iohubnamsqnzyburydxr.supabase.co/storage/v1/object/public/app-assets/stickdeath-logo.png',
            },
            footer: {
              text: 'StickDeath ∞ — Create. Animate. Annihilate.',
            },
            timestamp: new Date().toISOString(),
          },
        ],
      }),
    });

    if (!res.ok) throw new Error(`Discord webhook failed: ${await res.text()}`);

    return {
      platform: 'discord',
      target: 'official',
      status: 'published',
    };
  } catch (err) {
    return {
      platform: 'discord',
      target: 'official',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown Discord error',
    };
  }
}

// ─── Token Refresh Helper ────────────────────────────────────────────────────

async function getValidToken(
  adminClient: ReturnType<typeof createAdminClient>,
  userId: string,
  platform: Platform,
): Promise<SocialToken | null> {
  const { data: token } = await adminClient
    .from('social_tokens')
    .select('*')
    .eq('user_id', userId)
    .eq('platform', platform)
    .single();

  if (!token) return null;

  if (token.token_expires_at) {
    const expiresAt = new Date(token.token_expires_at).getTime();
    const now = Date.now() - 5 * 60 * 1000;
    if (expiresAt < now && token.refresh_token) {
      const refreshed = await refreshPlatformToken(platform, token.refresh_token);
      if (refreshed) {
        await adminClient
          .from('social_tokens')
          .update({
            access_token: refreshed.access_token,
            token_expires_at: refreshed.expires_at,
          })
          .eq('user_id', userId)
          .eq('platform', platform);
        return { ...token, access_token: refreshed.access_token };
      }
      return null;
    }
  }

  return token as SocialToken;
}

async function refreshPlatformToken(
  platform: Platform,
  refreshToken: string,
): Promise<{ access_token: string; expires_at: string } | null> {
  try {
    switch (platform) {
      case 'youtube': {
        const res = await fetch('https://oauth2.googleapis.com/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: Deno.env.get('GOOGLE_CLIENT_ID')!,
            client_secret: Deno.env.get('GOOGLE_CLIENT_SECRET')!,
            refresh_token: refreshToken,
            grant_type: 'refresh_token',
          }),
        });
        const data = await res.json();
        if (!data.access_token) return null;
        return {
          access_token: data.access_token,
          expires_at: new Date(Date.now() + data.expires_in * 1000).toISOString(),
        };
      }
      case 'tiktok': {
        const res = await fetch('https://open.tiktokapis.com/v2/oauth/token/', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_key: Deno.env.get('TIKTOK_CLIENT_KEY')!,
            client_secret: Deno.env.get('TIKTOK_CLIENT_SECRET')!,
            grant_type: 'refresh_token',
            refresh_token: refreshToken,
          }),
        });
        const data = await res.json();
        if (!data.data?.access_token) return null;
        return {
          access_token: data.data.access_token,
          expires_at: new Date(Date.now() + data.data.expires_in * 1000).toISOString(),
        };
      }
      case 'facebook':
      case 'instagram': {
        const res = await fetch(
          `https://graph.facebook.com/v18.0/oauth/access_token?grant_type=fb_exchange_token&client_id=${Deno.env.get('FACEBOOK_APP_ID')}&client_secret=${Deno.env.get('FACEBOOK_APP_SECRET')}&fb_exchange_token=${refreshToken}`,
        );
        const data = await res.json();
        if (!data.access_token) return null;
        return {
          access_token: data.access_token,
          expires_at: new Date(Date.now() + (data.expires_in ?? 5184000) * 1000).toISOString(),
        };
      }
      default:
        return null;
    }
  } catch {
    return null;
  }
}

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  try {
    const adminClient = createAdminClient();

    let userId: string;
    let body: PublishRequest;

    const rawBody = await req.json();

    // Render completion webhook (no auth)
    if (rawBody.type === 'render.completed' && rawBody.render_job_id) {
      body = { render_job_id: rawBody.render_job_id };
      const { data: job } = await adminClient
        .from('render_jobs')
        .select('user_id')
        .eq('id', rawBody.render_job_id)
        .single();
      if (!job) return errorResponse('Render job not found', 404);
      userId = job.user_id;
    } else {
      // Direct call — requires auth
      const authHeader = req.headers.get('Authorization');
      if (!authHeader) return errorResponse('Missing Authorization', 401);
      const token = authHeader.replace('Bearer ', '');
      const { data: { user }, error } = await adminClient.auth.getUser(token);
      if (error || !user) return errorResponse('Invalid token', 401);
      userId = user.id;
      body = rawBody as PublishRequest;
    }

    const {
      render_job_id,
      platforms,
      publish_to_own_channels,
      title: reqTitle,
      description: reqDesc,
      account_type = 'both',
    } = body;

    // ── Fetch render job ──
    const { data: renderJob, error: rjError } = await adminClient
      .from('render_jobs')
      .select('*')
      .eq('id', render_job_id)
      .single();

    if (rjError || !renderJob) return errorResponse('Render job not found', 404);

    const job = renderJob as RenderJob;
    if (job.status !== 'completed' || !job.output_url) {
      return errorResponse('Render job not completed or has no output', 400);
    }

    // Determine which video URLs to use
    const watermarkedUrl = job.output_url_watermarked || job.output_url;
    const cleanUrl = job.output_url;

    // ── Fetch project metadata ──
    const { data: project } = await adminClient
      .from('studio_projects')
      .select('id, title, description, tags, user_id')
      .eq('id', job.project_id)
      .single();

    if (!project) return errorResponse('Project not found', 404);
    const proj = project as Project;

    // ── Check if user is Pro ──
    const { data: profile } = await adminClient
      .from('profiles')
      .select('subscription_tier, display_name, username')
      .eq('id', userId)
      .single();

    const isPro = profile?.subscription_tier === 'pro';
    const creatorName = profile?.display_name || profile?.username || 'Anonymous';

    const title = reqTitle || proj.title || 'StickDeath Animation';
    const description = reqDesc || proj.description || 'Check out this stick figure animation!';
    const tags = proj.tags || ['stickdeath', 'animation'];

    // ── Create publish_job record ──
    const { data: publishJob, error: pjError } = await adminClient
      .from('publish_jobs')
      .insert({
        render_job_id: render_job_id,
        project_id: proj.id,
        user_id: userId,
        status: 'publishing',
        title,
        description,
        provider: account_type,
      })
      .select()
      .single();

    if (pjError) return errorResponse(`Failed to create publish job: ${pjError.message}`, 500);

    const allResults: PlatformResult[] = [];

    // ════════════════════════════════════════════════════════════════
    // 1) OFFICIAL CHANNELS — Always watermarked
    // ════════════════════════════════════════════════════════════════

    if (account_type === 'official' || account_type === 'both') {
      const officialPromises: Promise<PlatformResult>[] = [];

      // YouTube → @stickdeath.infinity
      const ytToken = Deno.env.get('STICKDEATH_YOUTUBE_TOKEN');
      if (ytToken) {
        officialPromises.push(
          publishToYouTube(watermarkedUrl, title, description, tags, ytToken, true),
        );
      }

      // TikTok → @stickdeath.infinity
      const ttToken = Deno.env.get('STICKDEATH_TIKTOK_TOKEN');
      if (ttToken) {
        officialPromises.push(
          publishToTikTok(watermarkedUrl, title, ttToken, true),
        );
      }

      // Instagram (if configured)
      const igToken = Deno.env.get('STICKDEATH_INSTAGRAM_TOKEN');
      const igUserId = Deno.env.get('STICKDEATH_INSTAGRAM_USER_ID');
      if (igToken && igUserId) {
        officialPromises.push(
          publishToInstagram(watermarkedUrl, `${title} — ${description}`, igToken, igUserId, true),
        );
      }

      // Facebook (if configured)
      const fbToken = Deno.env.get('STICKDEATH_FACEBOOK_TOKEN');
      const fbPageId = Deno.env.get('STICKDEATH_FACEBOOK_PAGE_ID');
      if (fbToken && fbPageId) {
        officialPromises.push(
          publishToFacebook(watermarkedUrl, title, description, fbToken, fbPageId, true),
        );
      }

      // Discord → #stickdeath_infinity
      const discordWebhookUrl = Deno.env.get('STICKDEATH_DISCORD_WEBHOOK_URL');
      if (discordWebhookUrl) {
        officialPromises.push(
          publishToDiscord(watermarkedUrl, title, creatorName, discordWebhookUrl),
        );
      }

      allResults.push(...(await Promise.all(officialPromises)));
    }

    // ════════════════════════════════════════════════════════════════
    // 2) USER'S OWN CHANNELS — watermark based on Pro status
    // ════════════════════════════════════════════════════════════════

    if (
      (account_type === 'user' || account_type === 'both') &&
      publish_to_own_channels !== false
    ) {
      // Pro users get the clean URL; free users get watermarked
      const userVideoUrl = shouldWatermark('user', isPro) ? watermarkedUrl : cleanUrl;

      const userPlatforms: Platform[] =
        (platforms as Platform[]) ?? ['youtube', 'tiktok', 'instagram', 'facebook'];

      const userPromises: Promise<PlatformResult>[] = [];

      for (const platform of userPlatforms) {
        if (platform === 'discord') continue; // No user Discord publishing
        const token = await getValidToken(adminClient, userId, platform);
        if (!token) continue;

        switch (platform) {
          case 'youtube':
            userPromises.push(
              publishToYouTube(userVideoUrl, title, description, tags, token.access_token, false),
            );
            break;
          case 'tiktok':
            userPromises.push(
              publishToTikTok(userVideoUrl, title, token.access_token, false),
            );
            break;
          case 'instagram':
            userPromises.push(
              publishToInstagram(
                userVideoUrl,
                `${title} — ${description}`,
                token.access_token,
                token.platform_user_id,
                false,
              ),
            );
            break;
          case 'facebook':
            userPromises.push(
              publishToFacebook(
                userVideoUrl,
                title,
                description,
                token.access_token,
                token.platform_user_id,
                false,
              ),
            );
            break;
        }
      }

      allResults.push(...(await Promise.all(userPromises)));
    }

    // ── Determine overall status ──
    const anySuccess = allResults.some((r) => r.status === 'published');
    const allFailed = allResults.length > 0 && allResults.every((r) => r.status === 'failed');
    const overallStatus = allFailed ? 'failed' : anySuccess ? 'published' : 'no_platforms';

    // Split results by target
    const officialResults = allResults.filter((r) => r.target === 'official');
    const userResults = allResults.filter((r) => r.target === 'user');

    // Update publish_job
    await adminClient
      .from('publish_jobs')
      .update({
        status: overallStatus,
        platform_video_id: allResults.find((r) => r.external_id)?.external_id ?? null,
        platform_url: allResults.find((r) => r.external_url)?.external_url ?? null,
        error_message: allFailed
          ? allResults.map((r) => `${r.platform}: ${r.error}`).join('; ')
          : null,
        completed_at: new Date().toISOString(),
      })
      .eq('id', publishJob.id);

    // If any succeeded, mark project as published
    if (anySuccess) {
      await adminClient
        .from('studio_projects')
        .update({ is_published: true, published_at: new Date().toISOString() })
        .eq('id', proj.id);

      // Notify the creator
      await adminClient.from('notifications').insert({
        user_id: userId,
        type: 'publish_completed',
        message: `Your animation "${title}" was published to ${officialResults.filter((r) => r.status === 'published').length} official channels!`,
      });
    }

    return jsonResponse({
      publish_job_id: publishJob.id,
      status: overallStatus,
      watermark_applied: {
        official: true,
        user: shouldWatermark('user', isPro),
      },
      official_results: officialResults,
      user_results: userResults,
    });
  } catch (err) {
    if (err instanceof AuthError) return errorResponse(err.message, err.status);
    console.error('publish-video error:', err);
    return errorResponse('Internal server error', 500);
  }
});
