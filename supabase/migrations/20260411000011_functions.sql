-- =============================================================================
-- Migration: Database Functions & Triggers
-- StickDeath Infinity — Supabase Migration 011
-- Triggers, auto-timestamps, stat counters, signup hooks
-- =============================================================================

-- ─────────────────────────────────────────────
-- Generic updated_at trigger function
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- ─────────────────────────────────────────────
-- Apply updated_at triggers to all tables with updated_at column
-- ─────────────────────────────────────────────

-- users
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- profiles
CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- user_stats
CREATE TRIGGER trg_user_stats_updated_at
    BEFORE UPDATE ON public.user_stats
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- community_posts
CREATE TRIGGER trg_community_posts_updated_at
    BEFORE UPDATE ON public.community_posts
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- studio_projects
CREATE TRIGGER trg_studio_projects_updated_at
    BEFORE UPDATE ON public.studio_projects
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- render_jobs
CREATE TRIGGER trg_render_jobs_updated_at
    BEFORE UPDATE ON public.render_jobs
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- publish_jobs
CREATE TRIGGER trg_publish_jobs_updated_at
    BEFORE UPDATE ON public.publish_jobs
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ai_jobs
CREATE TRIGGER trg_ai_jobs_updated_at
    BEFORE UPDATE ON public.ai_jobs
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- dm_threads
CREATE TRIGGER trg_dm_threads_updated_at
    BEFORE UPDATE ON public.dm_threads
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ─────────────────────────────────────────────
-- Auto-create user record on Supabase auth signup
-- Fires when a new user is created in auth.users
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.users (id, email, username, avatar_url, created_at)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data ->> 'username', split_part(NEW.email, '@', 1)),
        COALESCE(NEW.raw_user_meta_data ->> 'avatar_url', NULL),
        now()
    );

    -- Create empty profile
    INSERT INTO public.profiles (user_id, handle, created_at)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data ->> 'username', split_part(NEW.email, '@', 1)),
        now()
    );

    -- Create user_stats row
    INSERT INTO public.user_stats (user_id)
    VALUES (NEW.id);

    -- Create default notification preferences
    INSERT INTO public.notification_preferences (user_id)
    VALUES (NEW.id);

    RETURN NEW;
END;
$$;

-- Attach to auth.users
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ─────────────────────────────────────────────
-- Follow count sync triggers
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_follow_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.user_stats
    SET following_count = following_count + 1
    WHERE user_id = NEW.follower_id;

    UPDATE public.user_stats
    SET followers_count = followers_count + 1
    WHERE user_id = NEW.following_id;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_follow_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.user_stats
    SET following_count = GREATEST(following_count - 1, 0)
    WHERE user_id = OLD.follower_id;

    UPDATE public.user_stats
    SET followers_count = GREATEST(followers_count - 1, 0)
    WHERE user_id = OLD.following_id;

    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_follow_insert
    AFTER INSERT ON public.follows
    FOR EACH ROW EXECUTE FUNCTION public.handle_follow_insert();

CREATE TRIGGER trg_follow_delete
    AFTER DELETE ON public.follows
    FOR EACH ROW EXECUTE FUNCTION public.handle_follow_delete();


-- ─────────────────────────────────────────────
-- Community post like count sync
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_community_like_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.community_posts
    SET like_count = like_count + 1
    WHERE id = NEW.post_id;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_community_like_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.community_posts
    SET like_count = GREATEST(like_count - 1, 0)
    WHERE id = OLD.post_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_community_like_insert
    AFTER INSERT ON public.community_likes
    FOR EACH ROW EXECUTE FUNCTION public.handle_community_like_insert();

CREATE TRIGGER trg_community_like_delete
    AFTER DELETE ON public.community_likes
    FOR EACH ROW EXECUTE FUNCTION public.handle_community_like_delete();


-- ─────────────────────────────────────────────
-- Community post save count sync
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_community_save_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.community_posts
    SET save_count = save_count + 1
    WHERE id = NEW.post_id;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_community_save_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.community_posts
    SET save_count = GREATEST(save_count - 1, 0)
    WHERE id = OLD.post_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_community_save_insert
    AFTER INSERT ON public.community_saves
    FOR EACH ROW EXECUTE FUNCTION public.handle_community_save_insert();

CREATE TRIGGER trg_community_save_delete
    AFTER DELETE ON public.community_saves
    FOR EACH ROW EXECUTE FUNCTION public.handle_community_save_delete();


-- ─────────────────────────────────────────────
-- Legacy post like count sync
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_like_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.posts
    SET like_count = like_count + 1
    WHERE id = NEW.post_id;

    -- Increment likes_received_count on user_stats
    UPDATE public.user_stats
    SET likes_received_count = likes_received_count + 1
    WHERE user_id = (SELECT user_id FROM public.posts WHERE id = NEW.post_id);

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_like_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.posts
    SET like_count = GREATEST(like_count - 1, 0)
    WHERE id = OLD.post_id;

    UPDATE public.user_stats
    SET likes_received_count = GREATEST(likes_received_count - 1, 0)
    WHERE user_id = (SELECT user_id FROM public.posts WHERE id = OLD.post_id);

    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_like_insert
    AFTER INSERT ON public.likes
    FOR EACH ROW EXECUTE FUNCTION public.handle_like_insert();

CREATE TRIGGER trg_like_delete
    AFTER DELETE ON public.likes
    FOR EACH ROW EXECUTE FUNCTION public.handle_like_delete();


-- ─────────────────────────────────────────────
-- Project count sync
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_project_count_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.user_stats
        SET projects_count = projects_count + 1
        WHERE user_id = NEW.user_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.user_stats
        SET projects_count = GREATEST(projects_count - 1, 0)
        WHERE user_id = OLD.user_id;
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER trg_project_insert
    AFTER INSERT ON public.studio_projects
    FOR EACH ROW EXECUTE FUNCTION public.handle_project_count_change();

CREATE TRIGGER trg_project_delete
    AFTER DELETE ON public.studio_projects
    FOR EACH ROW EXECUTE FUNCTION public.handle_project_count_change();


-- ─────────────────────────────────────────────
-- Post count sync
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_post_count_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.user_stats
        SET posts_count = posts_count + 1
        WHERE user_id = NEW.owner_user_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.user_stats
        SET posts_count = GREATEST(posts_count - 1, 0)
        WHERE user_id = OLD.owner_user_id;
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER trg_community_post_insert
    AFTER INSERT ON public.community_posts
    FOR EACH ROW EXECUTE FUNCTION public.handle_post_count_change();

CREATE TRIGGER trg_community_post_delete
    AFTER DELETE ON public.community_posts
    FOR EACH ROW EXECUTE FUNCTION public.handle_post_count_change();


-- ─────────────────────────────────────────────
-- DM thread updated_at on new message
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_dm_message_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE public.dm_threads
    SET updated_at = now()
    WHERE id = NEW.thread_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_dm_message_updates_thread
    AFTER INSERT ON public.dm_messages
    FOR EACH ROW EXECUTE FUNCTION public.handle_dm_message_insert();


-- ─────────────────────────────────────────────
-- Notification creation helpers
-- ─────────────────────────────────────────────

-- Create a follow notification
CREATE OR REPLACE FUNCTION public.create_follow_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    _prefs public.notification_preferences;
    _actor_name text;
BEGIN
    -- Check if recipient has follows notifications enabled
    SELECT * INTO _prefs FROM public.notification_preferences
    WHERE user_id = NEW.following_id;

    IF _prefs IS NULL OR _prefs.follows_enabled THEN
        SELECT COALESCE(p.display_name, u.username, 'Someone')
        INTO _actor_name
        FROM public.users u
        LEFT JOIN public.profiles p ON p.user_id = u.id
        WHERE u.id = NEW.follower_id;

        INSERT INTO public.notifications (user_id, type, actor_id, message)
        VALUES (
            NEW.following_id,
            'follow',
            NEW.follower_id,
            _actor_name || ' started following you'
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_follow_notification
    AFTER INSERT ON public.follows
    FOR EACH ROW EXECUTE FUNCTION public.create_follow_notification();


-- Create a like notification (community posts)
CREATE OR REPLACE FUNCTION public.create_community_like_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    _post public.community_posts;
    _prefs public.notification_preferences;
    _actor_name text;
BEGIN
    SELECT * INTO _post FROM public.community_posts WHERE id = NEW.post_id;

    -- Don't notify if liking own post
    IF _post.owner_user_id = NEW.user_id THEN RETURN NEW; END IF;

    SELECT * INTO _prefs FROM public.notification_preferences
    WHERE user_id = _post.owner_user_id;

    IF _prefs IS NULL OR _prefs.likes_enabled THEN
        SELECT COALESCE(p.display_name, u.username, 'Someone')
        INTO _actor_name
        FROM public.users u
        LEFT JOIN public.profiles p ON p.user_id = u.id
        WHERE u.id = NEW.user_id;

        INSERT INTO public.notifications (user_id, type, actor_id, post_id, message)
        VALUES (
            _post.owner_user_id,
            'like',
            NEW.user_id,
            NEW.post_id,
            _actor_name || ' liked your animation "' || _post.title || '"'
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_community_like_notification
    AFTER INSERT ON public.community_likes
    FOR EACH ROW EXECUTE FUNCTION public.create_community_like_notification();


-- ─────────────────────────────────────────────
-- Utility: increment AI daily limit
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_ai_daily_limit(
    p_user_id uuid,
    p_day_key varchar(10)
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    _count integer;
BEGIN
    INSERT INTO public.ai_limits (user_id, day_key, jobs_count)
    VALUES (p_user_id, p_day_key, 1)
    ON CONFLICT (user_id, day_key) DO UPDATE
    SET jobs_count = ai_limits.jobs_count + 1
    RETURNING jobs_count INTO _count;

    RETURN _count;
END;
$$;


-- ─────────────────────────────────────────────
-- Utility: get or create DM thread
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_or_create_dm_thread(
    p_user_a uuid,
    p_user_b uuid
)
RETURNS varchar
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    _thread_id varchar;
    _a uuid;
    _b uuid;
BEGIN
    -- Ensure consistent ordering
    IF p_user_a < p_user_b THEN
        _a := p_user_a; _b := p_user_b;
    ELSE
        _a := p_user_b; _b := p_user_a;
    END IF;

    -- Try to find existing
    SELECT id INTO _thread_id FROM public.dm_threads
    WHERE user_a_id = _a AND user_b_id = _b;

    IF _thread_id IS NOT NULL THEN
        RETURN _thread_id;
    END IF;

    -- Create new
    INSERT INTO public.dm_threads (user_a_id, user_b_id)
    VALUES (_a, _b)
    RETURNING id INTO _thread_id;

    -- Create thread state for both users
    INSERT INTO public.dm_thread_state (thread_id, user_id) VALUES (_thread_id, _a);
    INSERT INTO public.dm_thread_state (thread_id, user_id) VALUES (_thread_id, _b);

    RETURN _thread_id;
END;
$$;
