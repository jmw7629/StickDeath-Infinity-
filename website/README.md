# StickDeath Infinity product website source

Rebuilt on 2026-10-14 for `https://stickdeathinfinity.com/` (the address the owner named; hosting and
DNS remain owner actions, see `docs/WEBSITE_HOSTING.md`). Static and buildless: open `index.html`
locally or serve the folder. Zero third-party requests, no analytics, no trackers, no storage.

## Pages (2026-10-14)

| Page | Purpose | Indexable |
| --- | --- | --- |
| `index.html` | **The desktop** (see StickDeath OS below): boot, menu bar, icons, windows with close / minimize / maximize / restore / drag / resize, taskbar for minimized windows. Every other page opens inside a window through `?embed=1`. |
| `about.html` | The long-form page: hero with an original six-frame flipbook illustration, tool marquee, Studio overview with real captures, numbers read from the source, Spatter, Community, platform status, pricing status, help desk, support summary, data & trust | yes |
| `studio.html` | Studio tour: project creation, the 30-tool catalogue, brushes, selections, layers and blend modes, frames and timing, sound, pictures and rotoscope, Spatter, export | yes |
| `community.html` | Rooms, War Room, feed and challenges, publishing permissions, accounts, each with a built / needs-owner-backend / deliberately-not-built legend | yes |
| `screens.html` | 30 real simulator captures grouped by area, each labelled with its source revision | yes |
| `play.html` + `play.js` | Browser flipbook toy: up to 12 frames, pen/eraser, swatches, onion skin, undo, playback 2–24 fps, GIF (own LZW writer) and PNG spritesheet downloads; keyboard drawing; nothing stored or uploaded | yes |
| `404.html`, `account.html`, `admin.html`, `policies/*` | unchanged roles; new navigation chrome | no |

Captures in `screens/` are single frames from the CI UI-journey screen recordings (artifact
`native-studio-39f29cb…-1-0`, run 38516791084, source `39f29cb`, 2026-10-14; `welcome.webp` from
`30e90cf`; `audio.webp`, `grid.webp`, `shapes.webp`, `rooms.webp` from `960241f`, 2026-10-12),
downscaled to 480 px WebP. Every caption carries the revision. Nothing is a mock-up.

Numbers on the pages were read from the source on 2026-10-14: 30 `DrawingTool` cases, 13 brush
families (`StudioBrush.swift`), 18 blend modes (`StudioCraftLayers.swift`), 2,127 sounds
(`StudioSounds/catalogue.json`), 207 + 1,818 pictures (`StudioImages/*.json`), 4 export formats,
plans Creator USD 4.99 and Pro USD 9.99 monthly from `docs/BILLING_CONTRACT.md` (planned, not on sale).

Checks: `node scripts/website/check_help.mjs --check`, `node scripts/website/build_site.mjs --check`,
`PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/a11y_perf.mjs`. The harness now also
audits the four new pages and runs a flipbook journey on `play.html` (stroke, duplicate, add, play,
GIF and PNG downloads). Measured results are in `docs/WEBSITE_INVENTORY.md` §6.

## Wave 2 (2026-10-14, same day): store, login, clips, splash, reveal, interaction

| Area | Files | Notes |
| --- | --- | --- |
| Store | `store.html`, `store.js`, `store-config.js` (`null`), `assets/merch/*.webp` + `templates/`, `scripts/website/render_merch.mjs` | Eight original vector mock-ups (tee, hoodie, dad cap, sticker pack, poster, mug, tote, enamel pin) rendered from HTML/SVG templates with the repository font. Unconfigured: planned line-up, "Price on opening", no cart, no external request. Configured with the owner's Shopify Storefront values (public token, `*.myshopify.com` domain): products and prices load from the Storefront API, a Shopify cart is kept server-side, Checkout opens Shopify's hosted checkout. No price is typed into the page. |
| Login | `account.html`, `account.js`, `account-config.js` (backend origin + publishable key; `providers: []`) | Email/password sign-in, create account (confirmation email), reset link, provider buttons only for providers listed in the config, memory-only session with expiry, profile (email, confirmation, handle and plan from `public.users` when installed, honest server error otherwise), sign out, deletion request through `sdi_account_lifecycle`. Recovery and provider redirects are read from the URL fragment and cleared. |
| Clips | `clips/*.mp4` + `*.webp` posters | Seven 16–40 s clips cut with ffmpeg from the CI screen recordings (run 38516791084, source `39f29cb`): create project, draw and layers, sound library, lasso and Spatter, export PNG, rotoscope, brush and colour. 480 px, H.264, 15 fps, no audio; `preload="none"` with posters; 1.4 MB total. Three on the home page, four in the Studio tour (one behind the export tabs). |
| Splash | `index.html` `#splash`, `site.js` | Decorative overlay (mark, STICKDEATH ∞, Animation Studio, Ready) that fades out in 1.9 s, `aria-hidden`, no focusable controls, removed from the DOM afterwards, skipped under reduced motion and once per browser session (`sessionStorage`, guarded). |
| Scroll reveal | `[data-reveal]` + `site.js` + `.reveal` | Sections fade and rise as they enter the viewport (IntersectionObserver). Without JavaScript or with reduced motion everything is simply visible. The harness scrolls each page once before auditing so coverage is unchanged. |
| Interaction | hero speed slider (2–24 fps) retimes the flipbook; dragging across the frames scrubs them; export captures on the Studio tour sit behind keyboard-navigable tabs; frame counter ticks | |
| StickDeath OS | `index.html` (was `os.html`), `os.css`, `os.js`, `sounds/` (8 CC0 sounds, byte-identical to the catalogue, AAC kept in its MP4 container under `.mp4`, + `credits.json`), `assets/os/` (1-bit dithered wallpaper, pattern, mark) | A desktop you can play in, inspired by poolsuite.net: boot sequence (skippable; instant under reduced motion), menu bar whose items open windows, a ticking frame counter and clock, desktop icons, freeform windows on desktop and phone with close / half size / maximize (each a toggle back to the remembered normal size), a flame button that saves the window to the dock and brings it back in place, drag by the title bar with mouse or finger, resize by the corner grip, double-click the title to zoom (keyboard: arrows move, Escape closes), Jukebox with a Web Audio spectrum scope playing sounds copied unmodified from the app catalogue with per-sound credits, Screens and Clips windows, and the flipbook and store embedded through `?embed=1`, which hides the site chrome. Memory only. |
| Brand kit | `brand.html` | Mark, wordmark, colours, type, downloads and naming rules; the watercolor channel mark stays out of the public kit. |
| Deploy | `.github/workflows/website-deploy.yml`, `docs/STORE_SETUP_OWNER.md` | Dispatch-only GitHub Pages deploy until the owner enables Pages and DNS; Shopify runbook for the store. |
| Mac clean-up | `scripts/owner/mac_stickdeath_cleanup.sh` | Owner-run zsh script: lists DerivedData, archives, `.xcresult` bundles, duplicate clones, downloaded artifacts and scratch folders with sizes; `--archive` moves them to `~/StickDeath-Archive-YYYYMMDD` (never deletes; never touches the kept clone, ReferenceCorpus or the design reference). Written here, not runnable in this Linux container. |

Measured 2026-10-14: `a11y_perf` **527/527** (13 pages × 3 viewports, index behaviour, account, store, splash, slider and flipbook journeys); home page at 390×844 Slow-4G CPU×4: 10 requests, 315,779 bytes, LCP 1,316 ms, CLS 0.0017 (three clip posters now load with the page). `render_merch.mjs --check` OK.

---

## History before the rebuild

Local-only, buildless product/help implementation for issues #270/#272. Open `index.html` locally or serve this directory later with the team's approved static host. No dependencies, bundling or framework setup are required. No existing public marketing/review site, hosting configuration or audience was changed.

Implemented: responsive home/product/platform/pricing-status sections, accessible expanding mobile navigation and keyboard focus, searchable category-filtered help with direct article fragments, real browser-local problem-summary download, data-use explanation and license links. No fabricated downloads, prices, user counts, testimonials, account state or ticket submission. No chat/calls, analytics, SDKs, provider calls, project uploads or persistent browser storage.

The motion study is original illustrative SVG, explicitly not an app capture. The existing owner-restricted native evidence viewer is linked without copying private capture files or claiming that this website executes SwiftUI. `screens.html` shows nine real simulator captures (`screens/*.webp`, 480 px WebP downscales of the CI UI-journey artifacts from source revision `960241f`, 2026-10-12), each labelled with its source revision and prerelease status; refresh them from a newer artifact when the Studio changes. Special Elite was copied unmodified from the repository with its Apache license and original notice. `assets/mark.svg` is a simple original stick-figure navigation mark, not a claim to a separate registered logo.

Source grounding: inspected issue #270 and #272 bodies on October 9, 2026; native iOS Studio/export source and current Android local implementation. Canonical HEAD at authoring was `bf060c4` with in-progress implementation changes. The help source distinguishes iOS behavior from the unverified Android foundation. Website date is an editorial date, not an acceptance or release claim.

Intentionally unconnected: account/authenticated support intake, receipt/status delivery, billing, application installers and editable cross-platform synchronization. Pricing is a factual status page until approved plans and services exist. Local report download is clearly not the authenticated support flow required for full #272 completion.

Per the owner's implementation-first direction, no build, test, browser/accessibility review, dependency download, deployment or commit was performed. Later acceptance must include mobile/desktop, keyboard/VoiceOver, reduced motion, all links/help fragments, provider-independent download behavior, approved screenshots and final release/content review. Do not close #270/#272 based on this source alone.

## October 9 help-navigation and Studio guidance update

- Added task-based iOS guides for whole-artwork lasso/Move, image-pixel lifting, sound-library placement and Files/movie soundtrack import. Lasso guidance matches native Spatter guide revision `2026-10-12.1`; audio instructions were read against `AudioPanels.swift`. Guidance explicitly distinguishes current source from the user's installed build.
- Each expanded topic has a shareable fragment link. Reopening the same fragment after filtering now clears filters and restores/focuses the topic; it no longer depends on a hash-change event that cannot occur for an unchanged URL. Modified clicks keep native browser behavior.
- JavaScript syntax and whitespace checks are recorded by the coordinator. Browser interaction, VoiceOver, real device behavior, deployment and authenticated support intake remain deferred/unconnected. No issue completion is claimed.

## Local support-summary review flow

The form now collects bounded category, optional app version/build, expected result and reproduction steps. Review prepares an explicit “not submitted” summary; Download and Copy are separate user actions. Editing inputs invalidates the prepared summary to prevent exporting stale details. Unsupported downloads/clipboard operations preserve a selectable plain-text fallback. Clear removes form/preview state and outstanding Blob URLs; it explicitly does not erase downloaded files or the system clipboard. Leaving the page clears its draft. No local/session storage, attachments, identity collection or network submission was added.

JavaScript syntax and whitespace checks passed for this slice. Actual browser copy/download/clear behavior and accessible mobile acceptance remain deferred. This local preparation flow does not satisfy the authenticated receipt/status, abuse limits or admin support backend gates in #272.

## October 12 batch: help source of truth, discovery files, policy drafts, account shell, harness

- **Help center.** `help/articles.json` is the only editable source (20 topics with `id`, `category`, `platform`, `title`, `steps`, `limits`, `sources`, `guideRevision`, per-article `reviewed` date and `status`). `node scripts/website/check_help.mjs` validates it against the repository (guide revision from `SpatterAIViewModel.swift`, every curly-quoted UI label verbatim in Swift/Kotlin, every source path present) and regenerates `help/help-data.js`, which `help.js` reads so the page works from `file://`. Never edit `help-data.js`; `--check` fails when it is stale. The single editorial date was replaced by each topic's reviewed date and status badge.
- **Truthfulness.** Android copy now reflects the Kotlin source (eight brush families, shapes, text, fill, 16 blend modes, onion skin, four-track audio, PNG/spritesheet/GIF/MP4 export, `.sdiandroid.json` backups, partial one-way iOS import; transparent export and Android-to-iOS transfer absent), labelled as source implementation with device verification deferred. The owner-only review-host link was removed from the public page. `#pricing` is unchanged and still lists no plan or price.
- **Discovery.** `scripts/website/site_constants.mjs` holds the single canonical base (an owner-gated `.invalid` placeholder until the domain is verified). `node scripts/website/build_site.mjs` rewrites absolute self-URLs in every page, writes `robots.txt`, `sitemap.xml` (indexable pages only) and generates `policies/attribution.html` from the repository's license/credit files; `--og` renders `assets/og-card.png` from `assets/og-card.html`. JSON-LD is WebSite + Organization only. `404.html`, `account.html` and the policy drafts carry `noindex`.
- **Policies.** `policies/terms-v1.html`, `privacy-v1.html` and `publishing-v1.html` are version 1.0 drafts with no effective date and a visible "Draft — requires legal review before publication" banner. They describe implemented behavior only and mark unresolved items (contact route, age rules, retention periods, published-copy removal) as owner-gated.
- **Account shell.** `account.html` reads `account-config.js` (`window.SDI_ACCOUNT_CONFIG = null`). Without configuration it states that accounts and billing are not connected; with a valid https portal URL it shows only a link. It never lists prices.
- **Harness.** `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node scripts/website/a11y_perf.mjs` serves the folder from an in-process Node server and runs the accessibility, behavior, no-JS, reduced-motion, `file://` and throttled performance checks described in `docs/WEBSITE_INVENTORY.md`, where the measured results of the last run are recorded. Fixes made from its findings: 44px brand/nav/footer/table-link targets, long-token wrapping on policy pages, `novalidate` on the support form so the accessible status message replaces native bubbles, CSS-driven compact navigation (the JS used to hide the stacked nav after load, CLS 0.25 → 0), and a metric-matched local fallback face for Special Elite.
- Hosting, domain, deployment and rollback configuration are still absent from the repository; see `docs/WEBSITE_INVENTORY.md`.

## Desktop wave 3 (2026-10-14)

- **Layout memory.** Open windows, their places, snapped/half/maximized state, the dock and moved desktop icons are kept in this browser (`localStorage` key `sdi-os`, every access guarded). Phones always start fresh.
- **Edge snapping.** Dragging a title bar to the left or right edge snaps to that half at full height; the top edge maximizes. Dragging a snapped window away restores its normal size. Alt+Arrow keys do the same from the keyboard.
- **Desktop menu.** Tidy windows, Close all, CRT scanlines (remembered), Screensaver now, Keyboard shortcuts, Privacy choices, Reset desktop. A bouncing-mark screensaver starts after two idle minutes (never with reduced motion).
- **Privacy window.** Local usage counters are off by default and never sent anywhere; "Forget everything" clears all site storage.
- **Discord.** The community chat is the owner's Discord server (`https://discord.gg/mVUxqbB5c`, #StickDeath_Infinity): a Discord window and icon on the desktop, a section on community.html and a footer link on every page. The app itself still has no chat.
- Harness: 619/619 checks, including snapping, reload memory, the menu, CRT, icon drag, privacy counters and the screensaver.
