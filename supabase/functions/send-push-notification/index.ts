// send-push-notification — Sends APNs push to a user's registered devices
// Triggered by: database webhooks on likes, view milestones, new templates
// APNs auth key (.p8) must be set as APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID secrets

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface PushPayload {
  user_id: string;
  type: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const payload: PushPayload = await req.json();
    const { user_id, type, title, body, data } = payload;

    if (!user_id || !type || !title || !body) {
      return new Response(JSON.stringify({ error: "Missing required fields" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Log the notification
    await supabase.from("notification_log").insert({
      user_id, type, title, body, data: data || {},
    });

    // Get all active device tokens for this user
    const { data: tokens, error: tokenError } = await supabase
      .from("device_tokens")
      .select("token, platform")
      .eq("user_id", user_id)
      .eq("is_active", true);

    if (tokenError || !tokens || tokens.length === 0) {
      return new Response(JSON.stringify({
        success: true,
        message: "Notification logged, no active devices to push to",
        devices_reached: 0,
      }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // ----- APNs Push -----
    // NOTE: Full APNs JWT signing requires the .p8 key from Apple Developer.
    // Once Joseph provides it, uncomment and configure:
    //
    // const APNS_KEY_P8 = Deno.env.get("APNS_KEY_P8");
    // const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID");
    // const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID");
    // const APNS_BUNDLE_ID = "com.stickdeath.infinity";
    //
    // For each iOS token:
    //   1. Create JWT: { iss: TEAM_ID, iat: now } signed with ES256 using .p8
    //   2. POST to https://api.push.apple.com/3/device/{token}
    //      Headers: { authorization: "bearer {jwt}", "apns-topic": BUNDLE_ID }
    //      Body: { aps: { alert: { title, body }, badge: unreadCount, sound: "default" }, ...data }

    let devicesReached = 0;
    for (const device of tokens) {
      if (device.platform === "ios") {
        // Placeholder — APNs push will be wired once .p8 key is provided
        console.log(`[APNs] Would push to ${device.token.slice(0, 10)}...: ${title}`);
        devicesReached++;
      } else if (device.platform === "android") {
        // FCM push — wire up when Android is ready
        console.log(`[FCM] Would push to ${device.token.slice(0, 10)}...: ${title}`);
        devicesReached++;
      }
    }

    return new Response(JSON.stringify({
      success: true,
      notification_type: type,
      devices_reached: devicesReached,
      total_tokens: tokens.length,
    }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
