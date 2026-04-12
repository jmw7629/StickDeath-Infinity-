/**
 * stripe-webhook — Supabase Edge Function
 *
 * Handles Stripe webhook events for subscription management.
 * Verifies signatures, updates users + subscriptions tables,
 * and stores raw events for audit/debugging.
 *
 * Events handled:
 *   - checkout.session.completed
 *   - customer.subscription.created / updated / deleted
 *   - invoice.paid / payment_failed
 */

import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { corsHeaders, jsonResponse, errorResponse } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

// ─── Types ───────────────────────────────────────────────────────────────────

interface StripeEvent {
  id: string;
  type: string;
  data: { object: Record<string, unknown> };
}

interface StripeCheckoutSession {
  id: string;
  customer: string;
  subscription: string;
  client_reference_id: string; // user_id
  customer_email: string;
  metadata: Record<string, string>;
}

interface StripeSubscription {
  id: string;
  customer: string;
  status: string;
  current_period_start: number;
  current_period_end: number;
  cancel_at_period_end: boolean;
  canceled_at: number | null;
  items: {
    data: Array<{
      price: {
        id: string;
        product: string;
        unit_amount: number;
        currency: string;
        recurring: { interval: string };
      };
    }>;
  };
  metadata: Record<string, string>;
}

interface StripeInvoice {
  id: string;
  customer: string;
  subscription: string;
  status: string;
  amount_paid: number;
  amount_due: number;
  currency: string;
  hosted_invoice_url: string;
  invoice_pdf: string;
}

// ─── Stripe Signature Verification ──────────────────────────────────────────

const STRIPE_WEBHOOK_SECRET = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;

async function verifyStripeSignature(
  payload: string,
  signature: string,
): Promise<boolean> {
  const parts = signature.split(',');
  const timestampPart = parts.find((p) => p.startsWith('t='));
  const sigPart = parts.find((p) => p.startsWith('v1='));
  if (!timestampPart || !sigPart) return false;

  const timestamp = timestampPart.split('=')[1];
  const expectedSig = sigPart.split('=')[1];

  // Reject events older than 5 minutes
  if (Math.floor(Date.now() / 1000) - parseInt(timestamp) > 300) return false;

  const signedPayload = `${timestamp}.${payload}`;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(STRIPE_WEBHOOK_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(signedPayload));
  const computed = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  return computed === expectedSig;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Resolve a Stripe customer ID → user row. */
async function findUserByStripeCustomer(
  adminClient: ReturnType<typeof createAdminClient>,
  stripeCustomerId: string,
) {
  const { data } = await adminClient
    .from('users')
    .select('id, role, subscription_status, subscription_tier')
    .eq('stripe_customer_id', stripeCustomerId)
    .single();
  return data;
}

/** Map Stripe sub status to a tier label. */
function deriveTier(priceId: string | undefined): string {
  // Future: check priceId against a lookup table.
  // For now, any active subscription = 'pro'.
  return 'pro';
}

// ─── Event Handlers ──────────────────────────────────────────────────────────

async function handleCheckoutCompleted(
  session: StripeCheckoutSession,
  db: ReturnType<typeof createAdminClient>,
) {
  const userId = session.client_reference_id || session.metadata?.user_id;
  if (!userId) {
    console.error('checkout.session.completed: no user_id', session.id);
    return;
  }

  // Link Stripe customer + subscription IDs to the user row
  await db
    .from('users')
    .update({
      stripe_customer_id: session.customer,
      stripe_subscription_id: session.subscription || null,
    })
    .eq('id', userId);

  console.log(`Checkout completed: user=${userId} customer=${session.customer}`);
}

async function handleSubscriptionCreated(
  sub: StripeSubscription,
  db: ReturnType<typeof createAdminClient>,
) {
  const user = await findUserByStripeCustomer(db, sub.customer as string);
  if (!user) {
    console.error('subscription.created: unknown customer', sub.customer);
    return;
  }

  const priceItem = sub.items.data[0];

  // Upsert detailed subscription record
  await db.from('subscriptions').upsert(
    {
      user_id: user.id,
      stripe_subscription_id: sub.id,
      stripe_customer_id: sub.customer as string,
      status: sub.status,
      price_id: priceItem?.price?.id ?? null,
      product_id: (priceItem?.price?.product as string) ?? null,
      current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
      current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
      cancel_at_period_end: sub.cancel_at_period_end,
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'user_id' },
  );

  // Sync denormalized columns on users
  const isActive = sub.status === 'active' || sub.status === 'trialing';
  await db
    .from('users')
    .update({
      stripe_subscription_id: sub.id,
      subscription_status: sub.status,
      subscription_tier: isActive ? deriveTier(priceItem?.price?.id) : 'free',
      role: isActive ? 'pro' : user.role, // only upgrade, never downgrade here
    })
    .eq('id', user.id);

  console.log(`Subscription created: user=${user.id} status=${sub.status}`);
}

async function handleSubscriptionUpdated(
  sub: StripeSubscription,
  db: ReturnType<typeof createAdminClient>,
) {
  const user = await findUserByStripeCustomer(db, sub.customer as string);
  if (!user) {
    console.error('subscription.updated: unknown customer', sub.customer);
    return;
  }

  // Update detailed record
  await db
    .from('subscriptions')
    .update({
      status: sub.status,
      current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
      current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
      cancel_at_period_end: sub.cancel_at_period_end,
      canceled_at: sub.canceled_at
        ? new Date(sub.canceled_at * 1000).toISOString()
        : null,
      updated_at: new Date().toISOString(),
    })
    .eq('stripe_subscription_id', sub.id);

  // Sync users row
  const isActive = sub.status === 'active' || sub.status === 'trialing';
  await db
    .from('users')
    .update({
      subscription_status: sub.status,
      subscription_tier: isActive ? deriveTier(undefined) : 'free',
      role: isActive ? 'pro' : 'free',
    })
    .eq('id', user.id);

  // Notify on downgrade
  if (!isActive) {
    await db.from('notifications').insert({
      user_id: user.id,
      type: 'subscription_ended',
      title: 'Subscription ended',
      body: 'Your Pro subscription has ended. Re-subscribe anytime to unlock Pro features.',
      data: { subscription_id: sub.id },
    });
  }

  console.log(`Subscription updated: user=${user.id} status=${sub.status}`);
}

async function handleSubscriptionDeleted(
  sub: StripeSubscription,
  db: ReturnType<typeof createAdminClient>,
) {
  const user = await findUserByStripeCustomer(db, sub.customer as string);
  if (!user) return;

  await db
    .from('subscriptions')
    .update({
      status: 'canceled',
      canceled_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('stripe_subscription_id', sub.id);

  await db
    .from('users')
    .update({
      subscription_status: 'canceled',
      subscription_tier: 'free',
      role: 'free',
    })
    .eq('id', user.id);

  await db.from('notifications').insert({
    user_id: user.id,
    type: 'subscription_canceled',
    title: 'Pro subscription canceled',
    body: 'Your Pro features have been deactivated. Re-subscribe any time!',
    data: { subscription_id: sub.id },
  });

  console.log(`Subscription deleted: user=${user.id}`);
}

async function handleInvoicePaid(
  inv: StripeInvoice,
  db: ReturnType<typeof createAdminClient>,
) {
  const user = await findUserByStripeCustomer(db, inv.customer as string);
  if (!user) return;

  console.log(`Invoice paid: user=${user.id} amount=$${inv.amount_paid / 100}`);
}

async function handlePaymentFailed(
  inv: StripeInvoice,
  db: ReturnType<typeof createAdminClient>,
) {
  const user = await findUserByStripeCustomer(db, inv.customer as string);
  if (!user) return;

  await db.from('notifications').insert({
    user_id: user.id,
    type: 'payment_failed',
    title: 'Payment failed',
    body: "We couldn't process your payment. Please update your payment method to keep Pro.",
    data: { invoice_id: inv.id, invoice_url: inv.hosted_invoice_url },
  });

  console.log(`Payment failed: user=${user.id}`);
}

// ─── Main Handler ────────────────────────────────────────────────────────────

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders, status: 200 });
  }
  if (req.method !== 'POST') {
    return errorResponse('Method not allowed', 405);
  }

  try {
    const body = await req.text();
    const signature = req.headers.get('stripe-signature');
    if (!signature) return errorResponse('Missing Stripe signature', 400);

    const isValid = await verifyStripeSignature(body, signature);
    if (!isValid) return errorResponse('Invalid Stripe signature', 403);

    const event: StripeEvent = JSON.parse(body);
    const db = createAdminClient();

    // Idempotency — skip already-processed events
    const { data: existing } = await db
      .from('stripe_events')
      .select('id')
      .eq('stripe_event_id', event.id)
      .maybeSingle();

    if (existing) {
      console.log(`Duplicate event skipped: ${event.id}`);
      return jsonResponse({ received: true, duplicate: true });
    }

    // Store raw event
    await db.from('stripe_events').insert({
      stripe_event_id: event.id,
      type: event.type,
      data: event.data.object,
      processed: false,
    });

    // Route
    switch (event.type) {
      case 'checkout.session.completed':
        await handleCheckoutCompleted(event.data.object as unknown as StripeCheckoutSession, db);
        break;
      case 'customer.subscription.created':
        await handleSubscriptionCreated(event.data.object as unknown as StripeSubscription, db);
        break;
      case 'customer.subscription.updated':
        await handleSubscriptionUpdated(event.data.object as unknown as StripeSubscription, db);
        break;
      case 'customer.subscription.deleted':
        await handleSubscriptionDeleted(event.data.object as unknown as StripeSubscription, db);
        break;
      case 'invoice.paid':
        await handleInvoicePaid(event.data.object as unknown as StripeInvoice, db);
        break;
      case 'invoice.payment_failed':
        await handlePaymentFailed(event.data.object as unknown as StripeInvoice, db);
        break;
      default:
        console.log(`Unhandled event type: ${event.type}`);
    }

    // Mark processed
    await db
      .from('stripe_events')
      .update({ processed: true })
      .eq('stripe_event_id', event.id);

    return jsonResponse({ received: true });
  } catch (err) {
    console.error('stripe-webhook error:', err);
    return errorResponse('Webhook processing failed', 500);
  }
});
