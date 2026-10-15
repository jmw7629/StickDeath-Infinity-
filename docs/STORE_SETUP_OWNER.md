# Store setup (owner runbook, updated 2026-10-15)

**Status: coming soon. Shopify has not been started.** Owner decision 2026-10-15: Shopify
charges from the moment a store is started, so `website/store.html` is a "Merch store — coming
soon" page instead. It shows the 22 merch mock-ups as labelled concepts (no prices, sizes, cart
or checkout) and asks visitors three things:

1. **"Should we open the SDI merch store?"** — thumbs up / thumbs down with live totals.
2. **A thumbs up / down on each concept design.**
3. **"Suggest a design"** — title (≤ 80 characters), description (≤ 500) and an optional public
   handle. Every idea goes to a moderation queue; only ideas you approve appear on the page, each
   with its own thumbs up / down.

Nothing on the page is counted in the browser and no number is shown until the vote service
answers. Until it is switched on (below) the page says "Voting opens soon" with every control
disabled and makes no request outside the site.

## 1. Switch the poll on

1. Install `backend/sql/merch-interest.sql` on the Supabase project (it is also the last candidate
   in `backend/sql/dist/sdi-backend-install.sql`; it needs the earlier admin candidates). It is
   not applied yet. It creates the tables, a random 32-byte salt, and the RPCs
   `sdi_merch_totals`, `sdi_merch_vote`, `sdi_merch_suggest` (callable with the publishable key,
   i.e. the `anon` role — the first such functions in this backend), `sdi_merch_moderate`
   (administrators) and `sdi_merch_retention` (service role).
2. In `website/store-config.js` change `enabled: false` to `enabled: true`. The backend URL and
   publishable key there are the same public values as `account-config.js`; nothing secret goes
   in that file.
3. Deploy the site and open `store.html`: the status line should read "Voting is open. Counts are
   live from the server." with every count at 0.

To pause voting or the idea box without a deploy, use the `settings` action below. To take the
page offline again, set `enabled: false`.

## 2. Read the results

Results are only for administrators with the **moderation** capability (owners have every
capability), signed in with MFA (aal2) on a live session.

From the command center session, or any authenticated REST client with your own access token:

```http
POST https://gwcqlbjdvxebkxizfxsx.supabase.co/rest/v1/rpc/sdi_merch_moderate
apikey: <publishable key>
Authorization: Bearer <your administrator access token>
Content-Type: application/json

{"action":"results"}
```

The reply lists every voted target (`store/open-store`, `concept/<slug>`, `idea/<id>` with its
title) with `up`, `down`, `member_up`, `member_down` and `changed_last_7_days`, plus
`distinct_voters`, `distinct_members`, idea counts by status and the current settings.

Or read it directly in the Supabase SQL editor (runs as `postgres`, so no RPC gate):

```sql
select target_kind, target_key,
       count(*) filter (where value = 1)              as up,
       count(*) filter (where value = -1)             as down,
       count(*) filter (where value = 1 and member)   as member_up,
       count(*) filter (where value = -1 and member)  as member_down
from sdi_private.merch_votes
group by target_kind, target_key
order by target_kind, count(*) filter (where value = 1) - count(*) filter (where value = -1) desc;
```

**How to weigh the numbers.** A visitor without an account votes with a random key kept in their
browser; the server stores only a salted hash of it. Anyone can clear their browser and vote
again, so anonymous totals are a sentiment signal, not a count of people. `member_*` counts come
from signed-in accounts (one vote per account per target) and are the firmer number. Limits:
30 actions per minute per voter, 600 anonymous votes per minute site-wide, 3 ideas per voter per
day, 30 ideas per hour site-wide and at most 300 pending ideas (all editable in
`sdi_private.merch_settings`). The database cannot see IP addresses; add gateway rate limiting
if the poll attracts abuse. No email, IP or device data is stored; the optional handle is the
only personal text and it is shown publicly only on approved ideas.

## 3. Moderate ideas

Same endpoint and requirements:

- `{"action":"queue"}` — pending ideas, oldest first, 50 per page (`"page":1` for more,
  `"status":"approved"` or `"rejected"` to review past decisions). Shows whether the submitter
  was a member or anonymous, never who.
- `{"action":"decide","idea":"<id>","decision":"approved","note":"","revision":<revision>}` —
  approve (or `"rejected"`). Needs a second-factor check within the last 15 minutes (step-up).
  Approving publishes the idea on the page; rejecting hides it and deletes its votes. Every
  decision is written to `sdi_private.admin_access_audit`.
- `{"action":"settings","revision":<settings revision>,"voting_open":false}` (and/or
  `"suggestions_open"`) — pause or resume; also step-up.

Ideas reject links, email addresses, angle brackets and control characters; still read each one
before approving (rights, likeness, offensive content). The service sweep
`sdi_merch_retention` removes day-old rate-limit rows and rejected ideas 30 days after the
decision.

## 4. If the votes say "open it" (later, not now)

Opening Shopify starts billing, so do it only when you decide the demand is there. The earlier
preparation is still in the repository: `docs/shopify-products.csv` (regenerate with
`node scripts/website/shopify_csv.mjs`) imports the 22 designs as priceless drafts. The website's
Shopify cart code was removed with the coming-soon change; wiring a live store back in is a new
website task (Storefront API with a public token, Shopify-hosted checkout, no prices typed into
the page, and the harness's third-party request rule reviewed for `store.html`).

## What stays off

No pre-orders, no prices, no "limited drop" timers, no invented vote counts and no customer or
payment data on the website.
