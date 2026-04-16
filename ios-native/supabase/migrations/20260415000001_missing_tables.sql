-- =============================================================================
-- Migration: Missing tables referenced by iOS code
-- challenge_entries, social_tokens, project_likes
-- =============================================================================

-- ─── challenge_entries: Track user submissions to challenges ───
CREATE TABLE IF NOT EXISTS public.challenge_entries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    challenge_id uuid NOT NULL REFERENCES public.challenges(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    project_id uuid REFERENCES public.studio_projects(id) ON DELETE SET NULL,
    title text,
    description text,
    video_url text,
    thumbnail_url text,
    status text NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted', 'approved', 'rejected', 'winner')),
    votes integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(challenge_id, user_id)
);

ALTER TABLE public.challenge_entries ENABLE ROW LEVEL SECURITY;

-- Anyone can see approved entries
CREATE POLICY "challenge_entries_select" ON public.challenge_entries
    FOR SELECT USING (status = 'approved' OR auth.uid() = user_id OR public.is_admin());

-- Users can submit their own entries
CREATE POLICY "challenge_entries_insert" ON public.challenge_entries
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Users can update their own entries
CREATE POLICY "challenge_entries_update" ON public.challenge_entries
    FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());

-- Users can delete their own entries
CREATE POLICY "challenge_entries_delete" ON public.challenge_entries
    FOR DELETE USING (auth.uid() = user_id OR public.is_admin());

CREATE INDEX idx_challenge_entries_challenge ON public.challenge_entries(challenge_id);
CREATE INDEX idx_challenge_entries_user ON public.challenge_entries(user_id);


-- ─── social_tokens: Store OAuth tokens for connected social accounts ───
CREATE TABLE IF NOT EXISTS public.social_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    platform text NOT NULL CHECK (platform IN ('tiktok', 'youtube', 'discord', 'instagram', 'facebook', 'twitter', 'snapchat', 'reddit', 'vimeo')),
    access_token text NOT NULL,
    refresh_token text,
    token_expiry timestamptz,
    platform_user_id text,
    platform_username text,
    scopes text[],
    connected_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(user_id, platform)
);

ALTER TABLE public.social_tokens ENABLE ROW LEVEL SECURITY;

-- Users can only see/manage their own tokens
CREATE POLICY "social_tokens_select" ON public.social_tokens
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "social_tokens_insert" ON public.social_tokens
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "social_tokens_update" ON public.social_tokens
    FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "social_tokens_delete" ON public.social_tokens
    FOR DELETE USING (auth.uid() = user_id);


-- ─── project_likes: Track likes on studio projects (separate from post likes) ───
CREATE TABLE IF NOT EXISTS public.project_likes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES public.studio_projects(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(project_id, user_id)
);

ALTER TABLE public.project_likes ENABLE ROW LEVEL SECURITY;

-- Anyone authenticated can see likes
CREATE POLICY "project_likes_select" ON public.project_likes
    FOR SELECT USING (true);

-- Authenticated users can like
CREATE POLICY "project_likes_insert" ON public.project_likes
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Users can unlike their own
CREATE POLICY "project_likes_delete" ON public.project_likes
    FOR DELETE USING (auth.uid() = user_id);

CREATE INDEX idx_project_likes_project ON public.project_likes(project_id);
CREATE INDEX idx_project_likes_user ON public.project_likes(user_id);
