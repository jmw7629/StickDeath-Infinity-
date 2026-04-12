-- Migration: Referral system tables
-- v4: Invite a friend → both get 1 month Pro free

-- Referral codes (one per user)
CREATE TABLE IF NOT EXISTS referral_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    code VARCHAR(8) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active BOOLEAN NOT NULL DEFAULT true,
    total_referrals INTEGER NOT NULL DEFAULT 0,
    total_redeemed INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT referral_codes_user_unique UNIQUE (user_id)
);

-- Individual referral records
CREATE TABLE IF NOT EXISTS referrals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    referrer_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    referred_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    referral_code_id UUID NOT NULL REFERENCES referral_codes(id) ON DELETE CASCADE,
    status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'redeemed', 'expired', 'cancelled')),
    pro_granted_referrer BOOLEAN NOT NULL DEFAULT false,
    pro_granted_referred BOOLEAN NOT NULL DEFAULT false,
    pro_expires_referrer TIMESTAMPTZ,
    pro_expires_referred TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    redeemed_at TIMESTAMPTZ,
    CONSTRAINT referrals_no_self CHECK (referrer_id != referred_id),
    CONSTRAINT referrals_unique_pair UNIQUE (referrer_id, referred_id)
);

-- Indexes
CREATE INDEX idx_referral_codes_code ON referral_codes(code);
CREATE INDEX idx_referral_codes_user ON referral_codes(user_id);
CREATE INDEX idx_referrals_referrer ON referrals(referrer_id);
CREATE INDEX idx_referrals_referred ON referrals(referred_id);
CREATE INDEX idx_referrals_status ON referrals(status);

-- RLS
ALTER TABLE referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;

-- Users can read their own referral code
CREATE POLICY "Users can read own referral code"
    ON referral_codes FOR SELECT
    USING (auth.uid() = user_id);

-- Users can insert their own referral code
CREATE POLICY "Users can create own referral code"
    ON referral_codes FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Anyone can look up a code (for redemption)
CREATE POLICY "Anyone can lookup codes"
    ON referral_codes FOR SELECT
    USING (true);

-- Users can see referrals they're part of
CREATE POLICY "Users can see own referrals"
    ON referrals FOR SELECT
    USING (auth.uid() = referrer_id OR auth.uid() = referred_id);

-- Service role manages referral creation (via edge function)
CREATE POLICY "Service can manage referrals"
    ON referrals FOR ALL
    USING (auth.role() = 'service_role');

-- Function: grant referral Pro (called by edge function)
CREATE OR REPLACE FUNCTION grant_referral_pro(
    p_referral_id UUID,
    p_duration_days INTEGER DEFAULT 30
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_referrer_id UUID;
    v_referred_id UUID;
    v_expires TIMESTAMPTZ;
BEGIN
    v_expires := now() + (p_duration_days || ' days')::INTERVAL;

    SELECT referrer_id, referred_id INTO v_referrer_id, v_referred_id
    FROM referrals WHERE id = p_referral_id;

    -- Update referral record
    UPDATE referrals SET
        status = 'redeemed',
        redeemed_at = now(),
        pro_granted_referrer = true,
        pro_granted_referred = true,
        pro_expires_referrer = v_expires,
        pro_expires_referred = v_expires
    WHERE id = p_referral_id;

    -- Update referral code stats
    UPDATE referral_codes SET total_redeemed = total_redeemed + 1
    WHERE user_id = v_referrer_id;

    -- Grant Pro to both users in profiles
    UPDATE profiles SET
        is_pro = true,
        pro_expires_at = GREATEST(COALESCE(pro_expires_at, now()), v_expires)
    WHERE id IN (v_referrer_id, v_referred_id);
END;
$$;
