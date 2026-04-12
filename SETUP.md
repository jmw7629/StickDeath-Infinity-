# StickDeath Infinity — Setup & Deploy Guide

## Prerequisites
- Node.js 18+ 
- Expo CLI: `npm install -g eas-cli expo-cli`
- Xcode 15+ (for iOS simulator)
- Apple Developer Account (for TestFlight)

---

## 1. Clone & Install

```bash
git clone https://github.com/jmw7629/StickDeath-Infinity-.git
cd StickDeath-Infinity-
```

### Mobile App
```bash
cd app
npm install
```

Create `app/.env`:
```
EXPO_PUBLIC_SUPABASE_URL=https://iohubnamsqnzyburydxr.supabase.co
EXPO_PUBLIC_SUPABASE_ANON_KEY=sb_publishable_wYHTtPsLEEXP9tFuzoeRQw_j6UuoJWl
```

### Admin Portal
```bash
cd admin-portal
npm install
```

Create `admin-portal/.env`:
```
VITE_SUPABASE_URL=https://iohubnamsqnzyburydxr.supabase.co
VITE_SUPABASE_ANON_KEY=sb_publishable_wYHTtPsLEEXP9tFuzoeRQw_j6UuoJWl
VITE_SUPABASE_SERVICE_ROLE_KEY=<your service role key>
```

---

## 2. Run Locally

### Mobile App (iOS Simulator)
```bash
cd app
npx expo start --ios
```

### Admin Portal
```bash
cd admin-portal
npm run dev
# Opens at http://localhost:3001
```

---

## 3. Build for TestFlight

### One-time EAS setup
```bash
cd app
eas login                    # Log into your Expo account
eas build:configure          # Links to EAS project
```

### Update `eas.json`
Replace `APPLE_ID_HERE`, `ASC_APP_ID_HERE`, `TEAM_ID_HERE` with your Apple Developer credentials.

### Build & Submit
```bash
# Development build (simulator)
eas build --platform ios --profile development

# TestFlight build
eas build --platform ios --profile production

# Submit to TestFlight
eas submit --platform ios --profile production
```

---

## 4. Deploy Admin Portal (Vercel)

```bash
cd admin-portal
npm install -g vercel
vercel
# Follow prompts, set environment variables in Vercel dashboard
```

---

## 5. Apple/Google Auth (Optional)

### Apple Sign-In
1. Apple Developer Console → Certificates, Identifiers & Profiles
2. Register App ID with "Sign In with Apple" capability
3. Create Service ID for web
4. Add to Supabase: Dashboard → Auth → Providers → Apple

### Google Sign-In
1. Google Cloud Console → Create OAuth 2.0 credentials
2. Add iOS bundle ID: `com.stickdeath.infinity`
3. Add to Supabase: Dashboard → Auth → Providers → Google

---

## Architecture

```
stickdeath-infinity/
├── app/                    # React Native (Expo) mobile app
│   ├── app/                # Expo Router screens
│   └── src/                # Components, hooks, models, theme
├── admin-portal/           # Vite + React admin dashboard
├── supabase/
│   ├── migrations/         # 11 SQL migration files
│   ├── functions/          # 7 Edge Functions (deployed)
│   └── seed.sql
└── scripts/                # Deploy helpers
```

## Live Infrastructure
- **Supabase**: 48 tables, 7 edge functions, 4 storage buckets
- **Stripe**: Pro subscription ($4.99/mo), webhook active
- **GitHub**: github.com/jmw7629/StickDeath-Infinity-
