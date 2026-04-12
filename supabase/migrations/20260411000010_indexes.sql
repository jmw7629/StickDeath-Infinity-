-- =============================================================================
-- Migration: Additional Performance Indexes
-- StickDeath Infinity — Supabase Migration 010
--
-- Composite and partial indexes for common query patterns beyond
-- what was created in the table migrations.
-- =============================================================================

-- ─────────────────────────────────────────────
-- Users — fast lookups
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_users_role ON public.users (role);
CREATE INDEX IF NOT EXISTS idx_users_banned ON public.users (banned) WHERE banned = true;
CREATE INDEX IF NOT EXISTS idx_users_shadowbanned ON public.users (shadowbanned) WHERE shadowbanned = true;
CREATE INDEX IF NOT EXISTS idx_users_subscription_tier ON public.users (subscription_tier);
CREATE INDEX IF NOT EXISTS idx_users_subscription_status ON public.users (subscription_status)
    WHERE subscription_status != 'inactive';
CREATE INDEX IF NOT EXISTS idx_users_created_at ON public.users (created_at DESC);

-- ─────────────────────────────────────────────
-- Profiles — handle search
-- ─────────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_handle ON public.profiles (handle);
CREATE INDEX IF NOT EXISTS idx_profiles_display_name ON public.profiles (display_name);

-- ─────────────────────────────────────────────
-- Community posts — feed queries
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_community_posts_trending
    ON public.community_posts (like_count DESC, created_at DESC)
    WHERE status = 'approved';

CREATE INDEX IF NOT EXISTS idx_community_posts_recent_approved
    ON public.community_posts (created_at DESC)
    WHERE status = 'approved';

-- ─────────────────────────────────────────────
-- Studio — project listing & search
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_studio_projects_user_updated
    ON public.studio_projects (user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_studio_projects_user_status
    ON public.studio_projects (user_id, status);

-- ─────────────────────────────────────────────
-- Studio SFX — full-text search on name
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_sfx_name_trgm ON public.studio_sfx
    USING gin (name gin_trgm_ops);

-- NOTE: Requires pg_trgm extension. If not available, this index will
-- fail silently. The extension can be enabled with:
-- CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ─────────────────────────────────────────────
-- Library assets — full-text search
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_library_assets_name_trgm ON public.studio_library_assets
    USING gin (name gin_trgm_ops);

-- ─────────────────────────────────────────────
-- SFX / Library — tags GIN index
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_sfx_tags ON public.studio_sfx USING gin (tags);
CREATE INDEX IF NOT EXISTS idx_library_assets_tags ON public.studio_library_assets USING gin (tags);

-- ─────────────────────────────────────────────
-- Render jobs — pipeline monitoring
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_render_jobs_queued
    ON public.render_jobs (created_at)
    WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_render_jobs_processing
    ON public.render_jobs (started_at)
    WHERE status = 'processing';

-- ─────────────────────────────────────────────
-- AI jobs — pipeline monitoring
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_ai_jobs_queued
    ON public.ai_jobs (created_at)
    WHERE status = 'queued';

CREATE INDEX IF NOT EXISTS idx_ai_jobs_user_project
    ON public.ai_jobs (user_id, project_id);

-- ─────────────────────────────────────────────
-- DM messages — pagination
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_dm_messages_thread_created
    ON public.dm_messages (thread_id, created_at DESC);

-- ─────────────────────────────────────────────
-- Notifications — unread badge count
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_notifications_unread
    ON public.notifications (user_id, created_at DESC)
    WHERE read = false;

-- ─────────────────────────────────────────────
-- Tips — recent + amounts
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_tips_to_user_created
    ON public.tips (to_user_id, created_at DESC)
    WHERE status = 'completed';

-- ─────────────────────────────────────────────
-- Posts (legacy) — GIN index on tags
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_posts_tags ON public.posts USING gin (tags);

-- ─────────────────────────────────────────────
-- Frame audio — composite for timeline queries
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_frame_audio_project_layer
    ON public.frame_audio (project_id, layer, frame_index);

-- ─────────────────────────────────────────────
-- Reports — open reports dashboard
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_reports_open
    ON public.reports (created_at DESC)
    WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_dm_reports_open
    ON public.dm_reports (created_at DESC)
    WHERE status = 'open';

-- ─────────────────────────────────────────────
-- Enable trigram extension for fuzzy search
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_trgm;
