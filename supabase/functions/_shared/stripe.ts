// Shared Stripe client for Edge Functions
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");

if (!stripeSecretKey) {
  console.warn("STRIPE_SECRET_KEY not set — Stripe functions will fail");
}

export const stripe = new Stripe(stripeSecretKey ?? "", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

export const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";

// ── Subscription tier config ──
// Prices will be created in Stripe and IDs stored here.
// Joe needs to confirm pricing — using placeholders.
export const TIERS = {
  free: { name: "Free", priceId: null, features: ["basic_studio", "5_projects", "watermark"] },
  pro: {
    name: "Pro",
    priceId: Deno.env.get("STRIPE_PRO_PRICE_ID") ?? null,
    features: ["unlimited_projects", "no_watermark", "hd_export", "priority_render", "publish_to_socials", "analytics", "creator_badge", "tips_enabled"],
  },
} as const;

export type TierKey = keyof typeof TIERS;
