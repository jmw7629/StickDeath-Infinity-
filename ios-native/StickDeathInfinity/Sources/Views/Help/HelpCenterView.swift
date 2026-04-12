// HelpCenterView.swift
// Permanent in-app help & instructions — always accessible from Profile

import SwiftUI

// MARK: - Help Data
struct HelpSection: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let color: Color
    let articles: [HelpArticle]
}

struct HelpArticle: Identifiable {
    let id = UUID()
    let title: String
    let steps: [String]
    let tip: String?
}

struct HelpCenterView: View {
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var expandedSection: UUID?

    private let sections: [HelpSection] = [
        HelpSection(
            icon: "hand.draw.fill",
            title: "Getting Started",
            color: .orange,
            articles: [
                HelpArticle(
                    title: "Creating your first animation",
                    steps: [
                        "Tap the Studio tab (pencil icon) at the bottom",
                        "Tap '+' to create a new project — give it a name",
                        "You'll see a stick figure on the canvas",
                        "Drag any joint (the circles) to pose the figure",
                        "Tap '+' on the timeline to add a new frame",
                        "Pose the figure differently in the new frame",
                        "Hit ▶ Play to see your animation!"
                    ],
                    tip: "Start simple — a 5-frame walk cycle is a great first project."
                ),
                HelpArticle(
                    title: "Understanding the workspace",
                    steps: [
                        "Canvas — the large area where your animation plays",
                        "Toolbar — floating bar at top with mode buttons",
                        "Timeline — bottom strip showing all your frames",
                        "Layers panel — slide from left to manage figures",
                        "Properties panel — slide from right to adjust settings"
                    ],
                    tip: "All panels slide away to maximize canvas space. Swipe to reveal them."
                ),
                HelpArticle(
                    title: "Saving your work",
                    steps: [
                        "Your project auto-saves to the cloud periodically",
                        "Tap the save icon (↓) in the toolbar to save manually",
                        "All saves go to your Supabase account — nothing is lost",
                        "You can open any project from the Gallery"
                    ],
                    tip: nil
                ),
            ]
        ),
        HelpSection(
            icon: "figure.walk",
            title: "Animation Studio",
            color: .cyan,
            articles: [
                HelpArticle(
                    title: "Pose mode",
                    steps: [
                        "Pose mode lets you move individual joints",
                        "Tap a joint (circle) to select it — it turns orange",
                        "Drag it to reposition — connected bones move naturally",
                        "Each frame stores a unique pose for each figure",
                        "Create smooth motion by making small changes per frame"
                    ],
                    tip: "Hold on a joint for 0.5s to lock it in place (prevents accidental moves)."
                ),
                HelpArticle(
                    title: "Draw mode",
                    steps: [
                        "Draw mode lets you sketch freehand on the canvas",
                        "Use it for backgrounds, effects, weapons, props",
                        "Choose color and brush size in the Properties panel",
                        "Drawings are per-frame — great for impact effects",
                        "Use the eraser tool to clean up"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Move mode",
                    steps: [
                        "Move mode lets you pan and zoom the canvas",
                        "Drag to pan, pinch to zoom",
                        "Double-tap to reset the view to default",
                        "Use this to focus on details in large scenes"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Working with the timeline",
                    steps: [
                        "The timeline shows thumbnails of each frame",
                        "Tap a frame to jump to it",
                        "'+' adds a new frame after the current one",
                        "'⧉' duplicates the current frame (great for small tweaks)",
                        "'🗑' deletes the current frame",
                        "Drag frames to reorder them",
                        "▶ Play previews the full animation"
                    ],
                    tip: "Turn on Onion Skin (the ghost icon) to see the previous frame while posing. Essential for smooth animation."
                ),
                HelpArticle(
                    title: "Adding multiple figures",
                    steps: [
                        "Open the Layers panel (swipe from left edge)",
                        "Tap 'Add Figure' to create a new stick figure",
                        "Each figure has its own color and layer",
                        "Tap a figure in the list to select it for editing",
                        "Use the eye icon to show/hide figures per frame",
                        "Great for fight scenes and group animations"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Onion skinning",
                    steps: [
                        "Onion skinning shows a ghost of nearby frames",
                        "Toggle it with the onion icon in the toolbar",
                        "Previous frame shows in faded blue",
                        "This helps you see the motion between poses",
                        "Essential for smooth, professional animation"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Undo and Redo",
                    steps: [
                        "Tap ↩ to undo your last action (up to 50 steps)",
                        "Tap ↪ to redo",
                        "Works for poses, frame changes, adding/deleting figures",
                        "Full history is kept until you close the project"
                    ],
                    tip: nil
                ),
            ]
        ),
        HelpSection(
            icon: "sparkles",
            title: "AI Assistant (Pro)",
            color: .purple,
            articles: [
                HelpArticle(
                    title: "Using AI to create animations",
                    steps: [
                        "Tap the ✨ sparkle icon in the toolbar",
                        "Type what you want: 'walking cycle', 'fight scene', 'dance move'",
                        "AI generates a suggestion — tap Apply to use it",
                        "You can modify the AI's output manually after applying",
                        "AI understands your current frame count and figure setup"
                    ],
                    tip: "Be specific: 'a 12-frame running cycle with arms pumping' works better than just 'run'."
                ),
                HelpArticle(
                    title: "Suggested prompts",
                    steps: [
                        "The AI panel shows common prompts to get you started",
                        "'Walking Cycle' — smooth 8-frame walk",
                        "'Fight Scene' — dynamic action sequence",
                        "'Dance Move' — fun animated dance",
                        "'Jump' — complete jump arc with squash/stretch"
                    ],
                    tip: "AI assist requires a Pro subscription ($4.99/month)."
                ),
            ]
        ),
        HelpSection(
            icon: "paperplane.fill",
            title: "Publishing",
            color: .green,
            articles: [
                HelpArticle(
                    title: "How publishing works",
                    steps: [
                        "Tap Publish in the toolbar when your animation is ready",
                        "Give it a title — this appears on all platforms",
                        "Your video always uploads to StickDeath official channels",
                        "You can also upload to your own connected accounts",
                        "The server renders your frames into a video file",
                        "Then it distributes to all selected platforms"
                    ],
                    tip: "All published videos help build the StickDeath community and generate ad revenue."
                ),
                HelpArticle(
                    title: "StickDeath official channels",
                    steps: [
                        "TikTok — @stickdeathinfinity",
                        "YouTube — @stickdeath.infinity",
                        "Discord — StickDeath_Infinity",
                        "Instagram — @stickdeathinfinity",
                        "Facebook — StickDeath Infinity",
                        "All user videos go to these channels automatically",
                        "This is how the community grows and earns together"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Publishing to your own accounts",
                    steps: [
                        "Go to Profile → Connected Accounts",
                        "Tap 'Connect' next to any platform",
                        "Sign in to your account when prompted",
                        "When publishing, toggle 'Also upload to my channels'",
                        "Your video posts to both StickDeath and your channels"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Video watermark",
                    steps: [
                        "All free user videos include a 'StickDeath ∞' watermark",
                        "This appears in the bottom-right corner of the video",
                        "Pro users can remove the watermark on personal exports",
                        "Videos uploaded to StickDeath channels always have the watermark",
                        "This helps brand awareness across platforms"
                    ],
                    tip: nil
                ),
            ]
        ),
        HelpSection(
            icon: "star.fill",
            title: "Pro Subscription",
            color: .yellow,
            articles: [
                HelpArticle(
                    title: "What's included in Pro",
                    steps: [
                        "AI Animation Assistant — generate poses and scenes",
                        "Unlimited projects (free tier: 3 projects)",
                        "HD video export (1080p, 60fps)",
                        "Custom stick figure skins and colors",
                        "Remove watermark on personal exports",
                        "Priority publishing (your videos process first)",
                        "Priority support"
                    ],
                    tip: "Pro is $4.99/month, cancel anytime."
                ),
                HelpArticle(
                    title: "How to subscribe",
                    steps: [
                        "Go to Profile → tap 'Upgrade to Pro'",
                        "Review the features list",
                        "Tap 'Subscribe Now'",
                        "You'll be taken to a secure Stripe checkout",
                        "Enter your payment info and confirm",
                        "Pro features activate immediately"
                    ],
                    tip: nil
                ),
            ]
        ),
        HelpSection(
            icon: "person.circle",
            title: "Account & Profile",
            color: .blue,
            articles: [
                HelpArticle(
                    title: "Editing your profile",
                    steps: [
                        "Go to the Profile tab",
                        "Tap 'Edit Profile'",
                        "Change your username, bio, or avatar",
                        "Tap 'Save' when done"
                    ],
                    tip: nil
                ),
                HelpArticle(
                    title: "Connecting social accounts",
                    steps: [
                        "Go to Profile → Connected Accounts",
                        "Tap 'Connect' next to any platform",
                        "Sign in with your platform credentials",
                        "Once connected, you can publish to that account",
                        "Tap 'Disconnect' to remove access"
                    ],
                    tip: nil
                ),
            ]
        ),
    ]

    var filteredSections: [HelpSection] {
        if searchText.isEmpty { return sections }
        return sections.compactMap { section in
            let filteredArticles = section.articles.filter { article in
                article.title.localizedCaseInsensitiveContains(searchText) ||
                article.steps.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            guard !filteredArticles.isEmpty else { return nil }
            return HelpSection(icon: section.icon, title: section.title, color: section.color, articles: filteredArticles)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Search
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.gray)
                            TextField("Search help articles...", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(12)
                        .background(ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)

                        // Quick actions
                        HStack(spacing: 12) {
                            QuickHelpButton(icon: "play.fill", label: "Watch\nTutorial", color: .orange) {
                                // Replay onboarding
                                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                            }
                            QuickHelpButton(icon: "envelope.fill", label: "Contact\nSupport", color: .blue) {}
                            QuickHelpButton(icon: "bubble.left.fill", label: "Community\nDiscord", color: Color(hex: "#5865F2")) {}
                        }
                        .padding(.horizontal)

                        // Sections
                        ForEach(filteredSections) { section in
                            VStack(alignment: .leading, spacing: 0) {
                                // Section header
                                Button {
                                    withAnimation(.spring(response: 0.3)) {
                                        expandedSection = expandedSection == section.id ? nil : section.id
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: section.icon)
                                            .font(.title3)
                                            .foregroundStyle(section.color)
                                            .frame(width: 36, height: 36)
                                            .background(section.color.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))

                                        VStack(alignment: .leading) {
                                            Text(section.title)
                                                .font(.headline)
                                            Text("\(section.articles.count) articles")
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }

                                        Spacer()

                                        Image(systemName: expandedSection == section.id ? "chevron.up" : "chevron.down")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                    .padding(16)
                                }

                                // Articles (expanded)
                                if expandedSection == section.id {
                                    ForEach(section.articles) { article in
                                        NavigationLink {
                                            HelpArticleDetail(article: article, sectionColor: section.color)
                                        } label: {
                                            HStack {
                                                Text(article.title)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.white.opacity(0.8))
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(.gray)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(ThemeManager.surfaceLight.opacity(0.5))
                                        }
                                    }
                                }
                            }
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal)
                        }

                        // App version
                        Text("StickDeath Infinity v1.0 — Made with ❤️")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                            .padding(.top, 20)
                    }
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Help Center")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Article Detail
struct HelpArticleDetail: View {
    let article: HelpArticle
    let sectionColor: Color

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(article.title)
                        .font(.title2.bold())
                        .padding(.bottom, 4)

                    ForEach(Array(article.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.black)
                                .frame(width: 24, height: 24)
                                .background(sectionColor)
                                .clipShape(Circle())

                            Text(step)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }

                    if let tip = article.tip {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(.yellow)
                            Text(tip)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(14)
                        .background(Color.yellow.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.top, 8)
                    }
                }
                .padding(24)
            }
        }
    }
}

// MARK: - Quick Help Button
struct QuickHelpButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
