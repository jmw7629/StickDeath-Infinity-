#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# StickDeath Infinity — Deploy All Edge Functions + Set Secrets
# ══════════════════════════════════════════════════════════════════
# Usage:
#   cd stickdeath-infinity
#   chmod +x scripts/deploy-edge-functions.sh
#   ./scripts/deploy-edge-functions.sh
#
# Prerequisites:
#   - supabase CLI installed (brew install supabase/tap/supabase)
#   - supabase login (creates access token)
#   - supabase link --project-ref iohubnamsqnzyburydxr
# ══════════════════════════════════════════════════════════════════

set -e

PROJECT_REF="iohubnamsqnzyburydxr"
FUNCTIONS=("stripe-webhook" "create-checkout" "publish-video" "render-video" "ai-assist" "admin-actions" "social-connect" "create-tip" "manage-subscription" "grant-referral-pro" "send-push-notification")

echo "🚀 Deploying StickDeath Infinity Edge Functions..."
echo "   Project: $PROJECT_REF"
echo ""

# Deploy each function
for fn in "${FUNCTIONS[@]}"; do
    echo "📦 Deploying $fn..."
    supabase functions deploy "$fn" --project-ref "$PROJECT_REF" --no-verify-jwt 2>/dev/null || \
    supabase functions deploy "$fn" --project-ref "$PROJECT_REF"
    echo "   ✅ $fn deployed"
done

echo ""
echo "════════════════════════════════════════"
echo "✅ All ${#FUNCTIONS[@]} functions deployed!"
echo ""
echo "📌 Next: Set your secrets (if not already done):"
echo "   supabase secrets set STRIPE_SECRET_KEY=sk_test_YOUR_KEY --project-ref $PROJECT_REF"
echo "   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_YOUR_SECRET --project-ref $PROJECT_REF"
echo ""
echo "📌 Then register the webhook in Stripe Dashboard:"
echo "   URL: https://$PROJECT_REF.supabase.co/functions/v1/stripe-webhook"
echo "   Events: checkout.session.completed, customer.subscription.created,"
echo "           customer.subscription.updated, customer.subscription.deleted,"
echo "           invoice.paid, invoice.payment_failed"
echo "════════════════════════════════════════"
