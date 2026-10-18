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
| Account page | `website/account.html`, `account.js`, `account-config.js` | Config-gated (updated 2026-10-18). Sign-in, profile, deletion request, account notices, policy acceptance (`sdi_consent_action`), support requests with receipts (`sdi_support_action`) and the plans from `docs/PLAN_DECISIONS_2026_10_15.md` (Free, Creator USD 4.99, Pro USD 9.99, credits, no trial). Checkout and the billing portal call the `stripe-checkout` function only when `billing` is configured; with `billing: null` the page states that web checkout is not available yet. |
| Harness | `scripts/website/a11y_perf.mjs` | Playwright 1.56.1, Chromium only, in-process Node static server; see §4. |

## 2. What is NOT in the repository (owner-gated, issue #269)

- (Updated 2026-10-18.) The canonical base is `https://stickdeathinfinity.com/` (`scripts/website/site_constants.mjs`). Netlify currently serves the domain with DNS on Netlify NS1; the owner chose GoDaddy hosting and the migration, mail-record preservation and rollback are in `docs/WEBSITE_HOSTING.md`. No hosting configuration lives in this repository.
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

## 4b. 2026-10-13 additions (agent E, wave 3)

| Area | Files | Status |
| --- | --- | --- |
| Command center shell (#277) | `website/admin.html`, `admin.js`, `admin-config.js` (`null`) | config-gated; GoTrue password + TOTP step-up or provider redirect, memory-only session, read panels over `sdi_*` RPCs, owner emergency stop as the only write; `noindex`; registered in `site_constants.mjs` and the harness |
| Help checker | `scripts/website/check_help.mjs --sync-guide-revision` | rewrites `guideRevision` from `SpatterAIViewModel.swift` without touching reviewed dates |
| Harness | `scripts/website/a11y_perf.mjs` | admin page added to the page × viewport matrix; two new checks: unconfigured shell keeps sign-in/console hidden and requests only its own files; no-JS state text |
| Hosting/rollback | `docs/WEBSITE_HOSTING.md` | procedure only; domain and host remain owner gates |

Measured on 2026-10-13 (Playwright 1.56.1 Chromium, Node 22): `build_site --check` OK (11 pages),
`check_help --check` OK (20 articles, guide revision `2026-10-12.1`), `a11y_perf` **333/333**
checks passed; perf at 390×844 Slow-4G CPU×4: 7 requests, 240,269 bytes, LCP 704 ms, CLS 0.

## 5. Deferred / not verified

- Real iPhone Safari, VoiceOver, WebKit and Firefox: not run (Chromium only in this environment). The gap file's WebKit note from the V59 deployment cannot be reproduced here.
- Hosting-level checks (HTTPS, caching headers, compression, redirects, 404 routing) depend on the absent hosting configuration.
- Policy content requires legal review; it was written from source behavior and the owner's scope documents, not reviewed by counsel.
- Help content is read from source at the current guide revision; no topic has device evidence, so none carries `verified-on-device`.
- The admin shell's signed-in paths (GoTrue password/TOTP/provider flows, RPC panels) are exercised only by code review and the unconfigured-state checks; they need a configured test project.

## 6. 2026-10-14 rebuild for stickdeathinfinity.com

Owner request: "branch off and rebuild the website, use screenshots from the artifacts, build everything
into it." Branch `claude/website-rebuild-kurekj` from `178cc9d` (main). Scope: `website/**`,
`scripts/website/**`, this file, `docs/WEBSITE_HOSTING.md`.

| Change | Detail |
| --- | --- |
| Canonical base | `scripts/website/site_constants.mjs` now `https://stickdeathinfinity.com/` (the owner named the address). Hosting, DNS and the first deployment are still owner actions. |
| New pages | `studio.html`, `community.html`, `play.html` (+ `play.js`), rebuilt `index.html` and `screens.html`; all indexable with canonical and `og:url`; `sitemap.xml`/`robots.txt` regenerated. |
| Captures | 27 new WebP frames extracted (ffmpeg) from the CI screen recordings of run 38516791084 (source `39f29cb`) plus one from `30e90cf`; four retained from `960241f`. 32 files, 646,998 bytes. Superseded `launch`, `library`, `new-project`, `lasso`, `export` captures from `960241f` were replaced by the newer ones. |
| Design | New `styles.css` (21.8 KB): tokens, CSS-only flipbook hero (six SVG poses stepped at 12 fps, onion ghost, reduced-motion shows a single pose), tool marquee, phone frames, numbers strip, tool catalogue, plan cards, play panel. Compact navigation breakpoint moved to 700 px (seven links + CTA). |
| Flipbook toy | `play.js`: canvas frames in memory, pen/eraser with pointer pressure, swatches + custom colour, onion skin toggle, per-frame undo (24 steps), add/duplicate/delete/step, playback 2–24 fps (refuses under reduced motion and says so), PNG spritesheet via `toBlob`, GIF89a via an in-page LZW encoder with a 216-colour palette and infinite loop; keyboard cursor drawing; no storage, no network. |
| Harness | `a11y_perf.mjs`: pages list extended; `.webp` MIME; budgets raised to ≤12 requests / ≤420,000 bytes because the home page carries lazy captures and the unmodified 166 KB font (fontTools is not installed here, so no subset was produced); new `play.html` journey (stroke changes the canvas, duplicate + add → frame 3 of 3, Play/Stop, GIF and PNG download events, no page errors). |
| Share card | `assets/og-card.html` tagline "Draw it. Time it. Make it move." → `og-card.png` re-rendered (82,696 bytes). |

### Measured (2026-10-14T09:36:52Z, Playwright 1.56.1 Chromium, Node v22.22.0)

```
check_help: OK — 20 articles, guide revision 2026-10-13.1, 202 distinct UI labels verified against 153 Swift and 56 Kotlin files, 39 source paths exist; help-data.js in sync
build_site: OK — base https://stickdeathinfinity.com/; written: none; unchanged: 15
a11y_perf: 483/483 checks passed (12 pages × 3 viewports × 12 audits, index behaviour, play journey, 404, reduced motion, no-JS, admin shell, file://)
perf (index.html, 390×844, Slow-4G, CPU×4): 7 requests, 265,367 bytes, LCP 1000 ms, CLS 0.0004, DOMContentLoaded 1,054 ms, load 1,962 ms
```

Transfer breakdown on the home page: font 166,356 · `help/help-data.js` 36,270 · `index.html` 27,031 ·
`styles.css` 22,232 · `site.js` 11,365 · `help.js` 1,651 · `assets/mark.svg` 462. Captures are
`loading="lazy"` below the fold and were not requested during the measurement.

Not verified: real iPhone Safari/VoiceOver, WebKit and Firefox (Chromium only here); the GIF writer was
exercised by the download event and by decoding its output size, not by an external GIF validator;
hosting-level checks depend on the absent deployment.

### 6b. Wave 2 (2026-10-14): store, login, clips, splash, reveal

Added `store.html` (+ `store.js`, `store-config.js`, eight rendered merch mock-ups via `scripts/website/render_merch.mjs`), a real sign-in on `account.html` (+ `account.js`, configured `account-config.js` with the public backend origin and publishable key), seven H.264 clips cut from the CI recordings (`website/clips/`, 1.4 MB), a decorative splash on the home page, scroll reveal on every long page, a hero speed slider and frame scrubbing, export tabs on the Studio tour, and `scripts/owner/mac_stickdeath_cleanup.sh` (owner-run, archive-not-delete).

Harness additions: `store.html` in the page matrix, `.mp4` served, pages scrolled once before auditing (reveal sections become visible), account no-JS text, account configured-state checks (form shown, profile hidden, only own files requested, local validation before any request), store unconfigured checks (eight products, no prices, cart hidden, only own files), splash checks (aria-hidden, no focusable controls, removed within 3 s), slider retiming check, and the flipbook journey now scrolls the canvas into view and compares pixel sums (the CI run on 8c093e1 failed that check because the canvas was off-screen at 390×844).

Measured 2026-10-14 (Playwright 1.56.1 Chromium, Node v22.22.0): `check_help --check` OK (20 articles, guide revision 2026-10-13.1); `build_site --check` OK (16 unchanged); `render_merch --check` OK (8 products); `a11y_perf` **527/527**; perf on the home page at 390×844 Slow-4G CPU×4: 10 requests, 315,779 bytes, LCP 1,316 ms, CLS 0.0017, load 2,259 ms (budgets ≤12 / ≤420,000 / ≤2,500 ms / ≤0.05).

Owner gates: Shopify store values for `store-config.js`; Apple/Google/GitHub/Microsoft provider enablement for `account-config.js`; the backend bundle paste for profile/lifecycle services; hosting and DNS for the domain. Not verified here: a configured Shopify store end to end (no store exists yet), real provider redirects, Safari/VoiceOver.

Live backend probe (2026-10-14, from the review container with the publishable key only): `GET /auth/v1/settings` → 200, external providers enabled: email only, sign-up enabled, email confirmation required; `POST /auth/v1/token?grant_type=password` with an unknown account → 400. This matches what `account.js` expects (unknown or unconfirmed accounts show the "not recognised, or not confirmed" message; provider buttons stay hidden until the owner enables providers and lists them in `account-config.js`).

### 6c. StickDeath OS (2026-10-14, owner: "inspired by poolsuite.net")

`os.html` + `os.css` + `os.js`: a retro desktop with a boot screen, menu bar, desktop icons, draggable/zoomable windows (Flipbook and Store embedded via `?embed=1`; Jukebox; Screens; Clips; About), a status bar, a ticking frame counter and clock. The Jukebox plays eight sounds copied unmodified from `StickDeathInfinity/Resources/StudioSounds` (all CC0-1.0, 1.6 MB, credits in `website/sounds/credits.json` and shown per sound) through a Web Audio analyser drawn on a canvas. `assets/os/` holds a Floyd–Steinberg 1-bit dither of the poster artwork (wallpaper), an 8×8 checker pattern and a dithered mark, all generated with Pillow from repository assets. Keyboard: Enter or Space skips the boot, icons and menus are buttons, title bars take arrow keys, Escape closes the front window; focus returns to the opener. Reduced motion: no boot animation, no frame ticking, no scope animation. The home page's first call to action and the navigation now lead to the OS; the long-form pages remain for search and reading. Registered in `site_constants.mjs` (indexable) and in the harness page matrix (`.m4a`/`.wav` served).

### 6d. The desktop becomes the home page (2026-10-14, owner: "works like a PC screen")

`index.html` is now the StickDeath desktop; the long-form page moved to `about.html` (canonical and sitemap updated, every `index.html#…` link repointed). Window manager (`os.js`): each window has close, minimize and maximize boxes in the title bar; minimize sends it to a taskbar button that restores it; maximize fills the desktop and the same box restores the remembered normal geometry; drag by the title bar, resize by the corner grip, double-click the title to zoom; Escape closes the front window and focus returns to the opener; new windows cascade and clamp to the desktop; on phones every window fills the screen. Windows: About (text), Studio tour, Flipbook, Community, Store, Account and Help (the long-form pages embedded with `?embed=1`, which hides their chrome and disables scroll-reveal), Screens, Clips and Jukebox (native). The boot screen paints the dithered wallpaper behind its panel so the largest contentful paint happens early (LCP 1,028 ms under the Slow-4G profile, down from 3,184 ms when the About window was the first large paint).

Harness: the index behaviours (skip link, compact menu, help search, fragments, support form, splash, slider, reduced motion, no-JS, file://) now run against `about.html`; a desktop journey checks menu-opens-window, maximize/restore geometry, minimize-to-taskbar/restore, Escape, close and the status count. Measured 2026-10-14: `a11y_perf` **608/608**; home page (desktop) at 390×844 Slow-4G CPU×4: 11 requests, 303,073 bytes, LCP 1,028 ms, CLS 0.0025.

### 6e. Freeform windows, half size and the flame dock (2026-10-14, owner direction)

Windows are freeform on every screen size: drag by the title bar with mouse, pen or finger (pointer events, `touch-action: none` on the title bar), resize by the corner grip, and the position is remembered. The three title-bar boxes are now close (×), half size (the window becomes half the desktop, centred; press again to return) and maximize (full pane; press again to return). A flame button on the right of every title bar "saves the window to the desktop": it leaves the screen and sits in the dock at the bottom, where one tap brings it back exactly where it was. On phones new windows open at 92 % × 66 % of the screen instead of full screen so they can be moved. Harness journey updated (drag by 120 × 60 px, half size, maximize/restore to the dragged place, flame to dock and back, Escape, close; a phone context with touch verifies freeform drag). Measured 2026-10-14: `a11y_perf` **611/611**; desktop home at 390×844 Slow-4G CPU×4: 11 requests, 306,848 bytes, LCP 992 ms, CLS 0.0042.
