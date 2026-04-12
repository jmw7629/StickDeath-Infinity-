/**
 * social-connect — Supabase Edge Function
 *
 * OAuth flow for connecting user's own social media accounts:
 *   - YouTube (Google OAuth 2.0)
 *   - TikTok (TikTok Login Kit)
 *   - Instagram (Facebook/Instagram OAuth)
 *   - Facebook (Facebook Login)
 *
 * Endpoints:
 *   GET  ?action=connect&platform=youtube  → Returns OAuth authorization URL
 *   GET  ?action=callback&platform=youtube → Handles OAuth callback, stores tokens
 *   POST ?action=disconnect&platform=youtube → Removes stored tokens
 *   GET  ?action=status → Returns connection status for all platforms
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { verifyAuth, AuthError } from '../_shared/auth.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

type Platform = 'youtube' | 'tiktok' | 'instagram' | 'facebook';

interface OAuthConfig {
  authUrl: string;
  tokenUrl: string;
  clientId: string;
  clientSecret: string;
  scopes: string[];
}

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  token_type?: string;
  scope?: string;
}

// ─── Constants ───────────────────────────────────────────────────────────────

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const FUNCTIONS_URL = `${SUPABASE_URL}/functions/v1/social-connect`;
const APP_DEEP_LINK = 'stickdeath://';

function getOAuthConfig(platform: Platform): OAuthConfig {
  switch (platform) {
    case 'youtube':
      return {
        authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
        tokenUrl: 'https://oauth2.googleapis.com/token',
        clientId: Deno.env.get('GOOGLE_CLIENT_ID')!,
        clientSecret: Deno.env.get('GOOGLE_CLIENT_SECRET')!,
        scopes: [
          'https://www.googleapis.com/auth/youtube.upload',
          'https://www.googleapis.com/auth/youtube.readonly',
        ],
      };

    case 'tiktok':
      return {
        authUrl: 'https://www.tiktok.com/v2/auth/authorize/',
        tokenUrl: 'https://open.tiktokapis.com/v2/oauth/token/',
        clientId: Deno.env.get('TIKTOK_CLIENT_KEY')!,
        clientSecret: Deno.env.get('TIKTOK_CLIENT_SECRET')!,
        scopes: ['user.info.basic', 'video.publish', 'video.upload'],
      };

    case 'instagram':
      return {
        authUrl: 'https://www.facebook.com/v18.0/dialog/oauth',
        tokenUrl: 'https://graph.facebook.com/v18.0/oauth/access_token',
        clientId: Deno.env.get('FACEBOOK_APP_ID')!,
        clientSecret: Deno.env.get('FACEBOOK_APP_SECRET')!,
        scopes: [
          'instagram_basic',
          'instagram_content_publish',
          'pages_show_list',
          'pages_read_engagement',
        ],
      };

    case 'facebook':
      return {
        authUrl: 'https://www.facebook.com/v18.0/dialog/oauth',
        tokenUrl: 'https://graph.facebook.com/v18.0/oauth/access_token',
        clientId: Deno.env.get('FACEBOOK_APP_ID')!,
        clientSecret: Deno.env.get('FACEBOOK_APP_SECRET')!,
        scopes: [
          'pages_manage_posts',
          'pages_read_engagement',
          'pages_show_list',
          'publish_video',
        ],
      };
  }
}

// ─── State Management (CSRF protection) ─────────────────────────────────────

function generateState(userId: string, platform: Platform): string {
  const payload = JSON.stringify({
    user_id: userId,
    platform,
    ts: Date.now(),
    nonce: crypto.randomUUID(),
  });
  // Base64 encode — in production, encrypt this
  return btoa(payload);
}

function parseState(state: string): { user_id: string; platform: Platform; ts: number } | null {
  try {
    const payload = JSON.parse(atob(state));
    // Reject if older than 10 minutes
    if (Date.now() - payload.ts > 600000) return null;
    return payload;
  } catch {
    return null;
  }
}

// ─── OAuth Flow: Generate Auth URL ──────────────────────────────────────────

function buildAuthUrl(platform: Platform, userId: string): string {
  const config = getOAuthConfig(platform);
  const state = generateState(userId, platform);
  const redirectUri = `${FUNCTIONS_URL}?action=callback&platform=${platform}`;

  const params = new URLSearchParams();

  switch (platform) {
    case 'youtube':
      params.set('client_id', config.clientId);
      params.set('redirect_uri', redirectUri);
      params.set('response_type', 'code');
      params.set('scope', config.scopes.join(' '));
      params.set('state', state);
      params.set('access_type', 'offline');
      params.set('prompt', 'consent');
      return `${config.authUrl}?${params}`;

    case 'tiktok':
      params.set('client_key', config.clientId);
      params.set('redirect_uri', redirectUri);
      params.set('response_type', 'code');
      params.set('scope', config.scopes.join(','));
      params.set('state', state);
      return `${config.authUrl}?${params}`;

    case 'instagram':
    case 'facebook':
      params.set('client_id', config.clientId);
      params.set('redirect_uri', redirectUri);
      params.set('response_type', 'code');
      params.set('scope', config.scopes.join(','));
      params.set('state', state);
      return `${config.authUrl}?${params}`;
  }
}

// ─── OAuth Flow: Exchange Code for Token ────────────────────────────────────

async function exchangeCodeForToken(
  platform: Platform,
  code: string,
): Promise<TokenResponse> {
  const config = getOAuthConfig(platform);
  const redirectUri = `${FUNCTIONS_URL}?action=callback&platform=${platform}`;

  let response: Response;

  switch (platform) {
    case 'youtube': {
      response = await fetch(config.tokenUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          code,
          client_id: config.clientId,
          client_secret: config.clientSecret,
          redirect_uri: redirectUri,
          grant_type: 'authorization_code',
        }),
      });
      break;
    }

    case 'tiktok': {
      response = await fetch(config.tokenUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          code,
          client_key: config.clientId,
          client_secret: config.clientSecret,
          redirect_uri: redirectUri,
          grant_type: 'authorization_code',
        }),
      });
      break;
    }

    case 'instagram':
    case 'facebook': {
      const params = new URLSearchParams({
        code,
        client_id: config.clientId,
        client_secret: config.clientSecret,
        redirect_uri: redirectUri,
      });
      response = await fetch(`${config.tokenUrl}?${params}`);
      break;
    }
  }

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`Token exchange failed for ${platform}: ${err}`);
  }

  const data = await response.json();

  // Normalize response structure
  if (platform === 'tiktok') {
    return {
      access_token: data.data?.access_token ?? data.access_token,
      refresh_token: data.data?.refresh_token ?? data.refresh_token,
      expires_in: data.data?.expires_in ?? data.expires_in,
    };
  }

  return data as TokenResponse;
}

// ─── Fetch Platform User ID ─────────────────────────────────────────────────

async function fetchPlatformUserId(
  platform: Platform,
  accessToken: string,
): Promise<{ id: string; name: string }> {
  switch (platform) {
    case 'youtube': {
      const res = await fetch(
        'https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true',
        { headers: { Authorization: `Bearer ${accessToken}` } },
      );
      const data = await res.json();
      const channel = data.items?.[0];
      return {
        id: channel?.id ?? 'unknown',
        name: channel?.snippet?.title ?? 'YouTube Channel',
      };
    }

    case 'tiktok': {
      const res = await fetch(
        'https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name',
        { headers: { Authorization: `Bearer ${accessToken}` } },
      );
      const data = await res.json();
      return {
        id: data.data?.user?.open_id ?? 'unknown',
        name: data.data?.user?.display_name ?? 'TikTok User',
      };
    }

    case 'instagram': {
      // First get Facebook pages, then find linked IG account
      const pagesRes = await fetch(
        `https://graph.facebook.com/v18.0/me/accounts?access_token=${accessToken}`,
      );
      const pagesData = await pagesRes.json();
      const page = pagesData.data?.[0];

      if (page) {
        const igRes = await fetch(
          `https://graph.facebook.com/v18.0/${page.id}?fields=instagram_business_account&access_token=${accessToken}`,
        );
        const igData = await igRes.json();
        const igId = igData.instagram_business_account?.id;

        if (igId) {
          const igProfileRes = await fetch(
            `https://graph.facebook.com/v18.0/${igId}?fields=username&access_token=${accessToken}`,
          );
          const igProfile = await igProfileRes.json();
          return { id: igId, name: igProfile.username ?? 'Instagram Account' };
        }
      }
      return { id: 'unknown', name: 'Instagram Account' };
    }

    case 'facebook': {
      // Get the user's page (for posting videos)
      const pagesRes = await fetch(
        `https://graph.facebook.com/v18.0/me/accounts?access_token=${accessToken}`,
      );
      const pagesData = await pagesRes.json();
      const page = pagesData.data?.[0];
      return {
        id: page?.id ?? 'unknown',
        name: page?.name ?? 'Facebook Page',
      };
    }
  }
}

// ─── For Facebook/IG: Exchange for Long-Lived Token ─────────────────────────

async function getLongLivedToken(
  platform: 'facebook' | 'instagram',
  shortToken: string,
): Promise<TokenResponse> {
  const config = getOAuthConfig(platform);
  const res = await fetch(
    `https://graph.facebook.com/v18.0/oauth/access_token?grant_type=fb_exchange_token&client_id=${config.clientId}&client_secret=${config.clientSecret}&fb_exchange_token=${shortToken}`,
  );

  const data = await res.json();
  return {
    access_token: data.access_token,
    expires_in: data.expires_in ?? 5184000, // ~60 days
  };
}

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  try {
    const url = new URL(req.url);
    const action = url.searchParams.get('action');
    const platform = url.searchParams.get('platform') as Platform | null;

    // ── Action: Status (GET) — Get connection status ──
    if (action === 'status') {
      const { user, adminClient } = await verifyAuth(req);

      const { data: tokens } = await adminClient
        .from('social_tokens')
        .select('platform, platform_user_id, platform_username, connected_at, token_expires_at')
        .eq('user_id', user.id);

      const platforms: Platform[] = ['youtube', 'tiktok', 'instagram', 'facebook'];
      const status = platforms.map((p) => {
        const token = tokens?.find((t: Record<string, unknown>) => t.platform === p);
        return {
          platform: p,
          connected: !!token,
          platform_username: token?.platform_username ?? null,
          connected_at: token?.connected_at ?? null,
          expires_at: token?.token_expires_at ?? null,
        };
      });

      return jsonResponse({ connections: status });
    }

    // ── Action: Connect (GET) — Generate OAuth URL ──
    if (action === 'connect') {
      if (!platform || !['youtube', 'tiktok', 'instagram', 'facebook'].includes(platform)) {
        return errorResponse('Valid platform is required (youtube, tiktok, instagram, facebook)');
      }

      const { user } = await verifyAuth(req);
      const authUrl = buildAuthUrl(platform, user.id);

      return jsonResponse({ auth_url: authUrl, platform });
    }

    // ── Action: Callback (GET) — Handle OAuth redirect ──
    if (action === 'callback') {
      const code = url.searchParams.get('code');
      const state = url.searchParams.get('state');
      const error = url.searchParams.get('error');

      if (error) {
        // Redirect back to app with error
        return Response.redirect(
          `${APP_DEEP_LINK}social-connect/error?platform=${platform}&error=${encodeURIComponent(error)}`,
          302,
        );
      }

      if (!code || !state || !platform) {
        return errorResponse('Missing code, state, or platform');
      }

      // Validate state (CSRF protection)
      const stateData = parseState(state);
      if (!stateData || stateData.platform !== platform) {
        return errorResponse('Invalid or expired state', 403);
      }

      const adminClient = createAdminClient();

      // Exchange code for tokens
      let tokens = await exchangeCodeForToken(platform, code);

      // For Facebook/Instagram, exchange for long-lived token
      if (platform === 'facebook' || platform === 'instagram') {
        const longLived = await getLongLivedToken(platform, tokens.access_token);
        tokens = { ...tokens, ...longLived };
      }

      // Fetch the platform user ID and name
      const platformUser = await fetchPlatformUserId(platform, tokens.access_token);

      // Store the tokens securely
      await adminClient.from('social_tokens').upsert(
        {
          user_id: stateData.user_id,
          platform,
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token ?? null,
          token_expires_at: tokens.expires_in
            ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
            : null,
          platform_user_id: platformUser.id,
          platform_username: platformUser.name,
          connected_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'user_id,platform' },
      );

      // Redirect back to the app
      return Response.redirect(
        `${APP_DEEP_LINK}social-connect/success?platform=${platform}&name=${encodeURIComponent(platformUser.name)}`,
        302,
      );
    }

    // ── Action: Disconnect (POST) — Remove stored tokens ──
    if (action === 'disconnect') {
      if (!platform) {
        return errorResponse('platform is required');
      }

      const { user, adminClient } = await verifyAuth(req);

      const { error: delError } = await adminClient
        .from('social_tokens')
        .delete()
        .eq('user_id', user.id)
        .eq('platform', platform);

      if (delError) {
        return errorResponse(`Failed to disconnect: ${delError.message}`, 500);
      }

      return jsonResponse({
        disconnected: true,
        platform,
      });
    }

    return errorResponse(
      'Unknown action. Use: connect, callback, disconnect, or status',
    );
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.message, err.status);
    }
    console.error('social-connect error:', err);
    return errorResponse('Internal server error', 500);
  }
});
