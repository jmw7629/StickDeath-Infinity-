# StickDeath Infinity — Xcode Project (Native Swift)

## Quick Start — Open in Xcode in 2 minutes

### Step 1: Open the project
1. Open Xcode
2. Go to **File → Open** (or ⌘O)
3. Navigate to this folder and select the `StickDeathInfinity` folder
4. Xcode will detect `Package.swift` and load it as a Swift Package project

### Step 2: Wait for packages
- Xcode will automatically download **Supabase Swift SDK** and **Stripe iOS SDK**
- This takes 1–2 minutes the first time (you'll see a loading indicator at the top)

### Step 3: Set your team
1. Click the project name in the left sidebar
2. Go to **Signing & Capabilities** tab
3. Select your **Team** from the dropdown
4. Set **Bundle Identifier** to: `com.stickdeath.infinity`

### Step 4: Run it
1. Select an iPhone simulator (iPhone 15 Pro recommended)
2. Click the **▶ Run** button (or ⌘R)
3. The app will build and launch in the simulator

---

## What's In This Project

```
StickDeathInfinity/
├── Package.swift              ← SPM dependencies (Supabase + Stripe)
├── Sources/
│   ├── App/
│   │   ├── StickDeathInfinityApp.swift  ← Entry point
│   │   ├── RootView.swift               ← Auth/main routing
│   │   ├── MainTabView.swift            ← 4-tab navigation
│   │   └── ThemeManager.swift           ← Dark theme colors
│   ├── Models/
│   │   └── Models.swift                 ← All data models
│   ├── Services/
│   │   ├── SupabaseClient.swift         ← Live Supabase connection
│   │   ├── AuthManager.swift            ← Sign up/login/logout/session
│   │   ├── ProjectService.swift         ← Create/save/load/publish projects
│   │   ├── StripeService.swift          ← Pro subscription checkout
│   │   ├── AIService.swift              ← AI assistant (Pro only)
│   │   └── PublishService.swift         ← Render + publish to social
│   └── Views/
│       ├── Auth/
│       │   ├── WelcomeView.swift        ← Landing screen
│       │   ├── LoginView.swift          ← Email/password login
│       │   └── SignUpView.swift         ← Registration + terms
│       ├── Studio/
│       │   ├── ProjectsGalleryView.swift ← Project list grid
│       │   ├── StudioView.swift         ← Full-screen animation editor
│       │   ├── CanvasView.swift         ← Canvas + stick figure renderer
│       │   ├── EditorViewModel.swift    ← Editor logic + undo/redo
│       │   ├── TimelinePanel.swift      ← Frame timeline + playback
│       │   ├── LayersPanel.swift        ← Figure layers management
│       │   ├── PropertiesPanel.swift    ← Figure/canvas properties
│       │   ├── AIAssistPanel.swift      ← AI suggestions (Pro)
│       │   └── PublishSheet.swift       ← Publish to social platforms
│       ├── Feed/
│       │   └── FeedView.swift           ← Community animation feed
│       ├── Messages/
│       │   └── MessagesListView.swift   ← DM conversations + chat
│       └── Profile/
│           └── ProfileView.swift        ← Settings, subscription, logout
└── Assets.xcassets/                     ← App icon + accent color
```

## Connected to Live Backend

This app is pre-configured to talk to your live Supabase project:
- ✅ Database (48 tables)
- ✅ Authentication (email/password)
- ✅ Edge Functions (AI, payments, publishing)
- ✅ Storage (avatars, projects, renders)
- ✅ Stripe ($4.99/mo Pro subscription)

No additional configuration needed — just build and run.

## For TestFlight / App Store

1. In Xcode: **Product → Archive**
2. Once archived, click **Distribute App**
3. Choose **App Store Connect** → Upload
4. Go to [App Store Connect](https://appstoreconnect.apple.com) to submit for review

## Requirements
- Xcode 15+
- iOS 16+ target
- Apple Developer Account (for device testing / TestFlight)
