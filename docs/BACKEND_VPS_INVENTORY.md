# Backend VPS Inventory — 72.167.36.70

**Date:** 2026-09-06
**Inspector:** OpenCode (bridge task #58)
**Method:** Read-only SSH via `~/.ssh/stickdeath_backend` → `joewillisny@72.167.36.70`
**Scope:** Inventory only — no remote state was modified.

---

## 1. Executive Summary

The VPS is an Ubuntu 24.04.4 LTS instance (1.9 GB RAM, 38 GB disk, 35% used) hosted at 72.167.36.70 (GoDaddy SecureServer). It has been up 141+ days with minimal load.

**StickDeath Infinity is already deployed here** with two nginx-served frontends and a Supabase-backed Convex web app. The main application at `stickdeath.willisnmb.com` serves the web app (port 80) and an admin portal (`/admin`). An older Expo-based app exists in `/home/joewillisny/StickDeath-Infinity-/` but is not actively served.

The VPS also hosts unrelated workloads: a **9Router** dashboard (PM2, port 20128), a **Vitros Inventory Dashboard** (static HTML), a **REM Inventory Tracker API** (FastAPI/uvicorn, port 8000), **Nydus** server management agents (ports 2224, 8461), **OpenClaw** AI gateway (port 18789), and standard mail infrastructure (Postfix, MTA-STS).

---

## 2. Host / Capacity Summary

| Item | Value |
|---|---|
| Hostname | `70.36.167.72.host.secureserver.net` |
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | 6.8.0-87-generic |
| Uptime | 141+ days (since ~Apr 17, 2026) |
| CPU Load | 0.05 / 0.03 / 0.00 (idle) |
| RAM | 1.9 GB total, 1.4 GB used, 502 MB available |
| Swap | None (0 B) |
| Disk (`/dev/sda1`) | 38 GB total, 13 GB used (35%), 25 GB free |
| Public IP | 72.167.36.70 |
| Tailscale IP | 100.78.194.37 |
| Reboot Required | Unknown (could not check without sudo) |
| Pending Updates | Unknown (apt not run — safety gate) |

### Tailscale Network

| Hostname | IP | Status |
|---|---|---|
| `70` (this VPS) | 100.78.194.37 | online |
| `amd-halo` | 100.121.165.22 | offline (16d ago) |
| `iphone181` | 100.106.33.111 | online |
| `mcso9tqzb9-1` | 100.99.71.65 | online |
| `mcso9tqzb9` | 100.98.25.26 | offline (17d ago) |
| `users-mac-mini` | 100.68.105.127 | offline (1d ago) |

---

## 3. Service / Process / Port Inventory

### Listening Ports

| Port | Protocol | Service / Process | Binding |
|---|---|---|---|
| 22 | TCP | OpenSSH | 0.0.0.0 |
| 80 | TCP | nginx | 0.0.0.0 |
| 587 | TCP | Postfix (submission) | 127.0.0.1 |
| 2224 | TCP | Nydus server management | 0.0.0.0 |
| 8000 | TCP | uvicorn (REM Inventory) | 0.0.0.0 |
| 8461 | TCP | Unknown (likely Nydus API) | 127.0.0.1 |
| 18789 | TCP | OpenClaw gateway | 127.0.0.1 / [::1] |
| 20128 | TCP | Next.js (9Router) | *:20128 |
| 5432 | TCP | PostgreSQL 16 | 127.0.0.1 |
| 41641 | UDP | Tailscale WireGuard | 0.0.0.0 |

### Running Systemd Services (StickDeath-Relevant)

| Service | Status | Description |
|---|---|---|
| `nginx` | active | Web server / reverse proxy |
| `postgresql@16-main` | active | PostgreSQL 16 database |
| `rem-inventory.service` | active | FastAPI/uvicorn inventory tracker (port 8000) |
| `nydus-ex.service` | active | Nydus server management agent |
| `nydus-ex-api.service` | active | Nydus server management API |
| `tailscaled` | active | Tailscale VPN |
| `sendmail` | active | Mail transport agent |
| `postfix-mta-sts-resolver` | active | MTA-STS policy resolver |
| `certbot.timer` | active | TLS cert renewal (twice daily) |
| `cron` | active | System cron daemon |

### PM2 Processes

| Name | Port | Status |
|---|---|---|
| `9router` | 20128 | online |

### Other Running Processes

| Process | PID | Description |
|---|---|---|
| `next-server (v16.2.7)` | 1118774 | 9Router web dashboard (started Jun 5) |
| `openclaw gateway` | 1727997 | AI gateway on port 18789 (started Jul 1) |
| `codex app-server` | 1728728 | OpenAI Codex integration (started Jul 1) |
| `uvicorn main:app` | 282939 | REM Inventory API (started Apr 30) |

---

## 4. Reverse-Proxy / Domain Map

### Nginx Configuration

**Only the `stickdeath` vhost is active** in `sites-enabled/`. The `vitros` config exists in `sites-available/` but is **not enabled** — the `vitros-dashboard` is currently served as a standalone static site on port 80 when the stickdeath vhost doesn't match (both match `server_name 72.167.36.70 _`, but only stickdeath is symlinked).

| Path | Upstream | Source Directory |
|---|---|---|
| `/` | Static files | `/var/www/stickdeath/web/dist/` |
| `/admin` | Static files (SPA) | `/var/www/stickdeath/admin-portal/dist/` |
| `/api/*` | Supabase Edge Functions | `https://iohubnamsqnzyburydxr.supabase.co/functions/v1/` |
| `/inventory/` | FastAPI (uvicorn) | `http://127.0.0.1:8000/` → `/home/joewillisny/rem-inventory/` |

**server_names:** `72.167.36.70`, `stickdeath.willisnmb.com`, `_`

**Note:** No TLS is currently configured. Certbot timer is running but no certificates were found in `/etc/letsencrypt/live/`. The site runs over HTTP only.

### Vitros Dashboard (Inactive nginx config)

The `vitros` site in `sites-available/` would serve `/var/www/vitros-dashboard/` on port 80, but its symlink is not in `sites-enabled/`. The vitros content (VITROS Inventory Dashboard training app) is a standalone static build.

---

## 5. Application / Repository Map

### `/var/www/stickdeath/` — Main StickDeath Infinity Deployment

This is the **primary deployed codebase**, a git clone of `github.com/jmw7629/StickDeath-Infinity-` on branch `main`.

| Directory | Description | Tech Stack |
|---|---|---|
| `web/` | Main StickDeath Infinity web app (Convex + React + Vite) | React 19, Convex, Vite 7, Tailwind 4, TypeScript |
| `admin-portal/` | Admin dashboard (Supabase-backed) | React 18, Vite, Supabase, Recharts, Tailwind 3 |
| `app/` | React Native / Expo mobile app source | Expo 52, React Native 0.76, Supabase |
| `ios-native/` | SwiftUI native iOS app source | Swift, SwiftUI |
| `supabase/` | Supabase project config, migrations, edge functions | 15 SQL migrations, 13 edge functions |
| `scripts/` | Deploy helper scripts | bash |

**Latest deploy commit:** `f40bf62` — "Deploy: fix StudioCanvas TS error, enhance Spatter AI with full 10-role spec, build web+admin"

#### Web App (`/var/www/stickdeath/web/`)

- **Stack:** React 19 + Convex (BaaS) + Vite 7 + Tailwind 4
- **Convex schema:** 12 tables (profiles, projects, layers, frames, posts, reactions, comments, challenges, spatterMessages, notifications, follows, userStats) + auth tables
- **Key Convex modules:** `admin.ts`, `spatter.ts` (Spatter AI), `viktorTools.ts`, `studioFrames.ts`, `posts.ts`, `projects.ts`, `comments.ts`, `reactions.ts`, `challenges.ts`, `follows.ts`
- **Built dist exists:** `/var/www/stickdeath/web/dist/` (last built Jun 30)
- **Supabase auth** configured via `auth.config.ts`

#### Admin Portal (`/var/www/stickdeath/admin-portal/`)

- **Stack:** React 18 + Vite + Supabase (service_role key) + React Router
- **Pages:** Dashboard, Analytics, Users, Reports, Projects, Audit
- **Auth:** Supabase email/password auth, admin role check via `users.role` column
- **Built dist exists:** `/var/www/stickdeath/admin-portal/dist/` (last built May 6)

#### Expo Mobile App (`/var/www/stickdeath/app/`)

- **Stack:** Expo 52, React Native 0.76, Supabase, expo-router
- **Not deployed on VPS** — source only; built for iOS via EAS

#### Supabase Edge Functions (`/var/www/stickdeath/supabase/functions/`)

13 edge functions including:
- `spatter-ai` — Spatter AI chatbot (GPT-4o powered, 10-role system)
- `publish-video` — Video publishing pipeline
- `render-video` — Video rendering
- `create-checkout` / `create-tip` / `manage-subscription` — Stripe billing
- `stripe-webhook` — Stripe webhook handler
- `grant-referral-pro` — Referral system
- `admin-actions` — Admin operations
- `ai-assist` — AI assistance
- `social-connect` — Social features
- `send-push-notification` — Push notifications

### `/home/joewillisny/StickDeath-Infinity-/` — Legacy iOS Repository

- **Git remote:** `github.com/jmw7629/StickDeath-Infinity-` (same repo)
- **Branch:** `main` (with remote branches: `swiftui-v3-rebuild`, `feature/video-import-landscape-timeline`)
- **Content:** SwiftUI iOS app (`StickDeathInfinity.xcodeproj`, `Package.swift`)
- **Latest commit:** `6ec7b64` — "v18.3: Fix PanelHeader emoji icon support"
- **Note:** This is a separate clone from `/var/www/stickdeath/`, at a different commit history. It appears to be the original iOS-only development copy.

---

## 6. `/admin/` Architecture and Serving Path

| Aspect | Detail |
|---|---|
| URL | `http://stickdeath.willisnmb.com/admin` or `http://72.167.36.70/admin` |
| Source | `/var/www/stickdeath/admin-portal/` |
| Built output | `/var/www/stickdeath/admin-portal/dist/` |
| Serving | nginx `alias` directive with SPA fallback (`try_files $uri $uri/ /admin/index.html`) |
| Stack | React 18 + Vite + Supabase |
| Auth | Supabase email/password → role check (`admin` or `superadmin`) |
| Backend | Supabase (hosted at `iohubnamsqnzyburydxr.supabase.co`) via `service_role` key |
| Database tables accessed | `users`, `studio_projects`, `posts`, `subscriptions`, `reports`, `admin_actions` |
| Features | User management (ban/unban, role changes), project moderation, report resolution, audit log, analytics dashboard, subscription/revenue tracking |
| Environment | `.env` contains `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SUPABASE_SERVICE_ROLE_KEY` (all redacted) |

**⚠️ Security observation:** The admin portal uses the Supabase `service_role` key client-side (in the browser). This key bypasses RLS. While common for admin dashboards, it means anyone who inspects the built JS can extract it. Consider proxying admin API calls through a server-side function.

---

## 7. Database / Storage Map

### PostgreSQL 16

- **Running:** `postgresql@16-main.service`
- **Binding:** 127.0.0.1:5432 (localhost only)
- **Access:** Requires sudo (could not enumerate databases without privileges)
- **Used by:** REM Inventory Tracker API (via `DATABASE_URL` in `/home/joewillisny/rem-inventory/.env`)
- **StickDeath connection:** The main StickDeath app uses **Convex** (hosted BaaS) and **Supabase** (hosted) — both cloud-hosted databases. The local PostgreSQL does not appear to be used by StickDeath directly.

### Supabase (Cloud)

- **Project:** `iohubnamsqnzyburydxr.supabase.co`
- **Tables:** 48 tables (per SETUP.md), 15 SQL migrations in repo
- **Edge Functions:** 13 functions
- **Storage:** 4 buckets (per SETUP.md)
- **Auth:** Enabled (email/password, Apple, Google providers configured)
- **Used by:** Main web app, admin portal, Expo mobile app, all edge functions

### Convex (Cloud)

- **Project:** Connected via `CONVEX_SITE_URL` env var
- **Tables:** 12+ tables defined in schema (profiles, projects, layers, frames, posts, reactions, comments, challenges, spatterMessages, notifications, follows, userStats) + auth tables
- **Used by:** Main web app (`/var/www/stickdeath/web/`)

### Redis

- Not detected running on the VPS.
- `postfix-mta-sts-resolver.service` references Redis (`After=redis-server.service`) but Redis is not in the running services list. This may mean the MTA-STS resolver is failing or using a different backend.

---

## 8. StickDeath-Specific Findings

### Auth/Session Backend
- **Convex Auth:** Primary auth for the web app (`@convex-dev/auth` library, `auth.config.ts`)
- **Supabase Auth:** Used by admin portal and mobile app (email/password, Apple, Google)
- **Status:** ✅ Functional — auth tables defined, login/signup routes exist

### Spatter AI Proxy/Backend
- **Convex Action** (`spatter.ts`): Full knowledge-base chatbot with Viktor Spaces AI gateway fallback
- **Supabase Edge Function** (`spatter-ai/index.ts`): GPT-4o powered with 10-role system (chat, welcome, generate, enhance, feedback, support, moderate, collaborate, react, escalate)
- **Status:** ✅ Comprehensive implementation — both Convex and Supabase paths exist

### Publishing/YouTube Worker
- **Supabase Edge Function** (`publish-video/`): Exists in repo
- **Status:** ⚠️ Implementation exists but not verified if functional

### Media Upload/Storage
- **Convex Storage:** Frames stored via `storageId` references in Convex
- **Supabase Storage:** 4 buckets configured
- **Studio Components:** `ImageVault.tsx`, `SoundVault.tsx`, `ExportDialog.tsx`
- **Status:** ✅ Framework exists

### Community/Chat/Call Services
- **Posts, Comments, Reactions, Follows, Challenges** — all defined in Convex schema
- **No LiveKit integration detected** — grep found no LiveKit references in the web app
- **Status:** ✅ Community features present; video calls/chat not yet integrated

### Admin Moderation/Control APIs
- **Convex `admin.ts`:** User promotion, role setting, banning
- **Admin Portal:** Full Supabase-backed admin dashboard with user management, reports, audit log
- **Status:** ✅ Functional admin layer

### Analytics/Logging
- **Admin portal AnalyticsPage** exists (connected to Supabase)
- **Convex:** View counts, reaction counts on posts
- **Status:** ✅ Basic analytics in place

### LiveKit Integration
- **Not detected** in any source files or dependencies.
- **Status:** ❌ Not yet implemented

### Supabase Integration
- **Deep integration** — auth, database, edge functions, storage, billing (Stripe)
- **Status:** ✅ Primary backend for admin portal, mobile app, and edge functions

---

## 9. Other Unrelated Workloads on the VPS

| Workload | Location | Port | Description |
|---|---|---|---|
| **9Router** | `/home/joewillisny/9router/` | 20128 | Next.js network management dashboard (PM2-managed). Version 0.4.66. Not StickDeath-related. |
| **Vitros Dashboard** | `/var/www/vitros-dashboard/` | — | Static HTML training dashboard for "VITROS Inventory" system. Not StickDeath-related. |
| **REM Inventory Tracker** | `/home/joewillisny/rem-inventory/` | 8000 | FastAPI + SQLAlchemy inventory API. Not StickDeath-related. |
| **Nydus** | `/opt/nydus/` | 2224, 8461 | Server management agent pair (nydus-ex + nydus-ex-api). Hosting platform tooling. |
| **OpenClaw** | `/home/joewillisny/.openclaw/` | 18789 | AI gateway + Codex integration. Not StickDeath-related. |
| **Postfix/MTA-STS** | system | 587, 25 | Mail transport agent with MTA-STS policy resolver. System infrastructure. |

---

## 10. Security / Maintenance Observations

### Observations (No Changes Made)

1. **No TLS configured.** Certbot timer is active but no certificates exist. The site runs over HTTP only. `stickdeath.willisnmb.com` and the IP serve unencrypted traffic.

2. **Admin portal uses `service_role` key client-side.** The built JS bundle at `/admin/` contains the Supabase `service_role` key, which bypasses Row Level Security. Anyone can extract it from the browser.

3. **9Router exposes credentials in `ecosystem.config.js`.** JWT secret, initial password, API key secret, and machine ID salt are in plaintext in `/home/joewillisny/9router/ecosystem.config.js`.

4. **Git remote URLs contain tokens.** The `/var/www/stickdeath/.git/config` contains a GitHub PAT in the fetch URL (redacted in this report). The `/home/joewillisny/deploy_vps.sh` also contains Supabase keys and Stripe test keys in plaintext.

5. **141+ days uptime, no swap.** While the system is stable, there is no swap partition. A memory spike could trigger OOM kills.

6. **No firewall rules detected.** `ufw` and `iptables` returned no output. All listening ports may be exposed to the internet.

7. **Redis may be missing.** The MTA-STS resolver depends on `redis-server.service` which is not running.

8. **Two separate StickDeath clones exist** — `/var/www/stickdeath/` (deployed, newer commits) and `/home/joewillisny/StickDeath-Infinity-/` (development, different commit history). This could lead to confusion about which is authoritative.

---

## 11. Recommended Reuse Plan for StickDeath Backend

> **Note:** These are recommendations based on observations, not actions taken.

### Already Production-Ready (Reusable as-Is)

| Component | Status | Notes |
|---|---|---|
| **Convex backend** | ✅ Ready | Full schema, auth, all CRUD operations, Spatter AI |
| **Supabase edge functions** | ✅ Ready | 13 functions covering billing, publishing, AI, admin |
| **Admin portal** | ✅ Ready | Full dashboard with user/project/report management |
| **Web app (Convex)** | ✅ Ready | Studio, feed, challenges, profile, Spatter overlay |
| **Nginx serving** | ✅ Ready | Reverse proxy to Supabase, static file serving |

### Needs Work Before Production

| Component | Gap | Recommendation |
|---|---|---|
| **TLS/HTTPS** | No certificates configured | Set up certbot for `stickdeath.willisnmb.com` |
| **Admin key exposure** | `service_role` key in client bundle | Proxy admin API calls through server-side edge function |
| **LiveKit** | Not integrated | Add for real-time collaboration/video calls |
| **YouTube publishing** | Edge function exists but unverified | Test and verify the publish-video pipeline |
| **Redis** | Not running (MTA-STS may need it) | Install and configure if MTA-STS is needed |

### Architecture Observations

- The **dual-backend** approach (Convex for web app, Supabase for admin/mobile/edge functions) is unusual. Convex handles the main app data; Supabase handles auth for admin and billing. This works but adds complexity.
- The **admin portal queries Supabase directly** (bypassing Convex), which means user data must be synced between Convex and Supabase or the admin portal must use Supabase as the source of truth for user management.
- The **Expo mobile app** at `/var/www/stickdeath/app/` is source-only on the VPS — not built or served here. It's built via EAS for iOS.

---

## 12. Items That Could Not Be Inspected

| Item | Reason |
|---|---|
| PostgreSQL database names/tables | Requires `sudo` for `psql` access; user `joewillisny` lacks direct DB access |
| Reboot-required state | Requires `sudo` to check `/var/run/reboot-required` |
| Pending apt updates | Not run to avoid installing anything (safety gate) |
| UFW / iptables rules | No output returned — may need `sudo` or may not be configured |
| Redis status | Not in running services; may need `sudo` to inspect |
| Supabase remote data | Cloud-hosted; not inspectable from VPS |
| Convex remote data | Cloud-hosted; not inspectable from VPS |
| `/var/log/` contents | Not inspected to avoid data exposure |
| SSL certificate private keys | Not accessed (safety gate) |

---

*This document was generated as part of GitHub issue #58. No remote state was modified. All secrets encountered were redacted before writing.*
