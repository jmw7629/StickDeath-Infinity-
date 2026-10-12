# Website inventory and verification record

Batch date: 2026-10-12. Branch base: `e48e789` (`claude/studio-sdi-overhaul-kurekj`). Scope: `website/**`, `scripts/website/**`, this file. Issues touched: #269, #270, #271, #272, #273, #275 (website parts only). Nothing here establishes native iOS or Android acceptance.

## 1. What is in the repository

| Area | Files | Status |
| --- | --- | --- |
| Product/help page | `website/index.html`, `site.js`, `help.js`, `styles.css` | Static, buildless, zero third-party requests. `#pricing` unchanged (no plans, no prices). |
| Help source of truth | `website/help/articles.json` (20 topics) → generated `website/help/help-data.js` | Each topic carries `platform`, `steps`, `limits`, `sources` (repo paths), `guideRevision` (`2026-10-12.1`), per-topic `reviewed` ISO date and `status` (`source-implemented` ×18, `unavailable` ×2, `verified-on-device` ×0). |
| Help checker | `scripts/website/check_help.mjs` | Enforces sources + reviewed dates, guide revision regex-extracted from `StickDeathInfinity/ViewModels/SpatterAIViewModel.swift`, every curly-quoted UI label verbatim in Swift/Kotlin sources, every source path present; regenerates `help-data.js` (`--check` fails on drift). |
| Discovery | `website/robots.txt`, `website/sitemap.xml`, canonical/OG/Twitter meta, JSON-LD (WebSite + Organization only), `website/404.html`, `website/assets/og-card.html` → `og-card.png` (1200×630, 67,955 bytes) | Generated/verified by `scripts/website/build_site.mjs` from `scripts/website/site_constants.mjs`. Non-indexable pages (404, account, policy drafts, generated attribution) carry `noindex`; robots.txt does not Disallow them so the directive is crawlable. |
| Policy drafts | `website/policies/terms-v1.html`, `privacy-v1.html`, `publishing-v1.html` | Version 1.0-draft, no effective date, visible "Draft — requires legal review before publication" banner, owner-gated items named explicitly. |
| Attribution | `website/policies/attribution.html` | Generated from `StickDeathInfinity/Resources/Licenses/ArtCraft-NOTICE.txt`, `SpecialElite-NOTICE.txt`, `SpecialElite-Apache-2.0.txt`, `StudioSounds/CREDITS.txt` + `catalogue.json` (2,127 CC0 sounds, 21 creator/source rows), `StudioImages/catalogue.json` (207 pictures, 3 Kenney CC0 sources), `additional-packs.json` + `remote-pack.json` (6 packs, 1,818 pictures), and `website/assets/SpecialElite-NOTICE.txt`; inputs listed with SHA-256. No entry is hand-typed. |
| Account shell | `website/account.html`, `account.js`, `account-config.js` | Config-gated. `SDI_ACCOUNT_CONFIG = null` → "Accounts and billing are not connected to this website." A valid https `portalURL` shows only a link. No prices anywhere. |
| Harness | `scripts/website/a11y_perf.mjs` | Playwright 1.56.1, Chromium only, in-process Node static server; see §4. |

## 2. What is NOT in the repository (owner-gated, issue #269)

- No hosting project, domain, DNS, TLS, deployment pipeline, preview environment or rollback procedure. The canonical base is the reserved placeholder `https://stickdeath-infinity.invalid/` in `scripts/website/site_constants.mjs`; `.invalid` can never resolve, so it cannot be mistaken for a live URL. `stickdeathinfinity.com` is unverified and is not referenced.
- The "V59" review deployment cited in issue #270 (source `e0ac4fe5a2b42dcb72e7ed5651695625b14bbb24`) is not reachable from this repository: `git cat-file -t e0ac4fe` finds no such object on this branch, and no hosting configuration for `stickdeath-infinity-review.joewillisny.chatgpt.site` exists here. The public page no longer links to that owner-only host.
- No screenshots or recordings: the page states that only approved, source-labelled captures will be added. The hero motion study remains an original illustration labelled "Not an app screenshot".
- No account, billing, support-intake, analytics, email or admin backend is wired from the website. Local Postgres candidates listed in the gap analysis (support-request schema, admin shell) were not built in this batch.
- Policy effective dates, legal contact route, age rules, retention periods and published-copy removal timelines are marked owner-gated inside the drafts.
- The `SDI_PUBLISHING_CONSENT_VERSION` / `SDI_PUBLISHING_TERMS_URL` app configuration must point at the approved publishing document before uploads can be enabled; the drafts are not yet that document.

## 3. Commands

Run from the repository root with Node 22 (no npm install needed):

```sh
# Validate help/articles.json against the Swift/Kotlin sources and regenerate help/help-data.js
node scripts/website/check_help.mjs
node scripts/website/check_help.mjs --check        # CI mode: fail if help-data.js is stale

# Rewrite self-URLs from CANONICAL_BASE, write robots.txt + sitemap.xml, generate policies/attribution.html
node scripts/website/build_site.mjs
node scripts/website/build_site.mjs --check        # fail if any generated file is out of date
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/build_site.mjs --og   # also render assets/og-card.png

# Accessibility, behaviour, no-JS, reduced-motion, file:// and throttled performance checks
PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/a11y_perf.mjs --json /tmp/a11y.json
```

`a11y_perf.mjs` exits 1 on any failed check and prints measured values only.

## 4. Measured results (this batch, exact source at commit time)

### check_help.mjs

```
check_help: OK — 20 articles, guide revision 2026-10-12.1, 202 distinct UI labels verified against 146 Swift and 38 Kotlin files, 39 source paths exist; help-data.js in sync
```

### build_site.mjs

```
build_site: OK — base https://stickdeath-infinity.invalid/; written: none; unchanged: 10   (--check after generation)
```

### a11y_perf.mjs (run 2026-10-12T06:21:38Z, Playwright 1.56.1 Chromium, Node v22.22.0)

**294/294 checks passed.** Pages: `index.html`, `404.html`, `account.html`, `policies/terms-v1.html`, `privacy-v1.html`, `publishing-v1.html`, `attribution.html`. Viewports: 320×640, 390×844, 1440×900.

Per page × viewport (21 combinations × 12 checks): no console/page errors; zero non-same-origin requests; no horizontal overflow; all interactive targets ≥44×44 (inline links inside running text exempt per WCAG 2.5.8); exactly one `h1`; no skipped heading levels; `main`/`nav`/`header` present; every `img` has `alt`; every form control labelled; every link/button named; text contrast ≥4.5:1 (≥3:1 large) across every text element with a direct text node (index.html: 415 elements checked at 1440×900 with all topics expanded); visible focus outline (3px `#ffd26b`) on the first Tab stop.

index.html behaviour at each viewport: skip link is the first Tab stop, visible, targets `#main` and moves focus; compact menu toggles `aria-expanded`, Escape closes it and refocuses the button (desktop: button hidden, nav visible); help search "lasso" renders exactly the 3 topics whose text contains it (count computed from `articles.json`); category filter sets `aria-pressed` and narrows to the 7 Animate topics; all 20 `#help/<id>` fragments open and focus their topic; support form rejects an empty report with the "10–2,000" message, Review prepares a summary marked not submitted, Download fires a browser download event (`stickdeath-problem-summary.txt`), Copy writes the clipboard (verified by `readText`), Reset clears the draft.

Server/other: missing path returns HTTP 404 with the 404 page; `prefers-reduced-motion: reduce` → `scroll-behavior: auto`; with JavaScript disabled the `noscript` guidance and the account page's "not connected" text render; `file://` load renders all 20 topics with no errors.

Performance (index.html, 390×844, CDP Slow-4G emulation 150 ms RTT / 1.6 Mbps down / 750 kbps up, CPU ×4; budgets: ≤8 requests, ≤250,000 bytes, LCP ≤2.5 s, CLS ≤0.05):

| Metric | Measured | Budget |
| --- | --- | --- |
| Requests | 7 | ≤8 |
| Transfer (body + headers, uncompressed) | 240,259 bytes | ≤250,000 |
| LCP | 640 ms (runs 1–3: 592 / 616 / 676 ms) | ≤2,500 ms |
| CLS | 0 (run 1: 0.2601 before fixes) | ≤0.05 |
| DOMContentLoaded / load | 684 ms / 1,585 ms | — |

Transfer breakdown: `SpecialElite-Regular.ttf` 166,356 · `help/help-data.js` 36,030 · `index.html` 13,766 · `styles.css` 11,160 · `site.js` 10,834 · `help.js` 1,651 · `assets/mark.svg` 462. The font is 69% of the budget; a subset font would be the next saving but no font tooling is available in this environment, so it was not attempted.

### Failures found by the harness and fixed in this batch

1. Brand links 42px tall (header) and 19px (footer); nav links "Studio"/"Help" narrower than 44px at desktop → `min-height`/`min-width` rules.
2. Policy pages overflowed horizontally at 320/390px (SHA-256 digests, long URLs in `pre`/`td`/`code`) → `overflow-wrap:anywhere`; table/list links given 44px line boxes.
3. Native `required`/`minlength` validation suppressed the page's accessible status message → `novalidate` on the support form (attributes kept for semantics).
4. CLS 0.26: `site.js` hid the stacked compact nav after load, moving the hero ~130px. Compact nav state is now CSS-driven (`.menu` shown and nav hidden at ≤580px by default, `.open` toggled by JS, `<noscript>` style restores the nav) → CLS 0. A metric-matched local fallback face for Special Elite (size-adjust 87.5%, ascent 80.36%, descent 33.93%, from the TTF tables) was added as well; the font swap itself measured 0.003.
5. Playwright's `isVisible()` reports false for content inside `<noscript>`; the harness measures rendering in-page instead.

## 5. Deferred / not verified

- Real iPhone Safari, VoiceOver, WebKit and Firefox: not run (Chromium only in this environment). The gap file's WebKit note from the V59 deployment cannot be reproduced here.
- Hosting-level checks (HTTPS, caching headers, compression, redirects, 404 routing) depend on the absent hosting configuration.
- Policy content requires legal review; it was written from source behavior and the owner's scope documents, not reviewed by counsel.
- Help content is read from source at guide revision `2026-10-09.5`; no topic has device evidence, so none carries `verified-on-device`.
