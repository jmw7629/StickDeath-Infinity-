// POST /functions/v1/manage-subscription
// Manage existing subscriptions: cancel, reactivate, or create a billing portal session.
// Body: { action: "cancel" | "reactivate" | "portal", returnUrl?: string }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { handleCors, jsonResponse, errorResponse } from "../_shared/cors.ts";
import { supabaseAdmin, getUser } from "../_shared/supabase.ts";
import { stripe } from "../_shared/stripe.ts";

serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  try {
    const user = await getUser(req);
    if (!user) return errorResponse("Unauthorized", 401);

    const { action, returnUrl } = await req.json();

    const { data: dbUser } = await supabaseAdmin
      .from("users")
      .select("id, stripe_customer_id, stripe_subscription_id")
      .eq("id", user.id)
      .single();

    if (!dbUser) return errorResponse("User not found", 404);

    switch (action) {
      case "portal": {
        // Open Stripe Customer Portal for self-service
        if (!dbUser.stripe_customer_id) {
          return errorResponse("No billing account found. Subscribe first.");
        }

        const portalSession = await stripe.billingPortal.sessions.create({
          customer: dbUser.stripe_customer_id,
          return_url: returnUrl || `${req.headers.get("origin")}/settings`,
        });

        return jsonResponse({ url: portalSession.url });
      }

      case "cancel": {
        if (!dbUser.stripe_subscription_id) {
          return errorResponse("No active subscription to cancel");
        }

        // Cancel at period end (don't immediately revoke access)
        const subscription = await stripe.subscriptions.update(
          dbUser.stripe_subscription_id,
          { cancel_at_period_end: true }
        );

        await supabaseAdmin
          .from("subscriptions")
          .update({
            cancel_at_period_end: true,
            updated_at: new Date().toISOString(),
          })
          .eq("user_id", dbUser.id);

        return jsonResponse({
          status: "canceling",
          cancelAt: new Date(subscription.current_period_end * 1000).toISOString(),
          message: "Your subscription will remain active until the end of the billing period.",
        });
      }

      case "reactivate": {
        if (!dbUser.stripe_subscription_id) {
          return errorResponse("No subscription to reactivate");
        }

        await stripe.subscriptions.update(dbUser.stripe_subscription_id, {
          cancel_at_period_end: false,
        });

        await supabaseAdmin
          .from("subscriptions")
          .update({
            cancel_at_period_end: false,
            updated_at: new Date().toISOString(),
          })
          .eq("user_id", dbUser.id);

        return jsonResponse({
          status: "active",
          message: "Your subscription has been reactivated!",
        });
      }

      default:
        return errorResponse("Invalid action. Use 'cancel', 'reactivate', or 'portal'.");
    }
  } catch (err) {
    console.error("manage-subscription error:", err);
    return errorResponse(err.message, 500);
  }
});
