#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# StickDeath Infinity — Register Stripe Webhook via API
# ══════════════════════════════════════════════════════════════════
# Usage:
#   chmod +x scripts/setup-stripe-webhook.sh
#   STRIPE_SECRET_KEY=sk_test_xxx ./scripts/setup-stripe-webhook.sh
# ══════════════════════════════════════════════════════════════════

set -e

STRIPE_KEY="${STRIPE_SECRET_KEY:?Set STRIPE_SECRET_KEY env var}"
WEBHOOK_URL="https://iohubnamsqnzyburydxr.supabase.co/functions/v1/stripe-webhook"

echo "🔗 Creating Stripe webhook endpoint..."
echo "   URL: $WEBHOOK_URL"
echo ""

RESPONSE=$(curl -s -X POST "https://api.stripe.com/v1/webhook_endpoints" \
  -u "$STRIPE_KEY:" \
  -d "url=$WEBHOOK_URL" \
  -d "enabled_events[]=checkout.session.completed" \
  -d "enabled_events[]=customer.subscription.created" \
  -d "enabled_events[]=customer.subscription.updated" \
  -d "enabled_events[]=customer.subscription.deleted" \
  -d "enabled_events[]=invoice.paid" \
  -d "enabled_events[]=invoice.payment_failed" \
  -d "api_version=2024-12-18.acacia")

# Extract the webhook secret
WEBHOOK_SECRET=$(echo "$RESPONSE" | grep -o '"secret":"whsec_[^"]*"' | cut -d'"' -f4)
WEBHOOK_ID=$(echo "$RESPONSE" | grep -o '"id":"we_[^"]*"' | cut -d'"' -f4)

if [ -n "$WEBHOOK_SECRET" ]; then
    echo "✅ Webhook created!"
    echo "   ID: $WEBHOOK_ID"
    echo "   Secret: $WEBHOOK_SECRET"
    echo ""
    echo "📌 Now set the secret in Supabase:"
    echo "   supabase secrets set STRIPE_WEBHOOK_SECRET=$WEBHOOK_SECRET --project-ref iohubnamsqnzyburydxr"
else
    echo "❌ Error creating webhook:"
    echo "$RESPONSE" | head -20
fi
