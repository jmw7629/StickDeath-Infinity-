/**
 * publish-video — Supabase Edge Function
 *
 * Receives a render_jobs completion webhook or direct call.
 * Takes the rendered MP4 URL and publishes to platform channels:
 *   - YouTube (Data API v3)
 *   - TikTok (Content Posting API)
 *   - Instagram (Graph API — Reels)
 *   - Facebook (Graph API — Video)
 *
 * Also publishes to user's own connected social accounts.
 * Updates publish_jobs table with per-platform status.
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { corsHeaders, handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { verifyAuth, AuthError } from '../_shared/auth.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

type Platform = 'youtube' | 'tiktok' | 'instagram' | 'facebook';

interface PublishRequest {
  render_job_id: string;
  platforms?: Platform[];
  publish_to_own_channels?: boolean;
}

interface PlatformResult {
  platform: Platform;
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
): Promise<PlatformResult> {
  try {
    // Step 1: Download the video to a buffer
    const videoRes = await fetch(videoUrl);
    if (!videoRes.ok) throw new Error('Failed to download video');
    const videoBlob = await videoRes.blob();

    // Step 2: Initialize resumable upload
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
            description: `${description}\n\n🎬 Made with StickDeath Infinity`,
            tags: [...tags, 'stickdeath', 'animation', 'stickfigure'],
            categoryId: '24', // Entertainment
          },
          status: {
            privacyStatus: 'public',
            selfDeclaredMadeForKids: false,
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

    // Step 3: Upload the video bytes
    const uploadRes = await fetch(uploadUrl, {
      method: 'PUT',
      headers: { 'Content-Type': 'video/mp4' },
      body: videoBlob,
    });

    if (!uploadRes.ok) {
      const err = await uploadRes.text();
      throw new Error(`YouTube upload failed: ${err}`);
    }

    const result = await uploadRes.json();

    return {
      platform: 'youtube',
      status: 'published',
      external_id: result.id,
      external_url: `https://youtube.com/watch?v=${result.id}`,
    };
  } catch (err) {
    return {
      platform: 'youtube',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown YouTube error',
    };
  }
}

async function publishToTikTok(
  videoUrl: string,
  title: string,
  accessToken: string,
): Promise<PlatformResult> {
  try {
    // Step 1: Initialize video upload via TikTok Content Posting API
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
            title: title.slice(0, 150),
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

    if (!initRes.ok) {
      const err = await initRes.text();
      throw new Error(`TikTok init failed: ${err}`);
    }

    const result = await initRes.json();
    const publishId = result.data?.publish_id;

    return {
      platform: 'tiktok',
      status: 'published',
      external_id: publishId ?? undefined,
    };
  } catch (err) {
    return {
      platform: 'tiktok',
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
): Promise<PlatformResult> {
  try {
    // Step 1: Create a media container for the Reel
    const containerRes = await fetch(
      `https://graph.facebook.com/v18.0/${igUserId}/media`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          media_type: 'REELS',
          video_url: videoUrl,
          caption: `${caption}\n\n🎬 Made with StickDeath Infinity #stickdeath #animation #stickfigure`,
          access_token: accessToken,
        }),
      },
    );

    if (!containerRes.ok) {
      const err = await containerRes.text();
      throw new Error(`IG container failed: ${err}`);
    }

    const container = await containerRes.json();
    const containerId = container.id;

    // Step 2: Poll until container is ready (IG processes async)
    let ready = false;
    for (let i = 0; i < 30; i++) {
      const statusRes = await fetch(
        `https://graph.facebook.com/v18.0/${containerId}?fields=status_code&access_token=${accessToken}`,
      );
      const statusData = await statusRes.json();

      if (statusData.status_code === 'FINISHED') {
        ready = true;
        break;
      }
      if (statusData.status_code === 'ERROR') {
        throw new Error('IG container processing failed');
      }
      // Wait 2 seconds before polling again
      await new Promise((r) => setTimeout(r, 2000));
    }

    if (!ready) throw new Error('IG container processing timed out');

    // Step 3: Publish the container
    const publishRes = await fetch(
      `https://graph.facebook.com/v18.0/${igUserId}/media_publish`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          creation_id: containerId,
          access_token: accessToken,
        }),
      },
    );

    if (!publishRes.ok) {
      const err = await publishRes.text();
      throw new Error(`IG publish failed: ${err}`);
    }

    const result = await publishRes.json();

    return {
      platform: 'instagram',
      status: 'published',
      external_id: result.id,
      external_url: `https://instagram.com/reel/${result.id}`,
    };
  } catch (err) {
    return {
      platform: 'instagram',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown Instagram error',
    };
  }
}

async function publishToFacebook(
  videoUrl: string,
  title: string,
  description: string,
  accessToken: string,
  pageId: string,
): Promise<PlatformResult> {
  try {
    // Use the resumable upload API for Facebook videos
    const initRes = await fetch(
      `https://graph.facebook.com/v18.0/${pageId}/videos`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          file_url: videoUrl,
          title: title.slice(0, 100),
          description: `${description}\n\n🎬 Made with StickDeath Infinity`,
          access_token: accessToken,
        }),
      },
    );

    if (!initRes.ok) {
      const err = await initRes.text();
      throw new Error(`FB upload failed: ${err}`);
    }

    const result = await initRes.json();

    return {
      platform: 'facebook',
      status: 'published',
      external_id: result.id,
      external_url: `https://facebook.com/${result.id}`,
    };
  } catch (err) {
    return {
      platform: 'facebook',
      status: 'failed',
      error: err instanceof Error ? err.message : 'Unknown Facebook error',
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

  // Check if token is expired (with 5-minute buffer)
  if (token.token_expires_at) {
    const expiresAt = new Date(token.token_expires_at).getTime();
    const now = Date.now() - 5 * 60 * 1000;
    if (expiresAt < now && token.refresh_token) {
      // Token expired — attempt refresh based on platform
      const refreshed = await refreshToken(platform, token.refresh_token);
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
      return null; // Refresh failed
    }
  }

  return token as SocialToken;
}

async function refreshToken(
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

    // Support both webhook (no auth) and direct call (with auth)
    let userId: string;
    let body: PublishRequest;

    const rawBody = await req.json();

    // Check if this is a render completion webhook
    if (rawBody.type === 'render.completed' && rawBody.render_job_id) {
      body = { render_job_id: rawBody.render_job_id };
      // Get user from the render job
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

    const { render_job_id, platforms, publish_to_own_channels } = body;

    // Fetch the render job
    const { data: renderJob, error: rjError } = await adminClient
      .from('render_jobs')
      .select('*')
      .eq('id', render_job_id)
      .single();

    if (rjError || !renderJob) {
      return errorResponse('Render job not found', 404);
    }

    const job = renderJob as RenderJob;
    if (job.status !== 'completed' || !job.output_url) {
      return errorResponse('Render job is not completed or has no output', 400);
    }

    // Fetch the project for metadata
    const { data: project } = await adminClient
      .from('studio_projects')
      .select('id, title, description, tags, user_id')
      .eq('id', job.project_id)
      .single();

    if (!project) return errorResponse('Project not found', 404);
    const proj = project as Project;

    // Determine which platforms to publish to
    const targetPlatforms: Platform[] =
      platforms ?? ['youtube', 'tiktok', 'instagram', 'facebook'];

    // Create publish_job record
    const { data: publishJob, error: pjError } = await adminClient
      .from('publish_jobs')
      .insert({
        render_job_id: render_job_id,
        project_id: proj.id,
        user_id: userId,
        status: 'publishing',
        platforms: targetPlatforms,
        results: {},
      })
      .select()
      .single();

    if (pjError) {
      return errorResponse(`Failed to create publish job: ${pjError.message}`, 500);
    }

    const title = proj.title || 'StickDeath Animation';
    const description = proj.description || 'Check out this stick figure animation!';
    const tags = proj.tags || ['stickdeath', 'animation'];

    // ── Publish to StickDeath official channels ──

    const officialResults: PlatformResult[] = [];

    // Official channel tokens come from env vars
    const officialYTToken = Deno.env.get('STICKDEATH_YOUTUBE_TOKEN');
    const officialTTToken = Deno.env.get('STICKDEATH_TIKTOK_TOKEN');
    const officialIGToken = Deno.env.get('STICKDEATH_INSTAGRAM_TOKEN');
    const officialIGUserId = Deno.env.get('STICKDEATH_INSTAGRAM_USER_ID');
    const officialFBToken = Deno.env.get('STICKDEATH_FACEBOOK_TOKEN');
    const officialFBPageId = Deno.env.get('STICKDEATH_FACEBOOK_PAGE_ID');

    // Run all platform publishes concurrently
    const publishPromises: Promise<PlatformResult>[] = [];

    if (targetPlatforms.includes('youtube') && officialYTToken) {
      publishPromises.push(
        publishToYouTube(job.output_url, title, description, tags, officialYTToken),
      );
    }

    if (targetPlatforms.includes('tiktok') && officialTTToken) {
      publishPromises.push(
        publishToTikTok(job.output_url, title, officialTTToken),
      );
    }

    if (targetPlatforms.includes('instagram') && officialIGToken && officialIGUserId) {
      publishPromises.push(
        publishToInstagram(
          job.output_url,
          `${title} — ${description}`,
          officialIGToken,
          officialIGUserId,
        ),
      );
    }

    if (targetPlatforms.includes('facebook') && officialFBToken && officialFBPageId) {
      publishPromises.push(
        publishToFacebook(job.output_url, title, description, officialFBToken, officialFBPageId),
      );
    }

    officialResults.push(...(await Promise.all(publishPromises)));

    // ── Publish to user's own connected channels ──

    const userResults: PlatformResult[] = [];

    if (publish_to_own_channels !== false) {
      const userPublishPromises: Promise<PlatformResult>[] = [];

      for (const platform of targetPlatforms) {
        const token = await getValidToken(adminClient, userId, platform);
        if (!token) continue;

        switch (platform) {
          case 'youtube':
            userPublishPromises.push(
              publishToYouTube(job.output_url, title, description, tags, token.access_token),
            );
            break;
          case 'tiktok':
            userPublishPromises.push(
              publishToTikTok(job.output_url, title, token.access_token),
            );
            break;
          case 'instagram':
            userPublishPromises.push(
              publishToInstagram(
                job.output_url,
                `${title} — ${description}`,
                token.access_token,
                token.platform_user_id,
              ),
            );
            break;
          case 'facebook':
            userPublishPromises.push(
              publishToFacebook(
                job.output_url,
                title,
                description,
                token.access_token,
                token.platform_user_id,
              ),
            );
            break;
        }
      }

      userResults.push(...(await Promise.all(userPublishPromises)));
    }

    // Determine overall status
    const allResults = [...officialResults, ...userResults];
    const anySuccess = allResults.some((r) => r.status === 'published');
    const allFailed = allResults.length > 0 && allResults.every((r) => r.status === 'failed');

    const overallStatus = allFailed ? 'failed' : anySuccess ? 'published' : 'no_platforms';

    // Update publish_job with results
    await adminClient
      .from('publish_jobs')
      .update({
        status: overallStatus,
        results: {
          official: officialResults,
          user: userResults,
        },
        completed_at: new Date().toISOString(),
      })
      .eq('id', publishJob.id);

    // If successful, update the project's published status
    if (anySuccess) {
      await adminClient
        .from('studio_projects')
        .update({ is_published: true, published_at: new Date().toISOString() })
        .eq('id', proj.id);
    }

    return jsonResponse({
      publish_job_id: publishJob.id,
      status: overallStatus,
      official_results: officialResults,
      user_results: userResults,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.message, err.status);
    }
    console.error('publish-video error:', err);
    return errorResponse('Internal server error', 500);
  }
});
