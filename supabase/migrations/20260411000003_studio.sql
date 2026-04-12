-- =============================================================================
-- Migration: Studio & Animation Tools
-- StickDeath Infinity — Supabase Migration 003
-- Tables: studio_projects, studio_project_versions, studio_assets,
--         studio_sfx, studio_library_assets, library_sources,
--         library_asset_variants, frame_audio
-- =============================================================================

-- ─────────────────────────────────────────────
-- library_sources
-- Attribution sources for library content (Kenney, etc.)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.library_sources (
    key              varchar PRIMARY KEY,
    name             varchar(255) NOT NULL,
    license_name     varchar(100) NOT NULL,
    license_url      varchar(500) NOT NULL,
    attribution_text text NOT NULL,
    created_at       timestamptz DEFAULT now()
);

COMMENT ON TABLE public.library_sources IS 'License/attribution sources for library content';

-- ─────────────────────────────────────────────
-- studio_projects
-- Animation project workspace
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.studio_projects (
    id                       integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id                  uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    name                     varchar(255) NOT NULL,
    description              text,
    thumbnail_url            text,
    status                   varchar DEFAULT 'draft',
    post_id                  integer REFERENCES public.posts(id) ON DELETE SET NULL,
    created_at               timestamptz DEFAULT now(),
    updated_at               timestamptz DEFAULT now(),
    latest_version_id        integer,       -- FK added below (circular)
    latest_version_signature varchar(36),
    canvas_width             integer DEFAULT 1280,
    canvas_height            integer DEFAULT 720,
    fps                      integer DEFAULT 12,
    background_type          varchar DEFAULT 'color',
    background_value         text DEFAULT '#1a1a2e'
);

CREATE INDEX IF NOT EXISTS idx_studio_projects_user ON public.studio_projects (user_id);
CREATE INDEX IF NOT EXISTS idx_studio_projects_status ON public.studio_projects (status);

COMMENT ON TABLE public.studio_projects IS 'Animation studio projects';

-- Add deferred FK: profiles.pinned_project_id → studio_projects.id
ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_pinned_project_id_fk
    FOREIGN KEY (pinned_project_id) REFERENCES public.studio_projects(id) ON DELETE SET NULL;

-- Add deferred FK: community_posts.project_id → studio_projects.id
ALTER TABLE public.community_posts
    ADD CONSTRAINT community_posts_project_id_fk
    FOREIGN KEY (project_id) REFERENCES public.studio_projects(id) ON DELETE SET NULL;

-- ─────────────────────────────────────────────
-- studio_project_versions
-- Version history for projects (autosave + manual)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.studio_project_versions (
    id                integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    project_id        integer NOT NULL REFERENCES public.studio_projects(id) ON DELETE CASCADE,
    user_id           uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    version_number    integer NOT NULL,
    project_json      jsonb NOT NULL,
    label             varchar(100),
    created_at        timestamptz DEFAULT now(),
    version_signature varchar(36),
    base_version_id   integer,
    is_autosave       boolean DEFAULT false
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_studio_versions_project_number
    ON public.studio_project_versions (project_id, version_number);
CREATE INDEX IF NOT EXISTS idx_studio_versions_project ON public.studio_project_versions (project_id);
CREATE INDEX IF NOT EXISTS idx_studio_versions_created ON public.studio_project_versions (created_at);
CREATE INDEX IF NOT EXISTS idx_studio_versions_signature ON public.studio_project_versions (version_signature);

COMMENT ON TABLE public.studio_project_versions IS 'Project version snapshots (autosave + manual save)';

-- Now add the circular FK: studio_projects.latest_version_id
ALTER TABLE public.studio_projects
    ADD CONSTRAINT studio_projects_latest_version_fk
    FOREIGN KEY (latest_version_id) REFERENCES public.studio_project_versions(id) ON DELETE SET NULL;

-- ─────────────────────────────────────────────
-- studio_assets
-- Per-project uploaded media (images, sounds, etc.)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.studio_assets (
    id          integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    project_id  integer NOT NULL REFERENCES public.studio_projects(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    name        varchar(255) NOT NULL,
    type        varchar NOT NULL,
    url         text NOT NULL,
    mime_type   varchar(100),
    size        integer,
    duration    integer,
    folder      varchar(100) DEFAULT 'root',
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_studio_assets_project ON public.studio_assets (project_id);
CREATE INDEX IF NOT EXISTS idx_studio_assets_user ON public.studio_assets (user_id);

COMMENT ON TABLE public.studio_assets IS 'Per-project uploaded media assets';

-- ─────────────────────────────────────────────
-- studio_sfx
-- Global sound effects library
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.studio_sfx (
    id            varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    name          varchar(255) NOT NULL,
    tags          text[] DEFAULT '{}',
    category      varchar(50) NOT NULL,
    duration_ms   integer NOT NULL,
    file_url      text NOT NULL,
    preview_url   text,
    source_key    varchar(50) DEFAULT 'kenney',
    external_id   varchar(255),
    created_at    timestamptz DEFAULT now(),
    intensity     varchar(20),
    layer         varchar(20) DEFAULT 'action' NOT NULL,
    peak_db       real,
    loudness_lufs real
);

CREATE INDEX IF NOT EXISTS idx_sfx_category ON public.studio_sfx (category);
CREATE INDEX IF NOT EXISTS idx_sfx_layer ON public.studio_sfx (layer);
CREATE INDEX IF NOT EXISTS idx_sfx_name_text ON public.studio_sfx (name);
CREATE INDEX IF NOT EXISTS idx_sfx_source ON public.studio_sfx (source_key);

COMMENT ON TABLE public.studio_sfx IS 'Global SFX library for the animation studio';

-- ─────────────────────────────────────────────
-- studio_library_assets
-- Global visual asset library (stickmen, props, backgrounds)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.studio_library_assets (
    id          varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    source_key  varchar NOT NULL REFERENCES public.library_sources(key),
    external_id varchar(255) NOT NULL,
    name        varchar(255) NOT NULL,
    tags        text[] DEFAULT '{}',
    category    varchar(50) NOT NULL,
    file_url    text NOT NULL,
    preview_url text,
    created_at  timestamptz DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_library_assets_source_external
    ON public.studio_library_assets (source_key, external_id);
CREATE INDEX IF NOT EXISTS idx_library_assets_category ON public.studio_library_assets (category);
CREATE INDEX IF NOT EXISTS idx_library_assets_name ON public.studio_library_assets (name);
CREATE INDEX IF NOT EXISTS idx_library_assets_source ON public.studio_library_assets (source_key);

COMMENT ON TABLE public.studio_library_assets IS 'Global visual asset library';

-- ─────────────────────────────────────────────
-- library_asset_variants
-- Style variants of library assets (e.g. dark, neon)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.library_asset_variants (
    id          varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    asset_id    varchar NOT NULL REFERENCES public.studio_library_assets(id) ON DELETE CASCADE,
    variant_key varchar(50) NOT NULL,
    file_url    text NOT NULL,
    preview_url text,
    style_ready boolean DEFAULT false,
    style_error text,
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_library_variants_asset ON public.library_asset_variants (asset_id);

COMMENT ON TABLE public.library_asset_variants IS 'Style variants of library assets';

-- ─────────────────────────────────────────────
-- frame_audio
-- Per-frame SFX placement on the timeline
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.frame_audio (
    id              varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    project_id      integer NOT NULL REFERENCES public.studio_projects(id) ON DELETE CASCADE,
    frame_index     integer NOT NULL,
    sfx_id          varchar NOT NULL REFERENCES public.studio_sfx(id) ON DELETE CASCADE,
    offset_ms       integer DEFAULT 0,
    volume          integer DEFAULT 100,
    created_at      timestamptz DEFAULT now(),
    start_ms        integer DEFAULT 0,
    end_ms          integer,
    layer           varchar(20) DEFAULT 'action' NOT NULL,
    intensity_hint  varchar(20),
    priority        integer DEFAULT 0 NOT NULL,
    duck_group      varchar(20),
    is_loop         boolean DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_frame_audio_project ON public.frame_audio (project_id);
CREATE INDEX IF NOT EXISTS idx_frame_audio_project_frame ON public.frame_audio (project_id, frame_index);

COMMENT ON TABLE public.frame_audio IS 'Per-frame SFX placement on animation timeline';

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.library_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.studio_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.studio_project_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.studio_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.studio_sfx ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.studio_library_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.library_asset_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.frame_audio ENABLE ROW LEVEL SECURITY;
