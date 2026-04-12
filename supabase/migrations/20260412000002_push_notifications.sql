-- Migration: Push notification device tokens + analytics helper functions
-- v4: Matches actual schema (users, studio_projects, community_posts, subscriptions)

CREATE TABLE IF NOT EXISTS device_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token TEXT NOT NULL,
    platform VARCHAR(10) NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT device_tokens_unique UNIQUE (user_id, token)
);

CREATE TABLE IF NOT EXISTS notification_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type VARCHAR(30) NOT NULL CHECK (type IN (
        'like', 'view_milestone', 'new_template', 'streak_reminder',
        'new_follower', 'comment', 'feature_announcement', 'referral_reward',
        'pro_expiring', 'weekly_recap'
    )),
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    data JSONB DEFAULT '{}',
    is_read BOOLEAN NOT NULL DEFAULT false,
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at TIMESTAMPTZ
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_device_tokens_user ON device_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_device_tokens_active ON device_tokens(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_notification_log_user ON notification_log(user_id);
CREATE INDEX IF NOT EXISTS idx_notification_log_unread ON notification_log(user_id, is_read) WHERE is_read = false;

-- RLS
ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own device tokens"
    ON device_tokens FOR ALL
    USING (auth.uid() = user_id);

CREATE POLICY "Users read own notifications"
    ON notification_log FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users update own notifications"
    ON notification_log FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Service inserts notifications"
    ON notification_log FOR INSERT
    WITH CHECK (true);

-- ── Analytics helper functions (for Admin Portal) ──

-- Unread notification count for a user
CREATE OR REPLACE FUNCTION get_unread_notification_count(p_user_id UUID)
RETURNS INTEGER LANGUAGE SQL SECURITY DEFINER STABLE AS $$
    SELECT COUNT(*)::INTEGER FROM notification_log
    WHERE user_id = p_user_id AND is_read = false;
$$;

-- DAU based on user registrations (proxy until session tracking is added)
CREATE OR REPLACE FUNCTION get_daily_active_users(p_days INTEGER DEFAULT 30)
RETURNS TABLE(day DATE, count BIGINT) LANGUAGE SQL SECURITY DEFINER STABLE AS $$
    SELECT DATE(created_at) as day, COUNT(*)
    FROM users
    WHERE created_at >= now() - (p_days || ' days')::INTERVAL
    GROUP BY DATE(created_at)
    ORDER BY day;
$$;

-- Daily videos published (community_posts with status)
CREATE OR REPLACE FUNCTION get_daily_videos_published(p_days INTEGER DEFAULT 14)
RETURNS TABLE(day DATE, count BIGINT) LANGUAGE SQL SECURITY DEFINER STABLE AS $$
    SELECT DATE(created_at) as day, COUNT(*)
    FROM community_posts
    WHERE created_at >= now() - (p_days || ' days')::INTERVAL
    GROUP BY DATE(created_at)
    ORDER BY day;
$$;

-- Top creators by published videos, views, likes
CREATE OR REPLACE FUNCTION get_top_creators(p_limit INTEGER DEFAULT 10)
RETURNS TABLE(creator_id UUID, creator_username TEXT, videos BIGINT, total_views BIGINT, total_likes BIGINT)
LANGUAGE SQL SECURITY DEFINER STABLE AS $$
    SELECT
        u.id,
        u.username,
        COUNT(cp.id) as videos,
        COALESCE(SUM(cp.view_count), 0) as total_views,
        COALESCE(SUM(cp.like_count), 0) as total_likes
    FROM users u
    JOIN community_posts cp ON cp.owner_user_id = u.id
    GROUP BY u.id, u.username
    ORDER BY total_views DESC
    LIMIT p_limit;
$$;

-- Subscription funnel
CREATE OR REPLACE FUNCTION get_subscription_funnel()
RETURNS TABLE(tier TEXT, count BIGINT) LANGUAGE SQL SECURITY DEFINER STABLE AS $$
    SELECT 'total_users'::TEXT, COUNT(*) FROM users
    UNION ALL
    SELECT 'active_pro'::TEXT, COUNT(*) FROM subscriptions WHERE status = 'active'
    UNION ALL
    SELECT 'canceled'::TEXT, COUNT(*) FROM subscriptions WHERE status = 'canceled'
    UNION ALL
    SELECT 'past_due'::TEXT, COUNT(*) FROM subscriptions WHERE status = 'past_due';
$$;

-- Platform distribution (where videos are being published)
CREATE OR REPLACE FUNCTION get_platform_distribution()
RETURNS TABLE(platform TEXT, count BIGINT) LANGUAGE SQL SECURITY DEFINER STABLE AS $$
    SELECT
        provider as platform,
        COUNT(*)
    FROM publish_jobs
    WHERE status = 'completed'
    GROUP BY provider
    ORDER BY count DESC;
$$;
