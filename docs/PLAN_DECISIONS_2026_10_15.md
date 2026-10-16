# Plan decisions — 2026-10-15

The owner's decisions on 2026-10-15 replace the Free and Creator rules recorded on 2026-10-14
(`docs/SPATTER_BILLING_DECISIONS_2026_10_14.md`). Prices are unchanged: Creator USD 4.99/month,
Pro USD 9.99/month. There is no free trial (owner decision, evening of 2026-10-15).

## Free

Modelled on FlipaClip's free tier, without ads (no ad network is added).

| Area | Free |
| --- | --- |
| Spatter | The floating skull and its suggested prompts are visible. Every send, suggested or typed, gets one fixed answer (`BillingCopy.spatterUpgradeNote`) on the device. Nothing is sent to a provider or the server, and no project is read or edited. The server also refuses any Free request with `upgrade_required` before counting anything. |
| Layers | 3 per frame. Existing projects with more layers still open and edit. |
| Onion skin | 1 frame back, 0 forward. |
| Canvas | Presets only; no custom width and height. |
| Export | Up to 720p (1280 px long edge), with the SDI watermark burned into MP4 and GIF. |
| Locked | Audio import, the sound library, Blur, Smudge, Sharpen, Dodge/Burn, extra brushes, background cut, PNG image sequences, submissions to the official SDI channels. |

## Creator (USD 4.99/month)

- No Studio limits and no watermark.
- Own AI key: prompts go from the device to the member's provider and are not counted.
- Server-funded Spatter prompts per billing period, capped at the plan's break-even:
  `limit = floor(creator_period_budget_microusd / prompt_cost_estimate_microusd)`.
  Defaults: budget USD 3.49 (USD 4.99 minus a 30% store commission, rounded down) and
  USD 0.02 per prompt, giving 174 prompts. Both values are owner-editable in the admin
  Spatter limits; lower the estimate only from measured provider costs.
- Submit finished videos to the official SDI YouTube, TikTok and social channels. Each
  submission still needs the creator's channel-publication consent, rights clearance,
  moderation and the owner's approval of the exact render. The channel rendition carries
  the small watermarked SDI mark at the bottom right. The editable original stays on the
  device.

## Spatter credits

Owner decision (later on 2026-10-15): "You can purchase more credits to keep going and in
free you can pay as you go if you want."

- Credit packs are consumable store products (App Store, Google Play, Stripe on the web).
  One credit is one server-funded Spatter prompt. Pack sizes are server configuration and
  prices are store configuration; the apps show only the store's price.
- Order of spending: the plan's allowance first (Creator), then credits. Pro never spends
  credits. Free with credits uses Spatter pay-as-you-go, typed questions included; Free
  without credits gets the upgrade note.
- Credits are granted only after the server verifies the store's signed transaction, exactly
  once per transaction. The iOS app finishes a credit transaction only after the grant, so
  an unconfirmed purchase is redelivered rather than lost. Refunds claw credits back.
- Break-even: price a pack at no less than its credits times the per-prompt cost estimate,
  divided by 0.7 for the store commission (for example 100 credits at USD 0.02 need at
  least USD 2.86).

## Pro (USD 9.99/month)

Everything in Creator, with unlimited Spatter prompts (the per-user daily safety cap,
per-minute rate, global daily ceiling and emergency stop still apply).

## Enforcement

- `StudioPlanLimits` in `StickDeathInfinity/Services/Stripe/BillingPlanCatalog.swift` is the
  single definition. `StripeService` sets `StudioPlanLimits.current` from the tier.
- Limits apply only once the App Store sells the real plans: the catalog must name real
  product ids (not the placeholders) and the store must have loaded them. Until then every
  account keeps the full Studio, so nobody is locked out of a feature they cannot buy. This
  also keeps the simulator UI suite, which runs as a guest with placeholder ids, unchanged.
- The server is the authority for Spatter: the device never counts its own allowance.

## Not done

- Ads: not added. They would need a new ad network and its privacy and tracking disclosures.
- Live verification: the limits are not verified in a store build yet. The App Store
  subscriptions and the Info.plist product ids are owner configuration. No trial offers.

## Owner answers, evening of 2026-10-15

- **No free trial** on any plan. Spatter stays visible on Free and its suggested prompts are
  the teaser; any tap on a suggested prompt or any message send opens the plans screen
  (`SpatterAIViewModel.upgradeRequested`), where Free can subscribe or buy credits.
- **No partial refunds.** Only a full refund of a credit pack claws its credits back; the
  owner can still correct a balance with the audited `grant` action.
- **Stripe:** the old "StickDeath Pro" USD 4.99 product and its price are archived. The live
  Creator (`sdi.creator.monthly.web`, USD 4.99) and Pro (`sdi.pro.monthly.web`, USD 9.99)
  monthly prices carry lookup keys.
- **Merch:** Shopify is not started because it bills from the start. The store page is a
  "coming soon" page with concept designs, a poll on whether to open the store, per-design
  thumbs up/down and moderated design suggestions (`backend/sql/merch-interest.sql`).
- **Name and rights:** StickDeath Infinity holds the rights to its name and brand. The
  historical StickDeath had no legal entity or ownership. Historical StickDeath artwork,
  sounds and SWFs remain reference material only and are still not committed (AGENTS.md).
- **Spatter spending:** the owner approved opening the global daily cap ("go"); the value
  set at install is 100 prompts per UTC day (about USD 2 at the USD 0.02 estimate) and can be
  changed in the command center.
