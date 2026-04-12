-- =============================================================================
-- Migration: Row Level Security Policies
-- StickDeath Infinity — Supabase Migration 009
--
-- Convention:
--   auth.uid()       = current authenticated user's ID
--   is_admin()       = helper to check admin role
--   Anon users get read-only on public content
--   Authenticated users can CRUD their own data
--   Admins can read/write everything
-- =============================================================================

-- ─────────────────────────────────────────────
-- Helper function: check if current user is admin
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND role = 'admin'
    );
$$;

-- ─────────────────────────────────────────────
-- Helper: check if user is banned
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_not_banned()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (banned = true OR shadowbanned = true)
    );
$$;


-- =============================================
-- USERS
-- =============================================
CREATE POLICY "users_select_public" ON public.users
    FOR SELECT USING (true);

CREATE POLICY "users_update_own" ON public.users
    FOR UPDATE USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

CREATE POLICY "users_admin_all" ON public.users
    FOR ALL USING (public.is_admin());


-- =============================================
-- PROFILES
-- =============================================
CREATE POLICY "profiles_select_public" ON public.profiles
    FOR SELECT USING (true);

CREATE POLICY "profiles_insert_own" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "profiles_update_own" ON public.profiles
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "profiles_admin_all" ON public.profiles
    FOR ALL USING (public.is_admin());


-- =============================================
-- USER_STATS
-- =============================================
CREATE POLICY "user_stats_select_public" ON public.user_stats
    FOR SELECT USING (true);

CREATE POLICY "user_stats_admin_all" ON public.user_stats
    FOR ALL USING (public.is_admin());


-- =============================================
-- ASSETS
-- =============================================
CREATE POLICY "assets_select_own" ON public.assets
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "assets_insert_own" ON public.assets
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "assets_delete_own" ON public.assets
    FOR DELETE USING (auth.uid() = user_id);

CREATE POLICY "assets_admin_all" ON public.assets
    FOR ALL USING (public.is_admin());


-- =============================================
-- SESSIONS (service role only)
-- =============================================
CREATE POLICY "sessions_service_only" ON public.sessions
    FOR ALL USING (false);  -- Only accessible via service_role key


-- =============================================
-- WAITLIST
-- =============================================
CREATE POLICY "waitlist_insert_anon" ON public.waitlist
    FOR INSERT WITH CHECK (true);

CREATE POLICY "waitlist_select_admin" ON public.waitlist
    FOR SELECT USING (public.is_admin());


-- =============================================
-- POLICY_ACCEPTANCE_LOG
-- =============================================
CREATE POLICY "policy_log_insert_own" ON public.policy_acceptance_log
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "policy_log_select_own" ON public.policy_acceptance_log
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "policy_log_admin_all" ON public.policy_acceptance_log
    FOR ALL USING (public.is_admin());


-- =============================================
-- FOLLOWS
-- =============================================
CREATE POLICY "follows_select_public" ON public.follows
    FOR SELECT USING (true);

CREATE POLICY "follows_insert_own" ON public.follows
    FOR INSERT WITH CHECK (auth.uid() = follower_id AND public.is_not_banned());

CREATE POLICY "follows_delete_own" ON public.follows
    FOR DELETE USING (auth.uid() = follower_id);


-- =============================================
-- POSTS (legacy)
-- =============================================
CREATE POLICY "posts_select_public" ON public.posts
    FOR SELECT USING (hidden = false OR auth.uid() = user_id OR public.is_admin());

CREATE POLICY "posts_insert_own" ON public.posts
    FOR INSERT WITH CHECK (auth.uid() = user_id AND public.is_not_banned());

CREATE POLICY "posts_update_own" ON public.posts
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "posts_delete_own" ON public.posts
    FOR DELETE USING (auth.uid() = user_id OR public.is_admin());


-- =============================================
-- COMMUNITY_POSTS
-- =============================================
CREATE POLICY "community_posts_select_public" ON public.community_posts
    FOR SELECT USING (
        status = 'approved'
        OR auth.uid() = owner_user_id
        OR public.is_admin()
    );

CREATE POLICY "community_posts_insert_own" ON public.community_posts
    FOR INSERT WITH CHECK (auth.uid() = owner_user_id AND public.is_not_banned());

CREATE POLICY "community_posts_update_own" ON public.community_posts
    FOR UPDATE USING (auth.uid() = owner_user_id OR public.is_admin());

CREATE POLICY "community_posts_delete_own" ON public.community_posts
    FOR DELETE USING (auth.uid() = owner_user_id OR public.is_admin());


-- =============================================
-- COMMUNITY_LIKES
-- =============================================
CREATE POLICY "community_likes_select_public" ON public.community_likes
    FOR SELECT USING (true);

CREATE POLICY "community_likes_insert_own" ON public.community_likes
    FOR INSERT WITH CHECK (auth.uid() = user_id AND public.is_not_banned());

CREATE POLICY "community_likes_delete_own" ON public.community_likes
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- COMMUNITY_SAVES
-- =============================================
CREATE POLICY "community_saves_select_own" ON public.community_saves
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "community_saves_insert_own" ON public.community_saves
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "community_saves_delete_own" ON public.community_saves
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- LIKES (legacy)
-- =============================================
CREATE POLICY "likes_select_public" ON public.likes
    FOR SELECT USING (true);

CREATE POLICY "likes_insert_own" ON public.likes
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "likes_delete_own" ON public.likes
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- COMMENTS
-- =============================================
CREATE POLICY "comments_select_public" ON public.comments
    FOR SELECT USING (true);

CREATE POLICY "comments_insert_own" ON public.comments
    FOR INSERT WITH CHECK (auth.uid() = user_id AND public.is_not_banned());

CREATE POLICY "comments_update_own" ON public.comments
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "comments_delete_own" ON public.comments
    FOR DELETE USING (auth.uid() = user_id OR public.is_admin());


-- =============================================
-- STUDIO_PROJECTS
-- =============================================
CREATE POLICY "studio_projects_select_own" ON public.studio_projects
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "studio_projects_insert_own" ON public.studio_projects
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "studio_projects_update_own" ON public.studio_projects
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "studio_projects_delete_own" ON public.studio_projects
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- STUDIO_PROJECT_VERSIONS
-- =============================================
CREATE POLICY "studio_versions_select_own" ON public.studio_project_versions
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "studio_versions_insert_own" ON public.studio_project_versions
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "studio_versions_delete_own" ON public.studio_project_versions
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- STUDIO_ASSETS
-- =============================================
CREATE POLICY "studio_assets_select_own" ON public.studio_assets
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "studio_assets_insert_own" ON public.studio_assets
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "studio_assets_delete_own" ON public.studio_assets
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- STUDIO_SFX (global library — read public)
-- =============================================
CREATE POLICY "studio_sfx_select_public" ON public.studio_sfx
    FOR SELECT USING (true);

CREATE POLICY "studio_sfx_admin_all" ON public.studio_sfx
    FOR ALL USING (public.is_admin());


-- =============================================
-- STUDIO_LIBRARY_ASSETS (global library — read public)
-- =============================================
CREATE POLICY "library_assets_select_public" ON public.studio_library_assets
    FOR SELECT USING (true);

CREATE POLICY "library_assets_admin_all" ON public.studio_library_assets
    FOR ALL USING (public.is_admin());


-- =============================================
-- LIBRARY_SOURCES (global — read public)
-- =============================================
CREATE POLICY "library_sources_select_public" ON public.library_sources
    FOR SELECT USING (true);

CREATE POLICY "library_sources_admin_all" ON public.library_sources
    FOR ALL USING (public.is_admin());


-- =============================================
-- LIBRARY_ASSET_VARIANTS (global — read public)
-- =============================================
CREATE POLICY "library_variants_select_public" ON public.library_asset_variants
    FOR SELECT USING (true);

CREATE POLICY "library_variants_admin_all" ON public.library_asset_variants
    FOR ALL USING (public.is_admin());


-- =============================================
-- FRAME_AUDIO
-- =============================================
CREATE POLICY "frame_audio_select_own" ON public.frame_audio
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.studio_projects sp
            WHERE sp.id = frame_audio.project_id AND sp.user_id = auth.uid()
        )
        OR public.is_admin()
    );

CREATE POLICY "frame_audio_insert_own" ON public.frame_audio
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.studio_projects sp
            WHERE sp.id = frame_audio.project_id AND sp.user_id = auth.uid()
        )
    );

CREATE POLICY "frame_audio_update_own" ON public.frame_audio
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM public.studio_projects sp
            WHERE sp.id = frame_audio.project_id AND sp.user_id = auth.uid()
        )
    );

CREATE POLICY "frame_audio_delete_own" ON public.frame_audio
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM public.studio_projects sp
            WHERE sp.id = frame_audio.project_id AND sp.user_id = auth.uid()
        )
    );


-- =============================================
-- DM_THREADS
-- =============================================
CREATE POLICY "dm_threads_select_participant" ON public.dm_threads
    FOR SELECT USING (auth.uid() = user_a_id OR auth.uid() = user_b_id);

CREATE POLICY "dm_threads_insert_participant" ON public.dm_threads
    FOR INSERT WITH CHECK (
        (auth.uid() = user_a_id OR auth.uid() = user_b_id)
        AND public.is_not_banned()
    );


-- =============================================
-- DM_MESSAGES
-- =============================================
CREATE POLICY "dm_messages_select_participant" ON public.dm_messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.dm_threads dt
            WHERE dt.id = dm_messages.thread_id
            AND (dt.user_a_id = auth.uid() OR dt.user_b_id = auth.uid())
        )
    );

CREATE POLICY "dm_messages_insert_sender" ON public.dm_messages
    FOR INSERT WITH CHECK (
        auth.uid() = sender_user_id
        AND public.is_not_banned()
        AND EXISTS (
            SELECT 1 FROM public.dm_threads dt
            WHERE dt.id = dm_messages.thread_id
            AND (dt.user_a_id = auth.uid() OR dt.user_b_id = auth.uid())
        )
        AND NOT EXISTS (
            SELECT 1 FROM public.dm_blocks db
            WHERE (db.blocker_user_id = (
                SELECT CASE
                    WHEN dt.user_a_id = auth.uid() THEN dt.user_b_id
                    ELSE dt.user_a_id
                END FROM public.dm_threads dt WHERE dt.id = dm_messages.thread_id
            ) AND db.blocked_user_id = auth.uid())
        )
    );


-- =============================================
-- DM_THREAD_STATE
-- =============================================
CREATE POLICY "dm_thread_state_select_own" ON public.dm_thread_state
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "dm_thread_state_upsert_own" ON public.dm_thread_state
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "dm_thread_state_update_own" ON public.dm_thread_state
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);


-- =============================================
-- DM_BLOCKS
-- =============================================
CREATE POLICY "dm_blocks_select_own" ON public.dm_blocks
    FOR SELECT USING (auth.uid() = blocker_user_id);

CREATE POLICY "dm_blocks_insert_own" ON public.dm_blocks
    FOR INSERT WITH CHECK (auth.uid() = blocker_user_id);

CREATE POLICY "dm_blocks_delete_own" ON public.dm_blocks
    FOR DELETE USING (auth.uid() = blocker_user_id);


-- =============================================
-- DM_REPORTS
-- =============================================
CREATE POLICY "dm_reports_insert_own" ON public.dm_reports
    FOR INSERT WITH CHECK (auth.uid() = reporter_user_id);

CREATE POLICY "dm_reports_select_own" ON public.dm_reports
    FOR SELECT USING (auth.uid() = reporter_user_id OR public.is_admin());

CREATE POLICY "dm_reports_admin_all" ON public.dm_reports
    FOR ALL USING (public.is_admin());


-- =============================================
-- RENDER_JOBS
-- =============================================
CREATE POLICY "render_jobs_select_own" ON public.render_jobs
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "render_jobs_insert_own" ON public.render_jobs
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "render_jobs_update_own" ON public.render_jobs
    FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());


-- =============================================
-- PUBLISH_JOBS
-- =============================================
CREATE POLICY "publish_jobs_select_own" ON public.publish_jobs
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "publish_jobs_insert_own" ON public.publish_jobs
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "publish_jobs_update_own" ON public.publish_jobs
    FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());


-- =============================================
-- YOUTUBE_SUBMIT_STATUS
-- =============================================
CREATE POLICY "youtube_status_select_own" ON public.youtube_submit_status
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "youtube_status_upsert_own" ON public.youtube_submit_status
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "youtube_status_update_own" ON public.youtube_submit_status
    FOR UPDATE USING (auth.uid() = user_id);


-- =============================================
-- AI_JOBS
-- =============================================
CREATE POLICY "ai_jobs_select_own" ON public.ai_jobs
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

CREATE POLICY "ai_jobs_insert_own" ON public.ai_jobs
    FOR INSERT WITH CHECK (auth.uid() = user_id AND public.is_not_banned());

CREATE POLICY "ai_jobs_update_own" ON public.ai_jobs
    FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());


-- =============================================
-- AI_LIMITS
-- =============================================
CREATE POLICY "ai_limits_select_own" ON public.ai_limits
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "ai_limits_admin_all" ON public.ai_limits
    FOR ALL USING (public.is_admin());


-- =============================================
-- AI_OUTPUTS
-- =============================================
CREATE POLICY "ai_outputs_select_own" ON public.ai_outputs
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.ai_jobs aj
            WHERE aj.id = ai_outputs.job_id AND aj.user_id = auth.uid()
        )
        OR public.is_admin()
    );


-- =============================================
-- CHALLENGES
-- =============================================
CREATE POLICY "challenges_select_public" ON public.challenges
    FOR SELECT USING (true);

CREATE POLICY "challenges_admin_all" ON public.challenges
    FOR ALL USING (public.is_admin());


-- =============================================
-- CREATOR_BADGES
-- =============================================
CREATE POLICY "creator_badges_select_public" ON public.creator_badges
    FOR SELECT USING (true);

CREATE POLICY "creator_badges_admin_all" ON public.creator_badges
    FOR ALL USING (public.is_admin());


-- =============================================
-- USER_BADGES
-- =============================================
CREATE POLICY "user_badges_select_public" ON public.user_badges
    FOR SELECT USING (true);

CREATE POLICY "user_badges_admin_all" ON public.user_badges
    FOR ALL USING (public.is_admin());


-- =============================================
-- TIPS
-- =============================================
CREATE POLICY "tips_select_own" ON public.tips
    FOR SELECT USING (auth.uid() = from_user_id OR auth.uid() = to_user_id OR public.is_admin());

CREATE POLICY "tips_insert_own" ON public.tips
    FOR INSERT WITH CHECK (auth.uid() = from_user_id AND public.is_not_banned());


-- =============================================
-- NOTIFICATIONS
-- =============================================
CREATE POLICY "notifications_select_own" ON public.notifications
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "notifications_update_own" ON public.notifications
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "notifications_delete_own" ON public.notifications
    FOR DELETE USING (auth.uid() = user_id);


-- =============================================
-- NOTIFICATION_PREFERENCES
-- =============================================
CREATE POLICY "notif_prefs_select_own" ON public.notification_preferences
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "notif_prefs_insert_own" ON public.notification_preferences
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "notif_prefs_update_own" ON public.notification_preferences
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);


-- =============================================
-- ADMIN_ACTIONS (admin only)
-- =============================================
CREATE POLICY "admin_actions_admin_only" ON public.admin_actions
    FOR ALL USING (public.is_admin());


-- =============================================
-- REPORTS
-- =============================================
CREATE POLICY "reports_insert_authenticated" ON public.reports
    FOR INSERT WITH CHECK (auth.uid() = reporter_id);

CREATE POLICY "reports_select_own" ON public.reports
    FOR SELECT USING (auth.uid() = reporter_id OR public.is_admin());

CREATE POLICY "reports_admin_all" ON public.reports
    FOR ALL USING (public.is_admin());


-- =============================================
-- BROADCASTS
-- =============================================
CREATE POLICY "broadcasts_select_authenticated" ON public.broadcasts
    FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "broadcasts_admin_all" ON public.broadcasts
    FOR ALL USING (public.is_admin());


-- =============================================
-- BROADCAST_DELIVERY
-- =============================================
CREATE POLICY "broadcast_delivery_select_own" ON public.broadcast_delivery
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "broadcast_delivery_update_own" ON public.broadcast_delivery
    FOR UPDATE USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "broadcast_delivery_admin_all" ON public.broadcast_delivery
    FOR ALL USING (public.is_admin());


-- =============================================
-- CONVERSATIONS / MESSAGES (legacy AI chat)
-- =============================================
CREATE POLICY "conversations_authenticated" ON public.conversations
    FOR ALL USING (auth.uid() IS NOT NULL);

CREATE POLICY "messages_authenticated" ON public.messages
    FOR ALL USING (auth.uid() IS NOT NULL);


-- =============================================
-- STRIPE SCHEMA — service_role only (no client access)
-- All stripe tables are blocked for anon/authenticated
-- =============================================
DO $$
DECLARE
    tbl text;
BEGIN
    FOR tbl IN
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'stripe'
    LOOP
        EXECUTE format(
            'CREATE POLICY "stripe_%s_service_only" ON stripe.%I FOR ALL USING (false)',
            tbl, tbl
        );
    END LOOP;
END $$;
