-- =============================================================================
-- Migration: Watermark / Social / Reports / Discord
-- StickDeath Infinity — Supabase Migration 20260415-001
-- Tables: social_tokens, reports, app_config
-- Columns: render_jobs.output_url_watermarked
-- =============================================================================

-- ─────────────────────────────────────────────
-- social_tokens
-- OAuth tokens for user-connected social accounts
-- (YouTube, TikTok, Instagram, Facebook)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.social_tokens (
    id                 integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id            uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    platform           varchar(20) NOT NULL,
    access_token       text NOT NULL,
    refresh_token      text,
    token_expires_at   timestamptz,
    platform_user_id   text,
    platform_username  text,
    connected_at       timestamptz DEFAULT now(),
    updated_at         timestamptz DEFAULT now(),
    UNIQUE (user_id, platform)
);

CREATE INDEX IF NOT EXISTS idx_social_tokens_user ON public.social_tokens (user_id);
CREATE INDEX IF NOT EXISTS idx_social_tokens_platform ON public.social_tokens (platform);

COMMENT ON TABLE public.social_tokens IS 'OAuth tokens for user social accounts (YouTube, TikTok, IG, FB)';

ALTER TABLE public.social_tokens ENABLE ROW LEVEL SECURITY;

-- Users can read/manage their own tokens only
CREATE POLICY social_tokens_user_select ON public.social_tokens
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY social_tokens_user_insert ON public.social_tokens
    FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY social_tokens_user_update ON public.social_tokens
    FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY social_tokens_user_delete ON public.social_tokens
    FOR DELETE USING (auth.uid() = user_id);

-- ─────────────────────────────────────────────
-- reports
-- User-submitted reports for users/posts/comments
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reports (
    id              integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    reporter_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    entity_type     varchar(20) NOT NULL,   -- 'user', 'post', 'comment'
    entity_id       text NOT NULL,
    reason          varchar(50) NOT NULL,
    details         text,
    status          varchar(20) DEFAULT 'pending' NOT NULL,  -- pending, reviewed, resolved, dismissed
    reviewed_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
    reviewed_at     timestamptz,
    created_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reports_entity ON public.reports (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_reports_reporter ON public.reports (reporter_id);
CREATE INDEX IF NOT EXISTS idx_reports_status ON public.reports (status);

COMMENT ON TABLE public.reports IS 'User-submitted content reports for moderation';

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

-- Users can create reports but only read their own
CREATE POLICY reports_user_insert ON public.reports
    FOR INSERT WITH CHECK (auth.uid() = reporter_id);
CREATE POLICY reports_user_select ON public.reports
    FOR SELECT USING (auth.uid() = reporter_id);

-- ─────────────────────────────────────────────
-- app_config
-- Global app configuration key-value store
-- (official channel URLs, feature flags, etc.)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_config (
    key         varchar(100) PRIMARY KEY,
    value       jsonb NOT NULL,
    updated_at  timestamptz DEFAULT now()
);

COMMENT ON TABLE public.app_config IS 'Global app configuration (official channels, feature flags)';

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Anyone can read config; only admins write (via service role)
CREATE POLICY app_config_public_read ON public.app_config
    FOR SELECT USING (true);

-- Seed official channel config
INSERT INTO public.app_config (key, value) VALUES
(
    'official_channels',
    '{
        "youtube": {
            "handle": "@stickdeath.infinity",
            "url": "https://youtube.com/@stickdeath.infinity"
        },
        "tiktok": {
            "handle": "@stickdeath.infinity",
            "url": "https://www.tiktok.com/@stickdeath.infinity"
        },
        "discord": {
            "handle": "#stickdeath_infinity",
            "url": ""
        }
    }'::jsonb
),
(
    'watermark',
    '{
        "text": "StickDeath ∞",
        "tagline": "Made with StickDeath ∞",
        "position": "bottom-right",
        "opacity": 0.6,
        "rules": {
            "official_channels": "always",
            "free_user_export": "always",
            "pro_user_export": "removable"
        }
    }'::jsonb
)
ON CONFLICT (key) DO NOTHING;

-- ─────────────────────────────────────────────
-- Add watermarked output URL to render_jobs
-- ─────────────────────────────────────────────
ALTER TABLE public.render_jobs
    ADD COLUMN IF NOT EXISTS output_url_watermarked text;

COMMENT ON COLUMN public.render_jobs.output_url_watermarked
    IS 'URL of the watermarked version (always used for official channels)';
