/**
 * create-checkout — Supabase Edge Function
 *
 * Creates a Stripe Checkout session for Pro subscription ($4.99/mo).
 * Returns the checkout URL for the client to redirect to.
 *
 * Handles:
 *   - New subscriptions
 *   - Existing customers (uses stored customer ID)
 *   - Deep link return URLs for mobile app
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { handleCors, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { verifyAuth, AuthError } from '../_shared/auth.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

interface CheckoutRequest {
  return_url?: string;     // Optional custom return URL (for deep links)
  cancel_url?: string;     // Optional custom cancel URL
  coupon_code?: string;    // Optional coupon/promo code
}

interface StripeCheckoutSession {
  id: string;
  url: string;
}

// ─── Constants ───────────────────────────────────────────────────────────────

const STRIPE_SECRET_KEY = Deno.env.get('STRIPE_SECRET_KEY')!;
const STRIPE_PRO_PRICE_ID = Deno.env.get('STRIPE_PRO_PRICE_ID')!;
const APP_URL = Deno.env.get('APP_URL') ?? 'https://stickdeath.app';
const APP_DEEP_LINK = 'stickdeath://';

// ─── Stripe API Helper ──────────────────────────────────────────────────────

async function stripeRequest<T>(
  endpoint: string,
  method: string,
  body?: Record<string, string | string[]>,
): Promise<T> {
  const url = `https://api.stripe.com/v1${endpoint}`;

  const options: RequestInit = {
    method,
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
  };

  if (body) {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(body)) {
      if (Array.isArray(value)) {
        value.forEach((v) => params.append(key, v));
      } else {
        params.append(key, value);
      }
    }
    options.body = params.toString();
  }

  const response = await fetch(url, options);
  const data = await response.json();

  if (!response.ok) {
    throw new Error(data.error?.message ?? `Stripe API error: ${response.status}`);
  }

  return data as T;
}

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const corsRes = handleCors(req);
  if (corsRes) return corsRes;

  if (req.method !== 'POST') {
    return errorResponse('Method not allowed', 405);
  }

  try {
    const { user, adminClient } = await verifyAuth(req);

    // Check if user already has an active subscription
    const { data: userData } = await adminClient
      .from('users')
      .select('subscription_status, stripe_customer_id, email')
      .eq('id', user.id)
      .single();

    if (userData?.subscription_status === 'active' || userData?.subscription_status === 'trialing') {
      return jsonResponse(
        {
          error: 'Already subscribed',
          message: 'You already have an active Pro subscription.',
          status: userData.subscription_status,
        },
        409,
      );
    }

    let body: CheckoutRequest = {};
    try {
      body = await req.json();
    } catch {
      // No body is fine — use defaults
    }

    const returnUrl = body.return_url ?? `${APP_DEEP_LINK}subscription/success`;
    const cancelUrl = body.cancel_url ?? `${APP_DEEP_LINK}subscription/cancel`;

    // Reuse existing Stripe customer if available (stored on users table)
    const existingCustomerId = userData?.stripe_customer_id;

    // Build checkout session params
    const sessionParams: Record<string, string | string[]> = {
      'mode': 'subscription',
      'payment_method_types[]': ['card'],
      'line_items[0][price]': STRIPE_PRO_PRICE_ID,
      'line_items[0][quantity]': '1',
      'success_url': `${APP_URL}/checkout/success?session_id={CHECKOUT_SESSION_ID}&return=${encodeURIComponent(returnUrl)}`,
      'cancel_url': `${APP_URL}/checkout/cancel?return=${encodeURIComponent(cancelUrl)}`,
      'client_reference_id': user.id,
      'metadata[user_id]': user.id,
      'metadata[app]': 'stickdeath_infinity',
      'subscription_data[metadata][user_id]': user.id,
      'allow_promotion_codes': 'true',
    };

    // Reuse existing Stripe customer if available
    if (existingCustomerId) {
      sessionParams['customer'] = existingCustomerId;
    } else if (userData?.email || user.email) {
      sessionParams['customer_email'] = userData?.email || user.email;
    }

    // Apply coupon if provided
    if (body.coupon_code) {
      sessionParams['discounts[0][coupon]'] = body.coupon_code;
      // Can't use both allow_promotion_codes and discounts
      delete sessionParams['allow_promotion_codes'];
    }

    // Create the Stripe Checkout session
    const session = await stripeRequest<StripeCheckoutSession>(
      '/checkout/sessions',
      'POST',
      sessionParams,
    );

    return jsonResponse({
      checkout_url: session.url,
      session_id: session.id,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.message, err.status);
    }

    console.error('create-checkout error:', err);
    const message =
      err instanceof Error ? err.message : 'Failed to create checkout session';
    return errorResponse(message, 500);
  }
});
