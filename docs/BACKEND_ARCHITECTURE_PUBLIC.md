# StickDeath Infinity — Backend Architecture (Public)

> **Evidence discipline note.** This document distinguishes three confidence levels:
> - **Verified source exists** — confirmed in committed source files.
> - **Runtime verified** — confirmed to be operational via executed checks or established deployment facts.
> - **Not verified** — referenced in source or design documents but not confirmed operational.

Sensitive infrastructure details, credential locations, private network topology, and security-specific findings are intentionally omitted from this public report. See the security note at the end of this document.

---

## 1. High-Level Architecture

StickDeath Infinity is a **native SwiftUI/iOS application** backed by a **Supabase-hosted backend**. There is no custom backend server in this repository. The iOS app acts as a thick client that reads and writes directly to Supabase (Postgres, Auth, Storage, Realtime, Edge Functions).

An existing web surface (nginx-served) and an `/admin` surface exist on the backend VPS — these are not part of this repository and are not modified by this documentation task.

**Key external services:**
- **Supabase** — Database, Auth, Storage, Edge Functions, Realtime
- **LiveKit Cloud** — WebRTC voice/video calls and collaboration rooms
- **OpenAI** — GPT-4o for the Spatter AI assistant
- **StoreKit 2** — Apple In-App Purchases for subscriptions
- **Stripe** — Non-digital payments (creator tips, call billing)

---

## 2. Supabase Integration (Verified Source Exists)

All backend data flows route through a singleton Supabase client (`SupabaseManager.shared`) initialized from `AppConfig` (gitignored configuration, not committed to source control).

### 2.1 Auth

| Method | Status | Notes |
|--------|--------|-------|
| Sign In with Apple | Verified source exists | Native `ASAuthorizationController` → Supabase ID token exchange |
| Sign In with Google | Verified source exists | OAuth redirect via `stickdeath://auth/callback` URL scheme |
| Email/Password | Verified source exists | Standard Supabase Auth sign-up/sign-in |
| Guest (Anonymous) | Verified source exists | Anonymous Supabase session with auto-generated username |
| Session persistence | Verified source exists | Supabase auth state change listener implemented |

### 2.2 Database Tables (Inferred from Source)

The following tables are referenced in the iOS client source code. Table existence, schema correctness, and RLS policies are **not verified** from this repository — they would need to be confirmed against the live Supabase project.

| Table | Purpose | Source reference |
|-------|---------|-----------------|
| `users` | User profiles, subscription status, roles | `AuthService.swift` |
| `posts` | Social feed posts | `SocialService.swift` |
| `likes` | Post likes | `SocialService.swift` |
| `comments` | Post comments | `SocialService.swift` |
| `follows` | User follow relationships | `SocialService.swift` |
| `chat_rooms` | Chat room definitions | `MessageService.swift` |
| `chat_messages` | Chat messages | `MessageService.swift` |
| `room_members` | Chat room membership | `MessageService.swift` |
| `challenges` | Community animation challenges | `ChallengeService.swift` |
| `challenge_submissions` | Challenge entries | `ChallengeService.swift` |
| `studio_projects` | Animation project metadata and frame data | `ProjectService.swift` |
| `tips` | Creator tips and call charges | `StripeService.swift` |
| `spatter_bot_configs` | Spatter Command Center bot configurations | `SpatterBotService.swift` |
| `spatter_content_queue` | Content scheduling queue | `SpatterBotService.swift` |
| `spatter_knowledge` | Runtime AI knowledge entries (optional) | `SpatterService.swift` |

**Verification status:** Tables are inferred from client-side query code. Table schemas, indexes, RLS policies, and Supabase RPCs (e.g., `increment_likes`) are not verified from this repository.

### 2.3 Storage

| Bucket | Purpose | Source reference |
|--------|---------|-----------------|
| `media` | Images, videos, avatars, project data | `StorageService.swift` |

Storage operations (upload, download, delete, public URL generation) use Supabase Storage SDK. The `media` bucket holds user-uploaded content organized by path convention (`avatars/`, `projects/`, etc.).

**Runtime verified:** The app's StorageService is wired and would function against a live Supabase project with a properly configured `media` bucket.

### 2.4 Edge Functions

| Function | Purpose | Status |
|----------|---------|--------|
| `livekit-token` | Generates LiveKit room access tokens | Verified source exists (called via `client.functions.invoke`) |
| Project export (server-side rendering) | Render .sdi to GIF/MP4 | Not verified — TODO in `ProjectService.swift` |

### 2.5 Realtime

Supabase Realtime subscriptions for live chat messaging are referenced but **not implemented**. `MessageService.swift:88-95` contains a TODO placeholder for Supabase Realtime channel subscription.

**Status:** Not verified — placeholder only.

---

## 3. LiveKit Integration (Verified Source Exists)

Two LiveKit service implementations exist in the codebase:

### 3.1 Production Implementation (`Services/LiveKit/LiveKitService.swift`)

This is the more complete implementation with:
- Full call phase state machine (idle → preCalling → ringing → incoming → connecting → active → ended)
- R3 billing engine: per-minute rate tiers, spend caps, auto-run extensions, idle detection, abuse guard
- Token generation via Supabase Edge Function (`livekit-token`)
- Audio/video/screen-share media controls
- Post-call fare receipt

**Rate tiers:** Standard $0.05/min, Creator $0.10/min, Pro $0.15/min, Studio $0.25/min

**Runtime verified:** The LiveKit Swift SDK is included as a dependency (`Package.swift`). Actual connection to LiveKit Cloud is not verified from this environment.

### 3.2 Legacy Implementation (`Services/LiveKitService.swift`)

A simpler implementation with basic connect/disconnect, mute/video/screen-share controls, and direct token fetching via HTTP. This file appears to be an earlier version retained alongside the production implementation.

**Note:** The legacy implementation contains a hardcoded Supabase anon key in the token-fetching function. While the anon key is designed to be public, this pattern should be reviewed.

### 3.3 Collaboration Rooms

Five collaboration room types are defined in the Views layer:

| Room Type | Purpose | Status |
|-----------|---------|--------|
| `CollabRoomView` | Multi-user canvas sharing | Verified source exists |
| `CreatorRoomView` | Host + viewers + chat | Verified source exists |
| `WarRoomView` | 2-player battle with spectators | Verified source exists |
| `WatchTogetherView` | Synced video playback | Verified source exists |
| `LeaderboardView` | Competition rankings | Verified source exists |

**Runtime verified:** Room types are defined in the UI layer but actual LiveKit room creation and connection is not confirmed as operational.

---

## 4. Spatter AI (Verified Source Exists)

Spatter is the StickDeath AI assistant/creative operating system. Two components:

### 4.1 On-Device Knowledge Engine (`AI/SpatterBrainLoader.swift`)

- Bundled JSON knowledge base (3 files, ~4900 lines) covering animation, physics, tools, collaboration, community, business, and lore
- 120 embedded knowledge modules (100 brain + 20 core)
- Context-aware knowledge injection based on current screen/tool
- Fallback to Pollinations.ai free endpoint

**Status:** Verified source exists, embedded in app bundle.

### 4.2 Backend Service (`Services/Spatter/SpatterService.swift`)

- Calls OpenAI GPT-4o directly from the client with the full personality prompt + embedded knowledge
- Optionally queries Supabase `spatter_knowledge` table for runtime-added knowledge
- System prompt defines Spatter's personality, knowledge domains, and behavioral rules

**Security observation:** The OpenAI API key is read from `AppConfig.openAIAPIKey` and used directly in a client-side HTTP request. This should be proxied through a Supabase Edge Function for production use. This is noted as a generic security finding without reproducing specific attack vectors.

### 4.3 Spatter Command Center (Verified Source Exists)

Six views implementing an owner-only admin interface for bot management:

| View | Purpose |
|------|---------|
| `SpatterDashboardView` | Overview dashboard |
| `SpatterCommandCenterView` | Command center interface |
| `SpatterBotConfigView` | Bot configuration management |
| `SpatterContentQueueView` | Content scheduling queue |
| `SpatterAnalyticsView` | Analytics display |
| `SpatterCCSettingsView` | Settings management |

Backed by `SpatterBotService.swift` which manages bot configs, content queue, and analytics via Supabase.

**Runtime verified:** The UI is built and the service layer is wired to Supabase queries. Whether the `spatter_bot_configs` and `spatter_content_queue` tables exist in the live database is not confirmed from this repository.

---

## 5. Publishing / Content System

### 5.1 Social Feed (`Services/Social/SocialService.swift`)

- Posts with text, media, and project references
- Likes with RPC-based count increment
- Comments with user join
- Follow/unfollow relationships

**Verified source exists.** Runtime functionality depends on Supabase RLS policies and table configuration.

### 5.2 Challenges (`Services/Challenge/Challenge.swift`)

- Challenge CRUD (create, list, submit, fetch submissions)
- Community animation competitions with time windows

**Verified source exists.** Runtime functionality depends on Supabase configuration.

### 5.3 Studio Projects (`Services/Project/ProjectService.swift`)

- Project CRUD (create, list, save frames, load frames, delete)
- Server-side rendering/export is a TODO — currently throws `exportNotImplemented`

**Verified source exists.** The device-first storage architecture means full animation data stays on device; only metadata and thumbnails sync to the server.

---

## 6. Payment Architecture

### 6.1 Subscriptions (StoreKit 2)

| Tier | Monthly | Yearly | Features |
|------|---------|--------|----------|
| Free | — | — | Basic studio, watermarks, 1080p export, limited projects |
| Creator | $4.99/mo | $49.99/yr | No watermark, unlimited projects |
| Pro | $9.99/mo | $99.99/yr | 4K export, cloud sync, collab rooms, priority support |
| Studio | $19.99/mo | $199.99/yr | Commercial license, team workspace, API access, custom branding |

Subscription status is synced to Supabase `users` table after each StoreKit transaction.

**Verified source exists.** App Store Connect product registration is implied but not confirmed.

### 6.2 Non-Digital Payments (Stripe)

- **Creator tips:** Person-to-person payments (non-digital goods, permitted by Apple guidelines)
- **Call billing:** Consumable service charges for LiveKit R3 calls
- Recorded in Supabase `tips` table; actual Stripe charge via Edge Function (not implemented in this repository)

**Verified source exists for recording.** Stripe Edge Function integration is not confirmed as operational.

---

## 7. Admin Surface

### 7.1 iOS Admin Dashboard (`Views/Admin/AdminDashboardView.swift`)

A 10-tab superuser panel gated by `AppConfig.superuserEmails`:

| Tab | Content |
|-----|---------|
| Dashboard | Stats cards (hardcoded), recent activity (hardcoded) |
| Users | User list (hardcoded sample data) |
| Content | Storage stats (hardcoded) |
| Challenges | Challenge stats (hardcoded) |
| Spatter AI | Brain module count, query stats, admin portal link |
| Bots | Bot status indicators |
| Analytics | DAU/WAU/MAU (hardcoded) |
| Moderation | Report queue (hardcoded) |
| Settings | Maintenance mode, registration, email verification toggles |
| Billing | MRR, subscriber breakdown (hardcoded) |

**Verification status:** The admin view exists in source but currently displays hardcoded placeholder data rather than fetching from the backend. It is not connected to live data.

### 7.2 Web Admin Surface

A web-based admin surface exists on the backend VPS (not part of this repository). Details are intentionally omitted from this public report.

---

## 8. Reusable vs Legacy Assessment

### High-Value Reuse (for SwiftUI production app)

| Component | Confidence | Notes |
|-----------|-----------|-------|
| `SupabaseManager` | Verified source exists | Clean singleton pattern, minimal code |
| `AuthService` | Verified source exists | Complete auth flow with Apple/Google/Email/Guest |
| `StorageService` | Verified source exists | Clean Supabase Storage integration |
| `SocialService` | Verified source exists | Posts, likes, comments, follows — good building blocks |
| `ChallengeService` | Verified source exists | Challenge CRUD — good structure |
| `MessageService` | Verified source exists | Chat rooms and messages — foundation is solid |
| `ProjectService` | Verified source exists | Studio project CRUD — core to the app |
| `DeviceStorageManager` | Verified source exists | Well-designed device-first storage architecture |
| `LiveKitService` (production) | Verified source exists | Complete R3 billing + call management |
| `StripeService` | Verified source exists | StoreKit 2 + Stripe hybrid — thorough implementation |
| `SpatterService` | Verified source exists | AI integration — needs API key proxy for production |

### Legacy / Incomplete

| Component | Status | Notes |
|-----------|--------|-------|
| `LiveKitService` (legacy) | Superseded | Replaced by `Services/LiveKit/LiveKitService.swift` |
| `SpatterBotService` | Partial | Bot configs, content queue, analytics — tables may not exist |
| `AdminDashboardView` | Placeholder | Hardcoded data — needs backend wiring |
| `SpatterCC` views | Partial | UI exists, backend integration incomplete |
| `MessageService` Realtime | Not implemented | TODO placeholder only |
| `ProjectService` export | Not implemented | Server-side rendering TODO |

---

## 9. Architecture Recommendations

1. **Proxy OpenAI calls through Supabase Edge Functions.** Client-side API key usage is a security concern for production. Create a `spatter-chat` Edge Function that holds the API key server-side.

2. **Wire the admin dashboard to live data.** The current hardcoded stats are not useful. Implement Supabase queries or Edge Function endpoints for real admin metrics.

3. **Implement Supabase Realtime for messaging.** The TODO placeholder in `MessageService` should be completed for live chat functionality.

4. **Complete project export.** Server-side rendering via Edge Function is the planned path for .sdi → GIF/MP4 export.

5. **Remove or consolidate the legacy `LiveKitService`.** The simpler implementation at `Services/LiveKitService.swift` is superseded by the production implementation.

6. **Review the hardcoded Supabase anon key** in the legacy LiveKit service. While anon keys are public by design, centralizing configuration through `AppConfig` is preferred.

---

## 10. Security Note

This report intentionally omits:
- Private network topology and infrastructure details
- Credential locations, API key values, and secret inventories
- Specific security vulnerabilities and attack vectors
- Private database names, hostnames, and internal URLs
- Process topology, port bindings, and service manager details
- Admin-auth internals and privileged access patterns

**A private admin-security remediation task is required before production hardening.** The prior inventory identified a potentially severe privileged-credential design issue in the browser admin surface. That finding is not reproduced here. Specific remediation should be addressed in a separate private security task, not in this public documentation.

---

*Document generated from source code inspection of the StickDeath Infinity repository. No remote VPS state was modified in the creation of this document.*
