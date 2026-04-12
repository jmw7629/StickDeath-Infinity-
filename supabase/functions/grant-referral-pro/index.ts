// grant-referral-pro — Validates and redeems a referral code, grants Pro to both users
// Called by ReferralService.swift when a user enters a referral code

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Get the calling user
    const authHeader = req.headers.get("Authorization")!;
    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", "")
    );
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { code } = await req.json();
    if (!code || typeof code !== "string") {
      return new Response(JSON.stringify({ error: "Missing referral code" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Look up the referral code
    const { data: refCode, error: codeError } = await supabase
      .from("referral_codes")
      .select("*")
      .eq("code", code.toUpperCase())
      .eq("is_active", true)
      .single();

    if (codeError || !refCode) {
      return new Response(JSON.stringify({ error: "Invalid or expired referral code" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Prevent self-referral
    if (refCode.user_id === user.id) {
      return new Response(JSON.stringify({ error: "Cannot use your own referral code" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Check for duplicate referral
    const { data: existing } = await supabase
      .from("referrals")
      .select("id")
      .eq("referrer_id", refCode.user_id)
      .eq("referred_id", user.id)
      .single();

    if (existing) {
      return new Response(JSON.stringify({ error: "You've already used a referral from this user" }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Create referral record
    const { data: referral, error: insertError } = await supabase
      .from("referrals")
      .insert({
        referrer_id: refCode.user_id,
        referred_id: user.id,
        referral_code_id: refCode.id,
        status: "pending",
      })
      .select()
      .single();

    if (insertError) {
      return new Response(JSON.stringify({ error: "Failed to create referral" }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Grant Pro to both users (30 days)
    const { error: grantError } = await supabase.rpc("grant_referral_pro", {
      p_referral_id: referral.id,
      p_duration_days: 30,
    });

    if (grantError) {
      return new Response(JSON.stringify({ error: "Failed to grant Pro: " + grantError.message }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Bump referral code total_referrals
    await supabase
      .from("referral_codes")
      .update({ total_referrals: refCode.total_referrals + 1 })
      .eq("id", refCode.id);

    return new Response(JSON.stringify({
      success: true,
      message: "Referral redeemed! Both you and your friend get 1 month of Pro.",
      referral_id: referral.id,
    }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
