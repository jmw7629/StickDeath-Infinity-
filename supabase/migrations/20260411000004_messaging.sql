-- =============================================================================
-- Migration: Direct Messaging
-- StickDeath Infinity — Supabase Migration 004
-- Tables: dm_threads, dm_messages, dm_thread_state, dm_blocks, dm_reports
-- =============================================================================

-- ─────────────────────────────────────────────
-- dm_threads
-- Direct message conversation between two users
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dm_threads (
    id         varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    user_a_id  uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    user_b_id  uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    CONSTRAINT dm_threads_user_order CHECK (user_a_id < user_b_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_dm_threads_pair ON public.dm_threads (user_a_id, user_b_id);
CREATE INDEX IF NOT EXISTS idx_dm_threads_user_a ON public.dm_threads (user_a_id);
CREATE INDEX IF NOT EXISTS idx_dm_threads_user_b ON public.dm_threads (user_b_id);
CREATE INDEX IF NOT EXISTS idx_dm_threads_updated ON public.dm_threads (updated_at DESC);

COMMENT ON TABLE public.dm_threads IS 'Direct message threads between two users';

-- ─────────────────────────────────────────────
-- dm_messages
-- Individual messages within a DM thread
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dm_messages (
    id              varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    thread_id       varchar NOT NULL REFERENCES public.dm_threads(id) ON DELETE CASCADE,
    sender_user_id  uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    body            text NOT NULL,
    status          varchar DEFAULT 'sent',
    created_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dm_messages_thread ON public.dm_messages (thread_id, created_at);
CREATE INDEX IF NOT EXISTS idx_dm_messages_sender ON public.dm_messages (sender_user_id);

COMMENT ON TABLE public.dm_messages IS 'Messages within a DM thread';

-- ─────────────────────────────────────────────
-- dm_thread_state
-- Per-user state for each thread (read, muted, pinned)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dm_thread_state (
    thread_id    varchar NOT NULL REFERENCES public.dm_threads(id) ON DELETE CASCADE,
    user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    last_read_at timestamptz,
    muted        boolean DEFAULT false,
    hidden       boolean DEFAULT false,
    pinned       boolean DEFAULT false,
    pinned_at    timestamptz,
    PRIMARY KEY (thread_id, user_id)
);

COMMENT ON TABLE public.dm_thread_state IS 'Per-user DM thread state (read markers, mute, pin)';

-- ─────────────────────────────────────────────
-- dm_blocks
-- User blocking for DMs
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dm_blocks (
    blocker_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    blocked_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    created_at      timestamptz DEFAULT now(),
    PRIMARY KEY (blocker_user_id, blocked_user_id)
);

CREATE INDEX IF NOT EXISTS idx_dm_blocks_blocked ON public.dm_blocks (blocked_user_id);

COMMENT ON TABLE public.dm_blocks IS 'User block list for DMs';

-- ─────────────────────────────────────────────
-- dm_reports
-- Reports on DM abuse
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.dm_reports (
    id               varchar PRIMARY KEY DEFAULT gen_random_uuid()::text,
    reporter_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    thread_id        varchar NOT NULL REFERENCES public.dm_threads(id) ON DELETE CASCADE,
    message_id       varchar REFERENCES public.dm_messages(id) ON DELETE SET NULL,
    reason           text NOT NULL,
    details          text,
    status           varchar DEFAULT 'open',
    admin_note       text,
    resolved_by      uuid REFERENCES public.users(id) ON DELETE SET NULL,
    resolved_at      timestamptz,
    created_at       timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dm_reports_status ON public.dm_reports (status);
CREATE INDEX IF NOT EXISTS idx_dm_reports_thread ON public.dm_reports (thread_id);

COMMENT ON TABLE public.dm_reports IS 'Reports filed on DM abuse';

-- ─────────────────────────────────────────────
-- Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE public.dm_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dm_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dm_thread_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dm_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dm_reports ENABLE ROW LEVEL SECURITY;
