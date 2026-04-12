// ProfileView.swift
// Fully personalized user profile — avatar editor, skill level, interests,
// achievement badges, custom theme accent, stats, help, settings
// Follows "Variable Reward" pattern — achievements unlock at unpredictable intervals

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.deviceContext) var ctx
    @State private var showEditProfile = false
    @State private var showSubscription = false
    @State private var showConnectedAccounts = false
    @State private var showHelp = false
    @State private var showAchievements = false
    @State private var showPersonalization = false

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // ── Profile Card ──
                        profileHeader
                            .frame(maxWidth: ctx.maxContentWidth)

                        // ── Quick Stats ──
                        statsRow
                            .frame(maxWidth: ctx.maxContentWidth)

                        // ── Achievement Badges (variable reward — shows progress) ──
                        achievementStrip

                        Divider().background(ThemeManager.border).padding(.horizontal)

                        // ── Settings Menu ──
                        settingsMenu
                            .frame(maxWidth: ctx.maxContentWidth)

                        Text("StickDeath Infinity v1.0")
                            .font(.caption2).foregroundStyle(.gray).padding(.top, 8)
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showEditProfile) { EditProfileSheet() }
            .sheet(isPresented: $showSubscription) { SubscriptionView() }
            .sheet(isPresented: $showConnectedAccounts) { ConnectedAccountsView() }
            .sheet(isPresented: $showHelp) { HelpCenterView() }
            .sheet(isPresented: $showAchievements) { AchievementsView() }
            .sheet(isPresented: $showPersonalization) { PersonalizationSheet() }
        }
    }

    // MARK: - Profile Header
    var profileHeader: some View {
        VStack(spacing: 14) {
            // Avatar with edit button
            ZStack(alignment: .bottomTrailing) {
                if let url = auth.currentUser?.avatar_url, !url.isEmpty {
                    AsyncImage(url: URL(string: url)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        avatarPlaceholder
                    }
                    .frame(width: 90, height: 90)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder
                }

                Button { showEditProfile = true } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .background(Circle().fill(ThemeManager.background).frame(width: 26, height: 26))
                }
            }

            // Name + bio
            Text(auth.currentUser?.username ?? "User")
                .font(.title2.bold())

            if let bio = auth.currentUser?.bio, !bio.isEmpty {
                Text(bio).font(.subheadline).foregroundStyle(.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }

            // Skill level badge
            if let skill = auth.currentUser?.skill_level {
                HStack(spacing: 6) {
                    Image(systemName: skillIcon(skill))
                        .font(.caption2)
                    Text(skill.capitalized)
                        .font(.caption.bold())
                }
                .foregroundStyle(skillColor(skill))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(skillColor(skill).opacity(0.15))
                .clipShape(Capsule())
            }

            // Subscription badge
            HStack(spacing: 8) {
                if auth.isPro {
                    Label("PRO", systemImage: "star.fill")
                        .font(.caption.bold()).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.orange).clipShape(Capsule())
                } else {
                    Button { showSubscription = true } label: {
                        Label("Upgrade to Pro", systemImage: "star")
                            .font(.caption.bold()).foregroundStyle(.orange)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(.orange.opacity(0.15)).clipShape(Capsule())
                    }
                }

                // Interest tags
                if let interests = auth.currentUser?.interests, !interests.isEmpty {
                    ForEach(interests.prefix(3), id: \.self) { interest in
                        Text(interest)
                            .font(.system(size: 10)).foregroundStyle(.gray)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(ThemeManager.surface).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.top, 20)
    }

    var avatarPlaceholder: some View {
        Circle()
            .fill(LinearGradient(colors: [.orange.opacity(0.4), .red.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 90, height: 90)
            .overlay(
                Text(String(auth.currentUser?.username?.prefix(1) ?? "?").uppercased())
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    // MARK: - Stats
    var statsRow: some View {
        HStack(spacing: 0) {
            StatItem(value: "0", label: "Animations", icon: "film")
            Divider().frame(height: 32).background(ThemeManager.border)
            StatItem(value: "0", label: "Views", icon: "eye")
            Divider().frame(height: 32).background(ThemeManager.border)
            StatItem(value: "0", label: "Likes", icon: "heart")
            Divider().frame(height: 32).background(ThemeManager.border)
            StatItem(value: "0", label: "Streak", icon: "flame")
        }
        .padding(.vertical, 12)
        .background(ThemeManager.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    // MARK: - Achievement Strip (horizontal scroll — variable rewards)
    var achievementStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Achievements").font(.subheadline.bold())
                Spacer()
                Button("See All") { showAchievements = true }
                    .font(.caption).foregroundStyle(.orange)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Achievement.all.prefix(6)) { badge in
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(badge.unlocked ? badge.color.opacity(0.2) : ThemeManager.surface)
                                    .frame(width: 50, height: 50)
                                Image(systemName: badge.icon)
                                    .font(.title3)
                                    .foregroundStyle(badge.unlocked ? badge.color : .gray.opacity(0.4))
                            }
                            Text(badge.title)
                                .font(.system(size: 9)).foregroundStyle(.gray)
                                .lineLimit(1)
                        }
                        .frame(width: 60)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Settings Menu
    var settingsMenu: some View {
        VStack(spacing: 2) {
            SettingsRow(icon: "person.circle", title: "Edit Profile") { showEditProfile = true }
            SettingsRow(icon: "paintpalette.fill", title: "Personalization", tint: .purple) { showPersonalization = true }
            SettingsRow(icon: "star.circle", title: "Subscription") { showSubscription = true }
            SettingsRow(icon: "link.circle", title: "Connected Accounts") { showConnectedAccounts = true }
            SettingsRow(icon: "trophy.circle", title: "Achievements", tint: .yellow) { showAchievements = true }
            SettingsRow(icon: "questionmark.circle", title: "Help & Instructions", tint: .cyan) { showHelp = true }
            SettingsRow(icon: "play.circle", title: "Replay Tutorial", tint: .green) {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                NotificationCenter.default.post(name: .replayOnboarding, object: nil)
            }
            if auth.isAdmin {
                SettingsRow(icon: "shield.checkered", title: "Admin Portal", tint: .purple) {}
            }
            Button {
                Task { await auth.logout() }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right").foregroundStyle(.red).frame(width: 24)
                    Text("Sign Out").foregroundStyle(.red)
                    Spacer()
                }
                .padding()
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Helpers
    func skillIcon(_ level: String) -> String {
        switch level {
        case "beginner": return "star"
        case "intermediate": return "star.leadinghalf.filled"
        case "advanced": return "star.fill"
        default: return "star"
        }
    }

    func skillColor(_ level: String) -> Color {
        switch level {
        case "beginner": return .green
        case "intermediate": return .orange
        case "advanced": return .red
        default: return .gray
        }
    }
}

// MARK: - Notification for replaying onboarding
extension Notification.Name {
    static let replayOnboarding = Notification.Name("replayOnboarding")
}

struct StatItem: View {
    let value: String
    let label: String
    var icon: String = ""

    var body: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty {
                Image(systemName: icon).font(.caption2).foregroundStyle(.orange)
            }
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    var tint: Color = .orange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
                Text(title).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.gray)
            }
            .padding()
            .background(ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Personalization Sheet
struct PersonalizationSheet: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var skillLevel = "beginner"
    @State private var selectedInterests: Set<String> = []
    @State private var accentHex = "#FF6600"
    @State private var preferredFPS = 24
    @State private var canvasPreference = "landscape"
    @State private var saving = false

    let allInterests = ["Action", "Comedy", "Sci-Fi", "Horror", "Drama", "Music", "Sports", "Fantasy", "Anime", "Memes", "Tutorial", "Story"]
    let skillLevels = ["beginner", "intermediate", "advanced"]
    let fpsOptions = [12, 24, 30, 60]
    let canvasOptions = [("portrait", "rectangle.portrait"), ("landscape", "rectangle"), ("square", "square")]

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Skill Level
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Skill Level").font(.subheadline.bold())
                            HStack(spacing: 8) {
                                ForEach(skillLevels, id: \.self) { level in
                                    Button {
                                        skillLevel = level
                                    } label: {
                                        Text(level.capitalized)
                                            .font(.caption.bold())
                                            .foregroundStyle(skillLevel == level ? .black : .white)
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(skillLevel == level ? .orange : ThemeManager.surface)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }

                        // Interests (multi-select chips)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your Interests").font(.subheadline.bold())
                            Text("We'll personalize your feed and templates").font(.caption).foregroundStyle(.gray)
                            FlowLayout(spacing: 8) {
                                ForEach(allInterests, id: \.self) { interest in
                                    Button {
                                        if selectedInterests.contains(interest) {
                                            selectedInterests.remove(interest)
                                        } else {
                                            selectedInterests.insert(interest)
                                        }
                                    } label: {
                                        Text(interest)
                                            .font(.caption.bold())
                                            .foregroundStyle(selectedInterests.contains(interest) ? .black : .white)
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(selectedInterests.contains(interest) ? .orange : ThemeManager.surface)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }

                        // Default FPS
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Default Frame Rate").font(.subheadline.bold())
                            HStack(spacing: 8) {
                                ForEach(fpsOptions, id: \.self) { fps in
                                    Button {
                                        preferredFPS = fps
                                    } label: {
                                        Text("\(fps) fps")
                                            .font(.caption.bold())
                                            .foregroundStyle(preferredFPS == fps ? .black : .white)
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(preferredFPS == fps ? .orange : ThemeManager.surface)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }

                        // Canvas Orientation
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Default Canvas").font(.subheadline.bold())
                            HStack(spacing: 12) {
                                ForEach(canvasOptions, id: \.0) { option in
                                    Button {
                                        canvasPreference = option.0
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: option.1)
                                                .font(.title2)
                                            Text(option.0.capitalized)
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(canvasPreference == option.0 ? .orange : .gray)
                                        .frame(width: 70, height: 60)
                                        .background(canvasPreference == option.0 ? .orange.opacity(0.15) : ThemeManager.surface)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Personalization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }.disabled(saving)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    func loadExisting() {
        skillLevel = auth.currentUser?.skill_level ?? "beginner"
        selectedInterests = Set(auth.currentUser?.interests ?? [])
        accentHex = auth.currentUser?.theme_accent ?? "#FF6600"
        preferredFPS = auth.currentUser?.preferred_fps ?? 24
        canvasPreference = auth.currentUser?.preferred_canvas ?? "landscape"
    }

    func save() async {
        saving = true
        // Save to Supabase user_preferences
        try? await auth.updateProfile(username: nil, bio: nil, avatarURL: nil)
        // Additional preferences update
        guard let userId = auth.session?.user.id else { saving = false; return }
        try? await supabase.from("users").update([
            "skill_level": skillLevel,
            "interests": selectedInterests.sorted().joined(separator: ","),
            "theme_accent": accentHex,
            "preferred_fps": "\(preferredFPS)",
            "preferred_canvas": canvasPreference
        ]).eq("id", value: userId.uuidString).execute()
        await auth.fetchProfile()
        saving = false
        dismiss()
    }
}

// MARK: - Flow Layout (wrapping chips)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Achievements View
struct AchievementsView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Achievement.all) { badge in
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(badge.unlocked ? badge.color.opacity(0.2) : ThemeManager.surface)
                                        .frame(width: 50, height: 50)
                                    Image(systemName: badge.icon)
                                        .font(.title2)
                                        .foregroundStyle(badge.unlocked ? badge.color : .gray.opacity(0.3))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(badge.title).font(.subheadline.bold())
                                    Text(badge.description).font(.caption).foregroundStyle(.gray)
                                    // Progress bar
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(ThemeManager.surface)
                                                .frame(height: 4)
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(badge.color)
                                                .frame(width: geo.size.width * badge.progress, height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                }

                                Spacer()

                                if badge.unlocked {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(badge.color)
                                }
                            }
                            .padding(14)
                            .background(ThemeManager.surfaceLight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Achievements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Edit Profile Sheet (v3: avatar picker, bio, username)
struct EditProfileSheet: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var username = ""
    @State private var bio = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        // Avatar picker
                        ZStack(alignment: .bottomTrailing) {
                            Circle()
                                .fill(LinearGradient(colors: [.orange.opacity(0.4), .red.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 100, height: 100)
                                .overlay(
                                    Text(String(username.prefix(1)).uppercased())
                                        .font(.system(size: 40, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                            Image(systemName: "camera.circle.fill")
                                .font(.title2).foregroundStyle(.orange)
                        }
                        .padding(.top, 20)

                        VStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Username").font(.caption.bold()).foregroundStyle(.gray)
                                TextField("Username", text: $username)
                                    .textFieldStyle(.plain).padding().background(ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12)).autocapitalization(.none)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bio").font(.caption.bold()).foregroundStyle(.gray)
                                TextEditor(text: $bio)
                                    .frame(height: 80).scrollContentBackground(.hidden)
                                    .padding(8).background(ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
            .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            try? await auth.updateProfile(username: username, bio: bio)
                            saving = false
                            dismiss()
                        }
                    }.disabled(saving)
                }
            }
            .onAppear {
                username = auth.currentUser?.username ?? ""
                bio = auth.currentUser?.bio ?? ""
            }
        }
    }
}

// MARK: - Subscription View
struct SubscriptionView: View {
    @Environment(\.dismiss) var dismiss
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "star.fill").font(.system(size: 56)).foregroundStyle(.orange)
                    Text("StickDeath Pro").font(.title.bold())
                    VStack(alignment: .leading, spacing: 12) {
                        ProFeature(text: "AI Animation Assistant")
                        ProFeature(text: "Unlimited Projects")
                        ProFeature(text: "HD Export (1080p+)")
                        ProFeature(text: "Custom Stick Figures")
                        ProFeature(text: "Priority Publishing")
                        ProFeature(text: "Remove Watermark (personal exports)")
                        ProFeature(text: "Premium Templates & Assets")
                    }
                    Text("$4.99 / month").font(.title2.bold()).foregroundStyle(.orange)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button {
                        Task { await subscribe() }
                    } label: {
                        if loading { ProgressView().tint(.black) }
                        else { Text("Subscribe Now").font(.headline).foregroundStyle(.black) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16).background(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 40)
                    Text("Cancel anytime. Billed monthly through Stripe.")
                        .font(.caption2).foregroundStyle(.gray)
                }
                .padding()
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    func subscribe() async {
        loading = true; error = nil
        do {
            let checkoutURL = try await StripeService.shared.createCheckoutSession()
            await MainActor.run { UIApplication.shared.open(checkoutURL) }
            dismiss()
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct ProFeature: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.subheadline)
        }
    }
}
