/**
 * Official StickDeath Infinity channel configuration.
 *
 * ALL user-created videos are published here (watermarked).
 * Tokens for these accounts are stored as Supabase secrets
 * (not per-user social_tokens).
 */

export interface OfficialChannel {
  platform: string;
  handle: string;
  url: string;
  envTokenKey: string;       // Deno.env key for the access token
  envExtraKeys?: string[];   // Additional env keys needed (user ID, page ID, etc.)
}

export const OFFICIAL_CHANNELS: OfficialChannel[] = [
  {
    platform: 'youtube',
    handle: '@stickdeath.infinity',
    url: 'https://youtube.com/@stickdeath.infinity',
    envTokenKey: 'STICKDEATH_YOUTUBE_TOKEN',
  },
  {
    platform: 'tiktok',
    handle: '@stickdeath.infinity',
    url: 'https://www.tiktok.com/@stickdeath.infinity',
    envTokenKey: 'STICKDEATH_TIKTOK_TOKEN',
  },
  {
    platform: 'discord',
    handle: '#stickdeath_infinity',
    url: '', // Set via webhook
    envTokenKey: 'STICKDEATH_DISCORD_WEBHOOK_URL',
  },
];

/** The watermark text burned into every video */
export const WATERMARK_TEXT = 'StickDeath ∞';
export const WATERMARK_TAGLINE = 'Made with StickDeath ∞';

/**
 * Watermark rules:
 *
 * | Target               | Free user | Pro user  |
 * |----------------------|-----------|-----------|
 * | Official channels    | ✅ Always  | ✅ Always  |
 * | User's own channels  | ✅ Always  | ❌ Removed |
 * | Camera roll export   | ✅ Always  | ❌ Removed |
 *
 * In other words: official channel copies are ALWAYS watermarked,
 * no matter who made the video. Pro removes it only on the
 * creator's personal copy.
 */
export function shouldWatermark(
  target: 'official' | 'user',
  isPro: boolean,
): boolean {
  if (target === 'official') return true;   // Always
  return !isPro;                            // Only for free users
}
