# Social wall and creator profiles — contract (#217, #219, #220, #224)

This is a source contract, not acceptance evidence. Native compilation, simulator/device
behaviour and the live Supabase project are **deferred** until verified on macOS CI and
against the owner's project.

## Feed listing: `sdi_feed_page(category, page_cursor, as_of)` (feed-integrity.sql)

- Categories: `recent`, `following`, `featured`, `trending`. Unknown categories are refused.
- Order: `score desc, published_at desc, id desc`. `score` is 0 except in Trending, where it
  counts likes recorded in the seven days ending at the snapshot instant.
- Page 0 sends neither `page_cursor` nor `as_of` and receives `as_of` (snapshot) and
  `next_cursor`. Every later page sends both. The server returns rows strictly after the
  cursor key, so new posts, new likes and removals cannot duplicate or skip a row the member
  has not reached. A post published after the snapshot appears only after refresh. An unlike
  or moderation removal can lower or drop a row; the client de-duplicates by identity.
- Bounds: 25 rows per page, 40 pages per timeline (client), snapshots older than one day are
  refused, cursors are validated (`score|UTC timestamp with microseconds|uuid`), 60 calls per
  minute per account (shared with `sdi_feed_action`).
- Eligibility is identical to `sdi_feed_action`: visible post, approved media owned by the
  creator with a render digest and unexpired, creator not restricted, no block in either
  direction, Featured only for admin-featured posts, Following only for followed creators.
- `can_download` = creator permission (`allow_export`) **and** a current paid entitlement of
  the viewer (`sdi_private.entitlements`, billing.sql). The Free plan never downloads (#219
  owner note). `download_requires_plan` tells the client which message to show.
- `sdi_feed_action('list', …)` remains for older clients; the iOS client no longer uses it.

## Playback (#219)

`CommunityVideoPlayer` (HomeFeedView.swift) plays one approved HTTPS rendition after an
explicit tap; nothing autoplays. States come from the player: loading, slow start (15 s),
buffering, ended, failed with Retry/Close. Expensive networks (cellular, hotspot) are capped
at 2.5 Mbit/s and 720p, and the forward buffer is 12 s (`FeedPlaybackPolicy`). No account token
is attached to media requests. Share sends the HTTPS link; file export is offered only when
`FeedExportPolicy.state` is `.allowed` and is bounded to 200 MB.

## Creator totals: `sdi_creator_stats(subject)` (feed-integrity.sql)

Counts published (eligible) videos, likes on them and followers from the same rows the feed
shows; `following` only for the account itself. Blocked or restricted creators are
"Profile unavailable." The profile shows a dash when totals are not loaded, never an estimate.

## Profile editing and avatar (users-profiles.sql)

- Usernames are unique regardless of case. A changed username must satisfy the same rules as
  `CreatorHandle` (3–30 ASCII letters/digits/underscore, leading letter or digit, not
  reserved). Sign-up names keep the original 1–80 check until the member edits them.
- Avatar bucket `avatars`: public read, 300 KB, `image/jpeg` only; members may read, write,
  replace and delete only `<their uid>/avatar.jpg`. The block applies only where the Supabase
  `storage` schema exists (the local SQL harness skips it).
- Remove avatar clears the profile reference first, then deletes the stored object; a failed
  delete is reported and the next upload replaces the file.

## Owner gates

- Apply the SQL candidates on the owner's project (install bundle must be regenerated after
  these changes: `python3 scripts/backend/build_install_bundle.py`).
- Confirm the `avatars` bucket and storage policies exist after applying users-profiles.sql.
- Paid downloads depend on configured billing products and signed provider events (#253).

## Evidence

- `backend/sql/tests/015_feed_cursor_stats.sql` (keyset paging, cursor validation, trending
  snapshot, blocks, download entitlement, creator totals, handle rules): local PostgreSQL
  harness `scripts/backend/run_sql_tests.sh`.
- `Tests/CommunityFeed/main.swift`: keyset client parameters, cursor handling, plan-gated
  export, creator totals, playback state — compile/run deferred to macOS CI.
