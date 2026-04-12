-- =============================================================================
-- Migration: Community & Gamification
-- StickDeath Infinity — Supabase Migration 006
-- Tables: challenges, creator_badges, user_badges, tips,
--         notifications, notification_preferences
-- =============================================================================

-- ─────────────────────────────────────────────
-- challenges
-- Community animation challenges (weekly/monthly)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.challenges (
    id          integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    title       varchar(255) NOT NULL,
    description text,
    theme       varchar(100) NOT NULL,
    tag         varchar(50) NOT NULL,
    rules       text,
    start_date  timestamptz NOT NULL,
    end_date    timestamptz NOT NULL,
    active      boolean DEFAULT true,
    created_by  uuid NOT NULL REFERENCES public.users(id),
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_challenges_active ON public.challenges (active);
CREATE INDEX IF NOT EXISTS idx_challenges_dates ON public.challenges (start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_challenges_tag ON public.challenges (tag);

COMMENT ON TABLE public.challenges IS 'Community animation challenges';

-- ─────────────────────────────────────────────
-- creator_badges
-- Badge definitions (OG, Top Creator, etc.)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.creator_badges (
    id          varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    code        varchar(50) NOT NULL UNIQUE,
    label       varchar(100) NOT NULL,
    icon_key    varchar(50) NOT NULL,
    description text,
    sort_order  integer DEFAULT 0 NOT NULL
);

COMMENT ON TABLE public.creator_badges IS 'Badge type definitions';

-- ─────────────────────────────────────────────
-- user_badges
-- Badges awarded to users
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_badges (
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    badge_id   varchar NOT NULL REFERENCES public.creator_badges(id) ON DELETE CASCADE,
    awarded_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (user_id, badge_id)
);

CREATE INDEX IF NOT EXISTS idx_user_badges_badge ON public.user_badges (badge_id);
CREATE INDEX IF NOT EXISTS idx_user_badges_user ON public.user_badges (user_id);

COMMENT ON TABLE public.user_badges IS 'Badges awarded to users';

-- ─────────────────────────────────────────────
-- tips
-- Peer-to-peer tipping via Stripe
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tips (
    id                       integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    from_user_id             uuid NOT NULL REFERENCES public.users(id),
    to_user_id               uuid NOT NULL REFERENCES public.users(id),
    post_id                  integer REFERENCES public.posts(id) ON DELETE SET NULL,
    amount_cents             integer NOT NULL,
    stripe_payment_intent_id varchar,
    status                   varchar DEFAULT 'pending',
    created_at               timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tips_from_user ON public.tips (from_user_id);
CREATE INDEX IF NOT EXISTS idx_tips_to_user ON public.tips (to_user_id);
CREATE INDEX IF NOT EXISTS idx_tips_status ON public.tips (status);
CREATE INDEX IF NOT EXISTS idx_tips_created ON public.tips (created_at);

COMMENT ON TABLE public.tips IS 'Peer-to-peer creator tips';

-- ─────────────────────────────────────────────
-- notifications
-- In-app notifications (likes, follows, etc.)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.notifications (
    id         integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    type       varchar NOT NULL,
    actor_id   uuid REFERENCES public.users(id) ON DELETE SET NULL,
    post_id    integer REFERENCES public.posts(id) ON DELETE CASCADE,
    message    text NOT NULL,
    read       boolean DEFAULT false,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user_read ON public.notifications (user_id, read);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON public.notifications (user_id, created_at DESC);

COMMENT ON TABLE public.notifications IS 'In-app notification feed';

-- ─────────────────────────────────────────────
-- notification_preferences
-- Per-user notification opt-in/out
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.notification_preferences (
    id                integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id           uuid NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
    likes_enabled     boolean DEFAULT true,
    comments_enabled  boolean DEFAULT true,
    follows_enabled   boolean DEFAULT true,
    admin_enabled     boolean DEFAULT true,
    challenge_enabled boolean DEFAULT true,
    tips_enabled      boolean DEFAULT true
);

COMMENT ON TABLE public.notification_preferences IS 'Per-user notification preferences';

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_badges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
