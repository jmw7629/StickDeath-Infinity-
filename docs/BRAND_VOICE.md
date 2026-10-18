# Brand voice — StickDeath Infinity (draft for owner approval)

Status: draft written 2026-10-18 for #283. The owner supplies and approves the voice.
The version that marketing drafts are written from is the one stored and approved in
the command centre (`sdi_marketing_action('brand_voice')`, `brand_voice_versions` in
`backend/sql/marketing-workspace.sql`); this file is the starting text for that entry,
not an approval. Nothing here authorizes a post, email or upload.

## Who we are talking to

People who make short stick-figure animations, and people who like watching them. Many
are teenagers or young adults; some remember Flash-era stick animation and some have never
seen it. They care about making something, not about the tool.

## Tone

- **Dark-comic, never cruel.** Stick figures get flattened, launched and exploded; that is
  the joke. Real people, real groups and real tragedies are never the punchline.
- **Short and plain.** One idea per sentence. Verbs over adjectives. No hype stacks
  ("revolutionary", "game-changing", "insane"), no exclamation chains.
- **Maker to maker.** Talk about frames, timing, onion skin, sound hits and exports, the
  things a creator actually touches. Show a technique rather than praise one.
- **Confident, not boastful.** State what the app does. Never compare by naming a
  competitor, never claim "best", "first" or "only".
- **Honest about limits.** If a feature is not available yet, say so ("not available
  yet"), never "coming soon" with a date we do not have.

## Words

| Use | Avoid |
| --- | --- |
| StickDeath Infinity, SDI | StickDeath (the historical site), Stick Death, stickdeath |
| Studio, frames, layers, onion skin, export | content, assets (to members), "AI magic" |
| Spatter (the Studio assistant) | bot, AI friend, chat |
| War Room (a contest between two submitted videos; viewers pick a favourite) | battle royale, rank, leaderboard (unless the member turned records on) |
| Creator plan, Pro plan, credits | coins, gems, premium currency |

## Facts every message must get right

- Plans: Free, Creator USD 4.99/month, Pro USD 9.99/month; credits for extra Spatter
  prompts. No free trial (docs/PLAN_DECISIONS_2026_10_15.md). Show the store's price
  where a store sells it.
- Projects stay on the member's device. Nothing is uploaded because a project was saved,
  opened or exported.
- No messaging, chat or calls in the app. Rooms are invitation-only collaboration on a
  shared project.
- Every Spatter-generated video is approved by the owner, exact render, before it is
  released anywhere.

## Never

- Reference, imitate or tag a real person, creator, studio or brand, or use their name,
  likeness, voice or handle, without their written permission recorded in the rights
  record.
- Use historical StickDeath artwork, sounds, SWFs or characters (AGENTS.md: reference
  material only).
- Use a member's video, name or handle in marketing without their separate marketing
  permission for that exact render (#244).
- Invent numbers: members, views, downloads, wins, ratings or reviews.
- Target children, ask for personal data, or promise prizes or money.
- Use gore realism, weapons glorification, slurs, sexual content, or self-harm references.

## Email blasts

- Product and marketing email go only to members who turned that category on, never to a
  suppressed address (unsubscribe, bounce, complaint), and at most one opt-in email per
  member per seven days across all campaigns (`EmailQueue.enqueue_blast`,
  `backend/mail/queue.py`). Account and service notices are separate and carry no
  marketing.
- Subject: what is new, in under 60 characters. Body: what changed, how to use it, one
  link. Plain text, no tracking pixels. Every opt-in email carries the one-click
  unsubscribe footer the template adds.

## Social posts

- One clip, one sentence, the creator's credit when their marketing permission allows it,
  and the small watercolor SDI mark on the approved rendition.
- Hashtags: at most three, about animation, never trending tragedies or unrelated tags.
