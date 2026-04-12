-- =============================================================================
-- Migration: Social Features
-- StickDeath Infinity — Supabase Migration 002
-- Tables: follows, community_posts, community_likes, community_saves,
--         posts, likes, comments
-- =============================================================================

-- ─────────────────────────────────────────────
-- follows
-- User follow relationships
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.follows (
    id           integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    follower_id  uuid NOT NULL REFERENCES public.users(id),
    following_id uuid NOT NULL REFERENCES public.users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_follows_unique ON public.follows (follower_id, following_id);
CREATE INDEX IF NOT EXISTS idx_follows_follower ON public.follows (follower_id);
CREATE INDEX IF NOT EXISTS idx_follows_following ON public.follows (following_id);

COMMENT ON TABLE public.follows IS 'User follow relationships';

-- ─────────────────────────────────────────────
-- posts
-- Legacy feed posts (media uploads)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.posts (
    id              integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id         uuid NOT NULL REFERENCES public.users(id),
    title           varchar(255) NOT NULL,
    description     text,
    media_url       text NOT NULL,
    media_type      varchar DEFAULT 'mp4',
    tags            text[] DEFAULT '{}',
    like_count      integer DEFAULT 0,
    created_at      timestamptz DEFAULT now(),
    featured        boolean DEFAULT false,
    media_size      integer,
    media_duration  integer,
    thumbnail_url   text,
    hidden          boolean DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_posts_user ON public.posts (user_id);
CREATE INDEX IF NOT EXISTS idx_posts_created ON public.posts (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_featured ON public.posts (featured) WHERE featured = true;

COMMENT ON TABLE public.posts IS 'Legacy user feed posts';

-- ─────────────────────────────────────────────
-- community_posts
-- Community feed posts (published from studio)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.community_posts (
    id              integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    owner_user_id   uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    project_id      integer,       -- FK added after studio_projects
    render_job_id   integer,       -- FK added after render_jobs
    title           varchar(255) NOT NULL,
    description     text,
    thumbnail_url   text,
    video_url       text,
    duration_ms     integer DEFAULT 0,
    status          varchar DEFAULT 'pending' NOT NULL,
    like_count      integer DEFAULT 0,
    save_count      integer DEFAULT 0,
    view_count      integer DEFAULT 0,
    moderated_by    uuid REFERENCES public.users(id) ON DELETE SET NULL,
    moderated_at    timestamptz,
    created_at      timestamptz DEFAULT now(),
    updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_community_posts_owner ON public.community_posts (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_community_posts_status ON public.community_posts (status);
CREATE INDEX IF NOT EXISTS idx_community_posts_status_created ON public.community_posts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_community_posts_created ON public.community_posts (created_at DESC);

COMMENT ON TABLE public.community_posts IS 'Community-published animations';

-- ─────────────────────────────────────────────
-- community_likes
-- Like on a community post
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.community_likes (
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    post_id    integer NOT NULL REFERENCES public.community_posts(id) ON DELETE CASCADE,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (user_id, post_id)
);

CREATE INDEX IF NOT EXISTS idx_community_likes_post ON public.community_likes (post_id);

COMMENT ON TABLE public.community_likes IS 'Community post likes';

-- ─────────────────────────────────────────────
-- community_saves
-- Save/bookmark a community post
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.community_saves (
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    post_id    integer NOT NULL REFERENCES public.community_posts(id) ON DELETE CASCADE,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (user_id, post_id)
);

CREATE INDEX IF NOT EXISTS idx_community_saves_post ON public.community_saves (post_id);
CREATE INDEX IF NOT EXISTS idx_community_saves_user ON public.community_saves (user_id);

COMMENT ON TABLE public.community_saves IS 'Community post saves/bookmarks';

-- ─────────────────────────────────────────────
-- likes
-- Like on a legacy post
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.likes (
    id         integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    post_id    integer NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES public.users(id),
    created_at timestamptz DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_likes_unique ON public.likes (post_id, user_id);
CREATE INDEX IF NOT EXISTS idx_likes_user ON public.likes (user_id);

COMMENT ON TABLE public.likes IS 'Legacy post likes';

-- ─────────────────────────────────────────────
-- comments
-- Comments on legacy posts
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.comments (
    id         integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    post_id    integer NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES public.users(id),
    body       text NOT NULL,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_comments_post_created ON public.comments (post_id, created_at);

COMMENT ON TABLE public.comments IS 'Comments on legacy posts';

-- ─────────────────────────────────────────────
-- conversations / messages
-- AI chat conversations (legacy)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.conversations (
    id         serial PRIMARY KEY,
    title      text NOT NULL,
    created_at timestamptz DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS public.messages (
    id              serial PRIMARY KEY,
    conversation_id integer NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    role            text NOT NULL,
    content         text NOT NULL,
    created_at      timestamptz DEFAULT CURRENT_TIMESTAMP NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages (conversation_id, created_at);

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.community_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.community_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.community_saves ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
