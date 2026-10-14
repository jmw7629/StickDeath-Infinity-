# Spatter — wave 4 (2026-10-14): #206, #207, #208, #209, #215

Scope: Spatter cloud-advice transport and metering, grounded local help, device
memory controls, editable brief output and export receipts. Training and
creative tuning are owner-managed; nothing here trains or tunes a model. No paid
AI call, provider configuration, deployment or live charge was made.

Status words: **in source** = implemented and covered by Linux-runnable tests
where they exist; **deferred** = not run here (Swift has no compiler on this
host; native simulator/device runs are tracked by #124 and #265);
**owner-gated** = needs something only the owner can supply.

## #209 — provider-neutral transport, per-user and global budgets (P0)

In source, tested on Linux:

* `backend/sql/spatter-draft-jobs.sql` (end of file): server-side metering.
  Free 5 prompts (one-time until the owner says otherwise), creator (USD 4.99)
  15 per billing period keyed to `paid_through`, pro (USD 9.99) no plan
  allowance; per-minute rate, per-user daily safety cap, a global daily ceiling
  that **defaults to 0 (closed)**, the agent emergency stop, suspended/banned
  accounts. Exactly-once settlement (commit with usage units / release refund),
  stale reservations kept counted, users read their own allowance
  (`sdi_spatter_my_usage`), the owner changes limits with revision, reason and
  audit (`sdi_spatter_usage_admin`). The service wrapper is listed in
  `backend/sql/tests/080_rls_review.sql`.
* `backend/spatter/metering.py` (`SqlMeter`, strict decode; `InMemoryMeter`
  reference), `providers.py` (`ProviderRouter`: validated provider/model switch,
  per-attempt timeout, bounded retries for transient failures, adapter error text
  never propagated), `jwt_hs256.py` (stdlib HS256 verifier), `handler.py`
  (optional `meter`, `allowance` in replies, `code` in errors).
* Evidence: `python3 -I -m pytest backend/spatter -q` → 39 passed;
  `scripts/backend/run_sql_tests.sh` → 13 passed, 0 failed (PostgreSQL 16.15,
  stubs; not a deployment). A sentinel failure was injected once to confirm the
  new SQL block executes, then removed.

Owner-gated: choose/configure a provider adapter and model, deploy the
function, apply the SQL, set `global_daily_cap` > 0. The open owner questions
were answered on 2026-10-14 and are implemented in source (Free = 5 suggested
prompts per month, own AI key on Creator and Pro, trial on both paid plans):
see `docs/SPATTER_BILLING_DECISIONS_2026_10_14.md`, which supersedes the
one-time free allowance and the "BYO keys not implemented" note above.

### Client patch needed (outside D2 file ownership)

`StickDeathInfinity/App/SpatterBackendClient.swift`:

1. `decodeReply`: also decode `allowance {plan, period, remaining?, resetsAt?}`.
   Represent it next to `SpatterBudget` (or extend it with `plan`/`period`) and
   make `displayText` period-aware: `one_time` → "Free Spatter prompts left: N",
   `billing_period` → "Prompts left this billing period: N (renews <date>)",
   `pro` (remaining null) → "Unlimited plan (safety limits apply)". Until this
   lands, metered replies show no count; nothing is mislabelled as "today".
2. Non-2xx bodies: `BoundedSpatterRequest` cancels at the response header, so the
   JSON `code` is never read. Allow a bounded (≤ 4 KiB) JSON error body, decode
   `code`, `retryAfterSeconds`, `upgrade`, and map:
   `plan_allowance_exhausted` → "You've used this plan's Spatter prompts" + the
   upgrade target; `rate_limited` → "Too many requests; try again in N s";
   `daily_safety_limit` → "Daily safety limit reached; resets at midnight UTC";
   `global_limit`/`emergency_stop` → "Spatter cloud is paused right now";
   `account_restricted` → "This account can't use Spatter cloud".
   Extend `Tests/SpatterClient/main.swift` with one case per code.

## #207 — grounded help with citations and honest "I don't know"

In source: `SpatterHelpSource` and `SpatterGroundedHelp` in
`StickDeathInfinity/Services/Spatter/SpatterKnowledgeBase.swift` — ranking over
active (non-retired) modules only with a minimum grounding score, a "Sources"
footer naming the guide revision and module ids, and an explicit "I don't know"
answer that claims no ticket, refund, account access or action. New
`Tests/SpatterConversation` group asserts: retired modules are never cited
(including under a hostile query), the creative module is cited as reference not
capability, nonsense/weak/oversized queries cite nothing, and the unknown answer
admits it. Swift compile/run **deferred to macOS/Swift CI**.

### Wiring patch needed (outside D2 file ownership)

`StickDeathInfinity/ViewModels/SpatterAIViewModel.swift`, `localGuidance`:

```diff
-        if let guide = … { return "💀 Current Studio guide (\(currentGuideVersion))\n\n" + project + guide + "\n\nGuidance only; no project changes were made." }
+        if let guide = … { return "💀 Current Studio guide (\(currentGuideVersion))\n\n" + project + guide + "\n\n"
+            + SpatterGroundedHelp.sourcesFooter([SpatterHelpSource(kind: .currentGuide, id: "studio-guide", title: "Current Studio guide")], guideVersion: currentGuideVersion)
+            + "\n\nGuidance only; no project changes were made." }
@@ creative branch
-            return "💀 Creative reference · \(creative.title)\n\n\(project)\(details)\n\nThese are creative suggestions to apply yourself, not evidence of an automatic tool or a completed edit. Guidance only; no project changes were made."
+            return "💀 Creative reference · \(creative.title)\n\n\(project)\(details)\n\nThese are creative suggestions to apply yourself, not evidence of an automatic tool or a completed edit.\n\n"
+                + SpatterGroundedHelp.sourcesFooter([SpatterHelpSource(kind: .creativeReference, id: creative.id, title: creative.title)], guideVersion: currentGuideVersion)
+                + "\nGuidance only; no project changes were made."
@@ no match
-            return "💀 \(project)I couldn't find a matching entry in the 120 bundled guidance modules. Try a concrete topic such as layers, timing, onion skin or export. No animation was generated."
+            return SpatterGroundedHelp.unknownAnswer(projectLine: project, guideVersion: currentGuideVersion)
@@ historical branch: replace the trailing "\n\nGuidance revision \(currentGuideVersion). Guidance only; no project changes were made." with
+            "\n\n" + SpatterGroundedHelp.sourcesFooter([SpatterHelpSource(kind: .historicalReference, id: module.id, title: String(module.title.prefix(120)))], guideVersion: currentGuideVersion)
+            + "\nGuidance only; no project changes were made."
```

Existing conversation assertions ("do not have verified current instructions",
"not proof that a feature is available", "no project changes were made") are
preserved by this patch. After applying it, add an assertion that every local
reply contains "Sources".

## #208 — personality and device-local memory

Already in source and unchanged here: `SpatterPersonalMemoryStore` (opt-in,
off by default, per-account/guest scope, fixed schema v1 ≤ 2 KB with no extra
fields, export/import/reset, excluded from backup, no cloud sync) and the
Studio memory sheet; retired messaging/call modules are kept for provenance but
filtered from prompts, lookups and ranking (`Tests/SpatterPersonalMemory`,
`Tests/SpatterConversation`). Native verification **deferred**.

## #206 — varied briefs to editable output

Already in source and unchanged here: `SpatterMultiClauseBrief` (1–3 actors,
≤ 6 clauses, 11 actions, per-clause durations, seed) → one `appendFrames`
command, Preview plan before Apply, storyboard receipt, one-step Undo/Revert
(`Tests/SpatterPlanner`, `Tests/SpatterEval`). Native playback/save/reopen/export
journeys for new briefs **deferred**. Open-ended natural-language video
generation is not claimed.

## #215 — export invocation with factual artifacts

Already in source and unchanged here: from a saved Spatter edit, "Export this
edit as MP4" and "Export this edit as GIF" hand the exact saved revision to the
real exporters; `SpatterExportReceipt` reads the actual output file and reports
byte count, duration, frame count and SHA-256, refusing missing, mismatched or
unreadable output (`Tests/SpatterEval` exportReceipt cases,
`Tests/SpatterStudioEditSession` SHA-256 vectors). Native decode/reopen of the
GIF path **deferred**; the separate Files-save acceptance remains under #185.
