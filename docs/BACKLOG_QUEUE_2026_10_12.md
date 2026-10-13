# Backlog next queue — dependency ordered

Source: the coordinator's cached issue index (200 issues; the cache carries no closed state, so every cached issue is treated as open and the live tracker's closed dependencies such as #123, #158, #173 and #175 show as 'not in export'). Generated at branch head ee35143 on 2026-10-12 with `scripts/backlog/issue_cache_adapter.py` -> `audit_queue.py` -> `render_queue.py`. Before posting to #128, regenerate from a fresh `issue list --state all --json number,title,state,labels,body,url` export so closed items drop out and real blockers resolve.

Export: 200 issues, 200 open; 78 open `sdi:next` (within the 50–100 target). Inventory and ordering only; nothing here is finished or verified software.

Blocking cycles: none
Duplicate titles: none
Dependencies referenced but absent from the export (partial export, listed per row below): #123, #158, #173, #175

## Queue (100 of 162 open non-epic items; dependency order, then P0 < P1 < P2, next < later)

| # | Issue | P | Lane | Open blockers | Deps not in export | Note |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | #124 [SDI F02] Pass the complete app build and exact-source native regression gates | P0 | next | — | #123 | — |
| 2 | #125 [SDI F03] Map every visible control to implementation and acceptance evidence | P0 | next | — | #123 | — |
| 3 | #126 [SDI F04] Publish current source-labelled SwiftUI captures and a native review route | P0 | next | #124 | — | — |
| 4 | #129 [SDI A01] Establish secure account identity and provider-linking rules | P0 | next | — | #123 | — |
| 5 | #134 [SDI A06] Restore sessions automatically without bypassing consent | P0 | next | #129 | — | — |
| 6 | #139 [SDI S01] Finish sole floating toolbar docking and submenu placement | P0 | next | — | #123 | — |
| 7 | #140 [SDI S02] Give each tool its own persistent meaningful settings | P0 | next | #125, #139 | — | — |
| 8 | #152 [SDI S14] Implement marquee and lasso selection on real document content | P0 | next | #140 | — | — |
| 9 | #154 [SDI S16] Complete selection move, scale, rotate and flip | P0 | next | #152 | — | — |
| 10 | #155 [SDI S17] Integrate drawing copy, cut and paste with fresh identities | P0 | next | #152 | #123 | — |
| 11 | #156 [SDI S18] Make Delete and duplicate explicit, reversible and safe | P0 | next | #152 | — | — |
| 12 | #159 [SDI S21] Enforce visibility, opacity and every layer lock mode | P0 | next | — | #158 | — |
| 13 | #161 [SDI S23] Complete frames, duration, duplication and timeline reordering | P0 | next | — | #123 | — |
| 14 | #163 [SDI S25] Complete full-document transactional undo and redo | P0 | next | #161 | #158 | — |
| 15 | #164 [SDI S26] Wire every Studio dropdown and bottom control to a real command | P0 | next | #125, #140, #163 | — | — |
| 16 | #167 [SDI D01] Finish the offline project browser and project management | P0 | next | — | #123 | — |
| 17 | #168 [SDI D02] Harden atomic saves and crash-recovery checkpoints | P0 | next | #167 | — | — |
| 18 | #169 [SDI D03] Verify legacy animation migration and collision preservation | P0 | next | #168 | — | — |
| 19 | #172 [SDI D06] Protect local project isolation and private data | P0 | next | #134, #168 | — | — |
| 20 | #186 [SDI SEC01] Inventory the existing backend and admin before configuration changes | P0 | next | — | — | — |
| 21 | #187 [SDI SEC02] Enforce object-level authorization and minimum server data | P0 | next | #129, #186 | — | — |
| 22 | #203 [SDI AI01] Give Spatter accurate screen, tool and document context | P0 | next | #140 | #123 | — |
| 23 | #204 [SDI AI02] Extend Spatter's validated command registry across Studio | P0 | next | #163, #203 | — | — |
| 24 | #205 [SDI AI03] Make multi-command AI edits atomic, cancellable and reversible | P0 | next | #204 | — | — |
| 25 | #209 [SDI AI07] Complete authenticated provider-neutral AI transport and budget controls | P0 | next | #129, #186 | — | — |
| 26 | #210 [SDI AD01] Enforce server-side admin roles, MFA and audited privileged actions | P0 | next | #129, #186 | — | — |
| 27 | #269 [SDI W01] Verify existing website source, hosting, domain and reversible deployment | P0 | next | #126, #186 | — | — |
| 28 | #174 [SDI P01] Record creator consent and rights for official-channel and marketing publication | P0 | later | #129 | #173 | — |
| 29 | #238 [SDI SEC05] Protect provider credentials and OAuth refresh tokens | P0 | later | #186 | — | — |
| 30 | #260 [SDI SEC03] Retire legacy messaging and calling entry points across the backend | P0 | later | #186 | #123 | — |
| 31 | #127 [SDI F05] Compare the supplied visual references against actual native layouts | P1 | next | #124 | — | — |
| 32 | #130 [SDI A02] Complete Sign in with Apple and private-relay account handling | P1 | next | #129 | — | — |
| 33 | #131 [SDI A03] Complete Google sign-in and secure callback handling | P1 | next | #129 | — | — |
| 34 | #132 [SDI A04] Complete GitHub sign-in with minimal OAuth permissions | P1 | next | #129 | — | — |
| 35 | #133 [SDI A05] Complete Microsoft sign-in and supported account types | P1 | next | #129 | — | — |
| 36 | #136 [SDI A08] Finish branded splash and reliable startup routing | P1 | next | #134 | — | — |
| 37 | #137 [SDI A09] Finish welcome, onboarding and guest Studio access | P1 | next | #136 | — | — |
| 38 | #138 [SDI A10] Make all tabs, deep links and leave-Studio transitions safe | P1 | next | #137 | — | — |
| 39 | #141 [SDI S03] Verify pen, pencil, marker, crayon and brush-family rendering | P1 | next | #140 | — | — |
| 40 | #142 [SDI S04] Complete airbrush, watercolor, neon and calligraphy behavior | P1 | next | #141 | — | — |
| 41 | #143 [SDI S05] Finish pressure, smoothing and interrupted-stroke handling | P1 | next | #141 | — | — |
| 42 | #144 [SDI S06] Finish eraser modes and strength behavior | P1 | next | #140 | — | — |
| 43 | #145 [SDI S07] Complete bucket fill with tolerance and boundary rules | P1 | next | #140 | — | — |
| 44 | #146 [SDI S08] Complete eyedropper and color editing fidelity | P1 | next | #140 | — | — |
| 45 | #147 [SDI S09] Finish line, rectangle, ellipse and arrow tools | P1 | next | #140 | — | — |
| 46 | #148 [SDI S10] Implement editable text and typography controls | P1 | next | #140 | — | — |
| 47 | #149 [SDI S11] Complete gradient, blur, smudge, sharpen and burn effects | P1 | next | #140 | — | — |
| 48 | #150 [SDI S12] Finish rulers, guides, mirror and constrained drawing | P1 | next | #140 | — | — |
| 49 | #151 [SDI S13] Finish Hand, zoom, fit and canvas navigation | P1 | next | #139 | — | — |
| 50 | #153 [SDI S15] Implement wand selection with real tolerance and sampling | P1 | next | #152 | — | — |
| 51 | #157 [SDI S19] Finish crop and canvas resize semantics | P1 | next | #154 | — | — |
| 52 | #160 [SDI S22] Complete layer blend modes and glow in canvas and export | P1 | next | #159 | — | — |
| 53 | #162 [SDI S24] Finish onion skin, thumbnails and playback synchronization | P1 | next | #161 | — | — |
| 54 | #170 [SDI D04] Finish portable project backup, import and restore | P1 | next | #168 | — | — |
| 55 | #171 [SDI D05] Bound local storage, asset lifetime and cache eviction | P1 | next | #168 | — | — |
| 56 | #196 [SDI IM04] Insert images as editable layer content with transforms | P0 | next | #154, #171 | #173 | — |
| 57 | #176 [SDI AU02] Finish categorized searchable sound-library UI from audio references | P1 | next | — | #175 | — |
| 58 | #177 [SDI AU05] Complete multitrack audio placement, dragging and snapping | P1 | next | #161, #176 | — | — |
| 59 | #178 [SDI AU06] Finish clip trim, split, duplicate and explicit deletion | P1 | next | #177 | — | — |
| 60 | #179 [SDI AU07] Complete audio volume, mute, fades and track mixing controls | P1 | next | #177 | — | — |
| 61 | #180 [SDI AU08] Synchronize audio transport with animation playback and scrub | P1 | next | #162, #179 | — | — |
| 62 | #181 [SDI AU10] Verify final audio mixing and export fidelity | P0 | next | #178, #180 | — | — |
| 63 | #182 [SDI EX01] Finish correct MP4 export for the complete document | P0 | next | #160, #161, #181 | — | — |
| 64 | #183 [SDI EX02] Finish GIF export with honest palette, timing and alpha behavior | P1 | next | #160, #161 | — | — |
| 65 | #184 [SDI EX03] Finish PNG sequence and spritesheet export with manifests | P1 | next | #160, #161 | — | — |
| 66 | #185 [SDI EX04] Make export presets, filenames and sharing-file lifetime reliable | P0 | next | #182, #183, #184 | — | — |
| 67 | #188 [SDI P02] Validate and moderate real rendered submissions before release | P0 | later | #174, #185, #187 | — | — |
| 68 | #189 [SDI P03] Implement durable resumable binary upload jobs | P0 | later | #188 | — | — |
| 69 | #190 [SDI D07] Implement bounded temporary uploads and post-publication cleanup | P0 | later | #189 | — | — |
| 70 | #211 [SDI AD03] Build the exact-render approval queue and decision history | P0 | later | #188, #210 | — | — |
| 71 | #191 [SDI AU03] Expand licensed free sound packs with deduplication and provenance | P1 | next | — | #175 | — |
| 72 | #192 [SDI AU04] Complete accurate waveform analysis and sound previews | P1 | next | — | #175 | — |
| 73 | #193 [SDI AU09] Finish audio Files import and project-managed media lifetime | P1 | next | #171 | #175 | — |
| 74 | #194 [SDI IM02] Curate thousands of original or free StickDeath-style Studio images | P1 | next | — | #173 | — |
| 75 | #195 [SDI IM03] Build searchable image browsing, favorites and pack downloads | P1 | next | #171, #194 | — | — |
| 76 | #197 [SDI IM05] Finish Photos and Files image permission, orientation and error flows | P1 | next | #196 | — | — |
| 77 | #199 [SDI V01] Implement video import with real metadata and managed lifetime | P1 | next | #171, #197 | — | — |
| 78 | #200 [SDI V02] Implement rotoscope extraction at the actual playhead | P1 | next | #161, #199 | — | — |
| 79 | #201 [SDI V03] Complete video trim, orientation, timing and optional audio extraction | P1 | next | #193, #200 | — | — |
| 80 | #207 [SDI AI05] Finish grounded customer-service and in-app help answers | P1 | next | #203 | — | — |
| 81 | #208 [SDI AI06] Preserve personality and safe device-local memory controls | P1 | next | #172, #207 | — | — |
| 82 | #215 [SDI AI11] Make Spatter invoke real export and return factual artifacts | P1 | next | #185, #205 | — | — |
| 83 | #270 [SDI W02] Build the responsive product website from real native app capabilities | P1 | next | #127, #136, #137, #269 | — | — |
| 84 | #128 [SDI F06] Maintain a dependency-ordered 50–100-item next queue without duplicates | P1 | later | — | — | — |
| 85 | #135 [SDI A07] Finish account recovery, email login and deletion entry points | P1 | later | #129 | — | — |
| 86 | #198 [SDI IM06] Provide safe asset removal, attribution and catalogue updates | P1 | later | #171, #195 | — | — |
| 87 | #202 [SDI EX05] Measure long-project export resource limits and recovery | P1 | later | #185 | — | — |
| 88 | #216 [SDI AI12] Run adversarial and end-to-end Spatter acceptance evaluation | P1 | later | #207, #209, #215 | — | — |
| 89 | #217 [SDI SO01] Build the real social video wall and pagination | P1 | later | #129, #187 | — | — |
| 90 | #218 [SDI SO02] Implement idempotent likes, follows and accurate counts | P1 | later | #217 | — | — |
| 91 | #219 [SDI SO03] Implement feed video playback, share and creator-permitted export | P1 | later | #185, #217 | — | — |
| 92 | #220 [SDI SO04] Complete Trending, Recent, Following and Featured feeds | P1 | later | #218 | — | — |
| 93 | #221 [SDI W01] Create War Room video matchups with accepted participants | P1 | later | #188, #217 | — | — |
| 94 | #222 [SDI W02] Implement authenticated favorite voting and abuse limits | P0 | later | #221 | — | — |
| 95 | #225 [SDI W04] Finalize wins, losses and ties transactionally | P0 | later | #222 | — | — |
| 96 | #223 [SDI SO05] Complete challenge creation, scheduling, submissions and voting | P1 | later | #217, #222 | — | — |
| 97 | #224 [SDI SO06] Finish genuine profile editing and creator portfolios | P1 | later | #129, #217 | — | — |
| 98 | #226 [SDI W05] Apply optional public War Room records and badges everywhere | P1 | later | #224, #225 | — | — |
| 99 | #227 [SDI SO07] Implement real achievements and optional public statistics | P1 | later | #224, #226 | — | — |
| 100 | #228 [SDI R01] Create project-scoped collaboration rooms with explicit owner consent | P1 | later | #129, #170, #187 | — | — |

62 further open items follow the same ordering and are omitted by the 100-row limit.

## Owner-gated (11)

| Issue | P | Open blockers |
| --- | --- | --- |
| #246 [SDI AD02] Securely provision the owner command-center identity | P0 | #210 |
| #239 [SDI P04] Connect the existing owner YouTube channel through secure OAuth | P1 | #238 |
| #249 [SDI B01] Verify and reuse the existing Stripe account in read-only mode | P1 | — |
| #250 [SDI B02] Define 4.99 and 9.99 monthly plans and approved annual pricing | P1 | #249 |
| #251 [SDI B03] Implement StoreKit purchase, restore and subscription states | P1 | #129, #250 |
| #266 [SDI QA03] Deliver a signed native review build and physical-device performance evidence | P1 | #124, #202 |
| #280 [SDI AI14] Define the StickDeath blood and impact style spec as reusable motion primitives | P1 | #206, #213 |
| #281 [SDI W11] Support mailbox agent for support@stickdeathinfinity.com | P1 | #207, #272, #277 |
| #282 [SDI W12] Deferred business SMS — reconcile with no-messaging scope | P1 | #262, #276, #277 |
| #286 [SDI AND01] Android app: architecture decision and parity plan | P1 | #116 |
| #289 [SDI AND04] Android billing, push and Play Store release | P1 | — |

## Epics (tracking only, 27)

- #3 [SDI epic] Delivery inventory, acceptance traceability and backlog maintenance
- #4 [SDI epic] Native build, regression and release evidence
- #5 [SDI epic] Preserve historical projects and completed implementation
- #6 [SDI epic] Reference-faithful native visual and accessibility verification
- #7 [SDI epic] Shared visual tokens and adaptive native layouts
- #8 [SDI epic] Splash, welcome and truthful onboarding
- #9 [SDI epic] Apple, Google, GitHub and Microsoft sign-in with session restoration
- #10 [SDI epic] Profiles, ownership and optional public achievements
- #11 [SDI epic] Native navigation, Rooms and protected routes
- #12 [SDI epic] Shared native components and honest service states
- #13 [SDI epic] Current SwiftUI review captures, Simulator and TestFlight route
- #14 [SDI epic] Device-first projects, crash recovery and backups
- #15 [SDI epic] Minimal server storage and verified temporary-media cleanup
- #16 [SDI epic] Licensed dependencies and thousands of redistributable assets
- #17 [SDI epic] Studio project library and lifecycle
- #18 [SDI epic] Canonical Studio canvas, tools and rendered output
- #19 [SDI epic] Single snapping toolbar and tool-specific submenus
- #29 [SDI epic] Complete every visible Studio control
- #30 [SDI epic] Audio, image/video import and real media export
- #31 [SDI epic] Spatter support, editable video creation and owner-approved daily drafts
- #32 [SDI epic] Consented official YouTube and user-selected social publishing
- #117 [SDI epic] Social video wall and challenge lifecycle
- #118 [SDI epic] Invitation-based Studio collaboration rooms
- #119 [SDI epic] War Room video matchups and trustworthy results
- #120 [SDI epic] Admin command center, approval and operations
- #121 [SDI epic] $4.99 and $9.99 subscriptions, annual plans and existing Stripe integration
- #122 [SDI epic] Authorization, privacy, moderation and release safeguards
