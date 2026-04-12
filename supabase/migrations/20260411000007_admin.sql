-- =============================================================================
-- Migration: Admin & Moderation
-- StickDeath Infinity — Supabase Migration 007
-- Tables: admin_actions, reports, broadcasts, broadcast_delivery
-- =============================================================================

-- ─────────────────────────────────────────────
-- admin_actions
-- Audit log of admin moderation actions
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_actions (
    id          integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    admin_id    uuid NOT NULL REFERENCES public.users(id),
    action_type varchar NOT NULL,
    target_type varchar NOT NULL,
    target_id   varchar NOT NULL,
    reason      text,
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_actions_admin_id ON public.admin_actions (admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_actions_created ON public.admin_actions (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_actions_target ON public.admin_actions (target_type, target_id);

COMMENT ON TABLE public.admin_actions IS 'Admin moderation audit log';

-- ─────────────────────────────────────────────
-- reports
-- User-submitted content reports
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reports (
    id          integer PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    post_id     integer REFERENCES public.posts(id) ON DELETE CASCADE,
    reporter_id uuid NOT NULL REFERENCES public.users(id),
    reason      varchar NOT NULL,
    details     text,
    status      varchar DEFAULT 'open',
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reports_status ON public.reports (status);
CREATE INDEX IF NOT EXISTS idx_reports_post ON public.reports (post_id);
CREATE INDEX IF NOT EXISTS idx_reports_created ON public.reports (created_at DESC);

COMMENT ON TABLE public.reports IS 'User-submitted content reports';

-- ─────────────────────────────────────────────
-- broadcasts
-- Admin announcements to users
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.broadcasts (
    id                  varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    title               varchar(200) NOT NULL,
    body                text NOT NULL,
    link_url            varchar(500),
    audience            varchar(100) DEFAULT 'all' NOT NULL,
    user_ids            jsonb,
    created_at          timestamptz DEFAULT now(),
    created_by_admin_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_broadcasts_created_at ON public.broadcasts (created_at DESC);

COMMENT ON TABLE public.broadcasts IS 'Admin broadcast announcements';

-- ─────────────────────────────────────────────
-- broadcast_delivery
-- Delivery tracking per user per broadcast
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.broadcast_delivery (
    broadcast_id varchar NOT NULL REFERENCES public.broadcasts(id) ON DELETE CASCADE,
    user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    delivered_at timestamptz DEFAULT now(),
    read_at      timestamptz,
    PRIMARY KEY (broadcast_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_broadcast_delivery_user ON public.broadcast_delivery (user_id);

COMMENT ON TABLE public.broadcast_delivery IS 'Per-user broadcast delivery tracking';

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.admin_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadcasts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadcast_delivery ENABLE ROW LEVEL SECURITY;
