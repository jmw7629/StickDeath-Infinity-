# StickDeath ∞ — Secrets Configuration

API keys are loaded from your Xcode scheme environment or Info.plist.

## Setup

Add these keys to your Xcode scheme's environment variables (Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables):

| Key | Description |
|-----|-------------|
| `STRIPE_PUBLISHABLE_KEY` | Stripe publishable key (pk_test_...) |
| `STRIPE_SECRET_KEY` | Stripe secret key (sk_test_...) |
| `OPENAI_API_KEY` | OpenAI API key for Spatter AI |

Or add them to Info.plist:

```xml
<key>STRIPE_PUBLISHABLE_KEY</key>
<string>$(STRIPE_PUBLISHABLE_KEY)</string>
<key>STRIPE_SECRET_KEY</key>
<string>$(STRIPE_SECRET_KEY)</string>
<key>OPENAI_API_KEY</key>
<string>$(OPENAI_API_KEY)</string>
```

## Other Keys (in AppConfig.swift)

- Supabase URL & keys — hardcoded (project-specific, safe in private repos)
- LiveKit URL & key — hardcoded
- TikTok/YouTube client IDs — hardcoded (public client IDs)
