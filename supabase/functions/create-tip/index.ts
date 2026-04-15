// POST /functions/v1/create-tip
// Creates a Stripe PaymentIntent for tipping a creator.
// Body: { toUserId: string, amountCents: number, postId?: number }

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { handleCors, jsonResponse, errorResponse } from "../_shared/cors.ts";
import { supabaseAdmin, getUser } from "../_shared/supabase.ts";
import { stripe } from "../_shared/stripe.ts";

const MIN_TIP_CENTS = 100; // $1.00 minimum
const MAX_TIP_CENTS = 50000; // $500.00 maximum

serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;

  try {
    // ── Auth ──
    const user = await getUser(req);
    if (!user) return errorResponse("Unauthorized", 401);

    const { toUserId, amountCents, postId } = await req.json();

    // ── Validate ──
    if (!toUserId || !amountCents) {
      return errorResponse("toUserId and amountCents are required");
    }
    if (toUserId === user.id) {
      return errorResponse("You can't tip yourself");
    }
    if (amountCents < MIN_TIP_CENTS || amountCents > MAX_TIP_CENTS) {
      return errorResponse(`Tip must be between $${MIN_TIP_CENTS / 100} and $${MAX_TIP_CENTS / 100}`);
    }

    // ── Verify recipient exists and has creator mode ──
    const { data: recipient } = await supabaseAdmin
      .from("users")
      .select("id, username, stripe_customer_id, creator_mode_enabled")
      .eq("id", toUserId)
      .single();

    if (!recipient) return errorResponse("Recipient not found", 404);
    if (!recipient.creator_mode_enabled) {
      return errorResponse("This creator doesn't accept tips yet");
    }

    // ── Get or create Stripe customer for the tipper ──
    const { data: fromUser } = await supabaseAdmin
      .from("users")
      .select("id, email, username, stripe_customer_id")
      .eq("id", user.id)
      .single();

    if (!fromUser) return errorResponse("User not found", 404);

    let customerId = fromUser.stripe_customer_id;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: fromUser.email,
        metadata: { supabase_user_id: fromUser.id, username: fromUser.username },
      });
      customerId = customer.id;
      await supabaseAdmin
        .from("users")
        .update({ stripe_customer_id: customerId })
        .eq("id", fromUser.id);
    }

    // ── Create tip record ──
    const { data: tip, error: tipError } = await supabaseAdmin
      .from("tips")
      .insert({
        from_user_id: user.id,
        to_user_id: toUserId,
        post_id: postId ?? null,
        amount_cents: amountCents,
        status: "pending",
      })
      .select("id")
      .single();

    if (tipError || !tip) {
      return errorResponse("Failed to create tip record", 500);
    }

    // ── Create PaymentIntent ──
    const paymentIntent = await stripe.paymentIntents.create({
      amount: amountCents,
      currency: "usd",
      customer: customerId,
      metadata: {
        tip_id: tip.id.toString(),
        from_user_id: user.id,
        to_user_id: toUserId,
        post_id: postId?.toString() ?? "",
      },
      description: `Tip from ${fromUser.username} to ${recipient.username}`,
      automatic_payment_methods: { enabled: true },
    });

    // Update tip with payment intent ID
    await supabaseAdmin
      .from("tips")
      .update({ stripe_payment_intent_id: paymentIntent.id })
      .eq("id", tip.id);

    return jsonResponse({
      tipId: tip.id,
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
    });
  } catch (err) {
    console.error("create-tip error:", err);
    return errorResponse(err.message, 500);
  }
});
