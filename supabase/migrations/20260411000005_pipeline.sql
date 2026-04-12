-- =============================================================================
-- Migration: Render & AI Pipeline
-- StickDeath Infinity — Supabase Migration 005
-- Tables: render_jobs, publish_jobs, youtube_submit_status,
--         ai_jobs, ai_limits, ai_outputs
-- =============================================================================

-- ─────────────────────────────────────────────
-- render_jobs
-- Video render queue (project → mp4/gif/webm)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.render_jobs (
    id            integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    project_id    integer NOT NULL REFERENCES public.studio_projects(id) ON DELETE CASCADE,
    version_id    integer REFERENCES public.studio_project_versions(id) ON DELETE SET NULL,
    user_id       uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    status        varchar DEFAULT 'queued',
    format        varchar DEFAULT 'mp4',
    fps           integer DEFAULT 30,
    output_url    text,
    error_message text,
    progress      integer DEFAULT 0,
    created_at    timestamptz DEFAULT now(),
    started_at    timestamptz,
    completed_at  timestamptz,
    width         integer DEFAULT 1920,
    height        integer DEFAULT 1080,
    start_frame   integer DEFAULT 0,
    end_frame     integer,
    updated_at    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_render_jobs_project ON public.render_jobs (project_id);
CREATE INDEX IF NOT EXISTS idx_render_jobs_user ON public.render_jobs (user_id);
CREATE INDEX IF NOT EXISTS idx_render_jobs_status ON public.render_jobs (status);
CREATE INDEX IF NOT EXISTS idx_render_jobs_status_created ON public.render_jobs (status, created_at);

COMMENT ON TABLE public.render_jobs IS 'Animation render pipeline queue';

-- Add deferred FK: community_posts.render_job_id → render_jobs.id
ALTER TABLE public.community_posts
    ADD CONSTRAINT community_posts_render_job_id_fk
    FOREIGN KEY (render_job_id) REFERENCES public.render_jobs(id) ON DELETE SET NULL;

-- ─────────────────────────────────────────────
-- publish_jobs
-- Publish rendered video to platforms (YouTube, etc.)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.publish_jobs (
    id               integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    render_job_id    integer NOT NULL REFERENCES public.render_jobs(id) ON DELETE CASCADE,
    project_id       integer NOT NULL REFERENCES public.studio_projects(id) ON DELETE CASCADE,
    user_id          uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    provider         varchar NOT NULL,
    mode             varchar DEFAULT 'user_upload',
    status           varchar DEFAULT 'queued',
    title            varchar(255) NOT NULL,
    description      text,
    tags             text,
    privacy          varchar DEFAULT 'public',
    platform_video_id text,
    platform_url     text,
    error_message    text,
    created_at       timestamptz DEFAULT now(),
    updated_at       timestamptz DEFAULT now(),
    completed_at     timestamptz
);

CREATE INDEX IF NOT EXISTS idx_publish_jobs_render ON public.publish_jobs (render_job_id);
CREATE INDEX IF NOT EXISTS idx_publish_jobs_user ON public.publish_jobs (user_id);
CREATE INDEX IF NOT EXISTS idx_publish_jobs_status ON public.publish_jobs (status);

COMMENT ON TABLE public.publish_jobs IS 'Video publish pipeline (YouTube, etc.)';

-- ─────────────────────────────────────────────
-- youtube_submit_status
-- Per-user YouTube submission tracking
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.youtube_submit_status (
    user_id                uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    status                 varchar DEFAULT 'not_connected' NOT NULL,
    last_submission_at     timestamptz,
    last_submission_status varchar DEFAULT 'none' NOT NULL,
    last_error             text
);

CREATE INDEX IF NOT EXISTS idx_youtube_status_status ON public.youtube_submit_status (status);

COMMENT ON TABLE public.youtube_submit_status IS 'Per-user YouTube OAuth + submission state';

-- ─────────────────────────────────────────────
-- ai_jobs
-- AI generation request queue
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ai_jobs (
    id           integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    project_id   integer REFERENCES public.studio_projects(id) ON DELETE SET NULL,
    type         varchar NOT NULL,
    prompt       text NOT NULL,
    params_json  jsonb,
    status       varchar DEFAULT 'queued' NOT NULL,
    progress     integer DEFAULT 0,
    error        text,
    created_at   timestamptz DEFAULT now(),
    updated_at   timestamptz DEFAULT now(),
    started_at   timestamptz,
    completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_ai_jobs_user_created ON public.ai_jobs (user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_ai_jobs_status_created ON public.ai_jobs (status, created_at);

COMMENT ON TABLE public.ai_jobs IS 'AI generation pipeline queue';

-- ─────────────────────────────────────────────
-- ai_limits
-- Daily AI usage rate limits per user
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ai_limits (
    id         integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    day_key    varchar(10) NOT NULL,
    jobs_count integer DEFAULT 0 NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_limits_user_day ON public.ai_limits (user_id, day_key);

COMMENT ON TABLE public.ai_limits IS 'Daily AI usage rate limits';

-- ─────────────────────────────────────────────
-- ai_outputs
-- Results from completed AI jobs
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ai_outputs (
    id             integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    job_id         integer NOT NULL REFERENCES public.ai_jobs(id) ON DELETE CASCADE,
    result_json    jsonb,
    asset_ids_json jsonb,
    created_at     timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_outputs_job ON public.ai_outputs (job_id);

COMMENT ON TABLE public.ai_outputs IS 'AI generation results';

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.render_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.publish_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.youtube_submit_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_outputs ENABLE ROW LEVEL SECURITY;
