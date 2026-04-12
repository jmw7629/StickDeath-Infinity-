# StickDeath Infinity

> Stick figure animation studio with social community, auto-publishing pipeline, and AI-powered creation tools.

**iOS + Android** — one codebase, React Native (Expo) + Supabase.

---

## 📁 Project Structure

```
stickdeath-infinity/
├── app/                              # Expo Router screens
│   ├── (auth)/                       # Auth flow (welcome, login, register)
│   ├── (tabs)/                       # Main tabs (Studio, Feed, Messages, Profile)
│   └── studio/[id].tsx               # Animation studio editor
├── src/
│   ├── components/
│   │   ├── studio/                   # Canvas, toolbar, timeline, panels
│   │   └── common/                   # Shared UI components
│   ├── models/                       # StickFigure, Frame, Project data models
│   ├── hooks/                        # useStudio, useAuth, useProjects, useGestures
│   ├── lib/                          # Supabase client, auth provider
│   ├── theme/                        # Dark theme, colors, typography
│   └── types/                        # TypeScript types for database
├── supabase/
│   ├── migrations/                   # 11 SQL migration files (74+ tables)
│   ├── functions/                    # 7 Edge Functions + shared utils
│   ├── seed.sql                      # Initial data (badges, library, etc.)
│   └── config.toml                   # Supabase project config
├── package.json
├── app.json
├── eas.json                          # EAS Build config
├── .env.example                      # Environment variables template
└── README.md                         # ← You are here
```

---

## 🚀 Quick Start (Deploy in 30 Minutes)

### Prerequisites
- Node.js 18+ installed
- Supabase account (free tier works to start)
- Expo account (`npx expo login`)
- Stripe account (for billing — can skip initially)

---

### Step 1: Create Your Supabase Project

1. Go to [supabase.com](https://supabase.com) → **New Project**
2. Name: `stickdeath-infinity`
3. Region: US East (or closest to you)
4. Set a strong DB password — **save it**
5. Wait for project to provision (~2 min)

Once ready, go to **Settings → API** and copy:
- **Project URL** → `https://xxxxx.supabase.co`
- **Anon public key** → `eyJhbGci...`
- **Service role key** → `eyJhbGci...` (keep secret!)

---

### Step 2: Set Up Environment

```bash
# Clone or extract the project
cd stickdeath-infinity

# Copy env template
cp .env.example .env

# Edit .env with your Supabase keys:
EXPO_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
EXPO_PUBLIC_SUPABASE_ANON_KEY=your_anon_key_here
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key_here
```

---

### Step 3: Deploy Database

**Option A — Supabase CLI (recommended):**
```bash
# Install Supabase CLI
npm install -g supabase

# Link to your project
supabase login
supabase link --project-ref YOUR_PROJECT_REF

# Run all migrations
supabase db push

# Seed initial data
supabase db seed
```

**Option B — Supabase Dashboard (manual):**
1. Go to **SQL Editor** in your Supabase dashboard
2. Run each migration file in order:
   - `20260411000001_core_users.sql`
   - `20260411000002_social.sql`
   - `20260411000003_studio.sql`
   - `20260411000004_messaging.sql`
   - `20260411000005_pipeline.sql`
   - `20260411000006_community.sql`
   - `20260411000007_admin.sql`
   - `20260411000008_stripe.sql`
   - `20260411000009_rls_policies.sql`
   - `20260411000010_indexes.sql`
   - `20260411000011_functions.sql`
3. Then run `seed.sql`

---

### Step 4: Configure Auth Providers

In your Supabase dashboard → **Authentication → Providers:**

**Email (enabled by default)**
- Confirm email: OFF for development, ON for production

**Apple Sign-In:**
1. Apple Developer Console → Create a Service ID
2. Bundle ID: `com.willisnmb.stickdeathinfinity`
3. Add the Supabase callback URL
4. Paste Client ID and Secret in Supabase

**Google Sign-In:**
1. Google Cloud Console → Create OAuth 2.0 credentials
2. Add authorized redirect: `https://YOUR_PROJECT.supabase.co/auth/v1/callback`
3. Paste Client ID and Secret in Supabase

---

### Step 5: Install & Run the App

```bash
# Install dependencies
npm install

# Start the Expo dev server
npx expo start

# Scan the QR code with Expo Go (iOS/Android)
# Or press 'i' for iOS simulator / 'a' for Android emulator
```

---

### Step 6: Deploy Edge Functions

```bash
# Deploy all Supabase Edge Functions
supabase functions deploy publish-video
supabase functions deploy render-video
supabase functions deploy ai-assist
supabase functions deploy stripe-webhook
supabase functions deploy create-checkout
supabase functions deploy admin-actions
supabase functions deploy social-connect

# Set function secrets
supabase secrets set STRIPE_SECRET_KEY=sk_live_xxx
supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxx
supabase secrets set STRIPE_PRO_PRICE_ID=price_xxx
supabase secrets set OPENAI_API_KEY=sk-xxx
supabase secrets set YOUTUBE_CLIENT_ID=xxx
supabase secrets set YOUTUBE_CLIENT_SECRET=xxx
supabase secrets set TIKTOK_CLIENT_KEY=xxx
supabase secrets set TIKTOK_CLIENT_SECRET=xxx
supabase secrets set INSTAGRAM_APP_ID=xxx
supabase secrets set INSTAGRAM_APP_SECRET=xxx
supabase secrets set FACEBOOK_APP_ID=xxx
supabase secrets set FACEBOOK_APP_SECRET=xxx
```

---

### Step 7: Build for App Stores

```bash
# Configure EAS Build (first time only)
npx eas-cli build:configure

# Build for iOS
npx eas-cli build --platform ios --profile production

# Build for Android
npx eas-cli build --platform android --profile production

# Submit to stores
npx eas-cli submit --platform ios
npx eas-cli submit --platform android
```

---

## 🏗 Architecture

### Frontend: React Native (Expo)
- **Expo SDK 52** with Expo Router for file-based navigation
- **@shopify/react-native-skia** for high-performance 2D canvas (animation studio)
- **react-native-reanimated** for 60fps panel animations
- **react-native-gesture-handler** for touch/gesture processing

### Backend: Supabase
- **PostgreSQL** — 74 tables covering users, studio, social, messaging, billing, admin
- **Auth** — Email, Apple, Google sign-in with JWT
- **Realtime** — Live updates for DMs, feed, collaboration
- **Storage** — Project assets, renders, user uploads
- **Edge Functions** — Video publishing, Stripe webhooks, AI assistant

### Studio Engine
The animation studio uses a bone-based stick figure rig with an iterative constraint solver:
- 13 joints per figure (head, neck, shoulders, elbows, hands, hip, knees, feet)
- 12 bones with length constraints
- Constraint solver iterates 10x per frame for stable poses
- Onion skinning with configurable depth
- Camera system with pan/zoom/rotate

---

## 📋 Database Tables (74 total)

| Group          | Tables | Description                                    |
|----------------|--------|------------------------------------------------|
| Core Users     | 7      | users, profiles, stats, sessions, waitlist     |
| Social         | 5      | follows, posts, likes, saves, comments         |
| Studio         | 8      | projects, versions, assets, SFX, library       |
| Messaging      | 5      | DM threads, messages, state, blocks, reports   |
| Pipeline       | 6      | render jobs, publish jobs, AI jobs & limits     |
| Community      | 6      | challenges, badges, tips, notifications        |
| Admin          | 4      | admin actions, reports, broadcasts             |
| Stripe         | 29     | Full Stripe sync (subscriptions, invoices...)  |
| **Total**      | **74** |                                                |

---

## 🔑 Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `EXPO_PUBLIC_SUPABASE_URL` | ✅ | Supabase project URL |
| `EXPO_PUBLIC_SUPABASE_ANON_KEY` | ✅ | Supabase anonymous/public key |
| `SUPABASE_SERVICE_ROLE_KEY` | ✅ | Supabase service role key (server only) |
| `STRIPE_SECRET_KEY` | Sprint 2 | Stripe secret key |
| `STRIPE_WEBHOOK_SECRET` | Sprint 2 | Stripe webhook signing secret |
| `STRIPE_PRO_PRICE_ID` | Sprint 2 | Stripe price ID for Pro plan |
| `OPENAI_API_KEY` | Sprint 2 | OpenAI API key for AI assistant |
| `YOUTUBE_CLIENT_ID` | Sprint 2 | YouTube Data API OAuth client |
| `YOUTUBE_CLIENT_SECRET` | Sprint 2 | YouTube Data API OAuth secret |

---

## 📱 App Screens

| Screen | Route | Description |
|--------|-------|-------------|
| Welcome | `/(auth)/welcome` | Landing with Sign In / Sign Up |
| Login | `/(auth)/login` | Email + social auth |
| Register | `/(auth)/register` | Create account with username |
| Projects | `/(tabs)/` | Project gallery — create, browse, open |
| Studio | `/studio/[id]` | Full animation editor |
| Feed | `/(tabs)/feed` | Community animation feed |
| Messages | `/(tabs)/messages` | DM conversations |
| Profile | `/(tabs)/profile` | User profile & settings |

---

## 🛡 Row-Level Security

All tables have RLS enabled. Key policies:
- Users can only read/write their own data
- Public posts/profiles are readable by all authenticated users
- Admin actions require `role = 'admin'` check
- Stripe tables are service-role only (no client access)
- DMs only accessible to thread participants

---

## 📦 Edge Functions

| Function | Auth | Description |
|----------|------|-------------|
| `publish-video` | JWT | Publishes rendered videos to YouTube, TikTok, IG, FB |
| `render-video` | JWT | Renders project frames into MP4 |
| `ai-assist` | JWT | AI-powered animation suggestions (purchase-gated) |
| `stripe-webhook` | Stripe sig | Handles Stripe subscription lifecycle events |
| `create-checkout` | JWT | Creates Stripe Checkout sessions for Pro plan |
| `admin-actions` | JWT+admin | Ban users, moderate content, manage challenges |
| `social-connect` | JWT | OAuth flow for connecting social accounts |

---

## 💰 Billing

- **Free tier**: Basic studio, community access, watermarked exports, ads
- **Pro ($4.99/mo)**: Unlimited exports, no watermark, no ads, AI assistant, priority rendering
- Stripe Checkout for subscription management
- 29 Stripe sync tables for full billing state

---

## 🎯 What's Next

After initial deployment, these features are ready to wire:
1. Push notifications (expo-notifications)
2. Deep linking for shared videos
3. Admin portal (web dashboard)
4. Shopify merch integration
5. Advanced AI features (auto-tween, style transfer)
6. AR preview mode

---

*Built for Willis NMB Designs — StickDeath Infinity © 2026*
