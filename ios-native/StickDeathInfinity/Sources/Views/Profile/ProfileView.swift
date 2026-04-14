// ProfileView.swift — User profile + settings
// Pulls from users, profiles, user_stats tables
// Bold orange-on-dark theme

import SwiftUI

// MARK: - DB Models
struct UserStats: Codable {
    let user_id: String
    let followers_count: Int?
    let following_count: Int?
    let posts_count: Int?
    let projects_count: Int?
    let likes_received_count: Int?
}

// MARK: - Profile View
struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var stats: UserStats?
    @State private var isEditing = false
    @State private var editUsername = ""
    @State private var editBio = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Header area
                        profileHeader

                        // Stats
                        statsRow

                        // Actions
                        actionButtons

                        // Menu items
                        menuItems
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { settingsSheet }
            .task { await loadStats() }
        }
    }

    // MARK: - Profile Header
    var profileHeader: some View {
        VStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.orange, .red],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .shadow(color: .orange.opacity(0.3), radius: 12)

                if let url = auth.currentUser?.avatar_url, let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        avatarInitial
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                } else {
                    avatarInitial
                }
            }

            // Name + handle
            VStack(spacing: 4) {
                Text(auth.currentUser?.username?.uppercased() ?? "CREATOR")
                    .font(ThemeManager.headlineBold(size: 24))
                    .foregroundStyle(.white)

                if let email = auth.currentUser?.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.5))
                }
            }

            // Bio
            if let bio = auth.currentUser?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Tier badge
            HStack(spacing: 6) {
                Image(systemName: auth.isPro ? "crown.fill" : "person.fill")
                    .font(.caption2)
                Text(auth.isPro ? "PRO" : "FREE")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(auth.isPro ? .orange : Color(white: 0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(auth.isPro ? Color.orange.opacity(0.15) : Color(white: 0.1))
            .clipShape(Capsule())
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    var avatarInitial: some View {
        Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(.white)
    }

    // MARK: - Stats Row
    var statsRow: some View {
        HStack(spacing: 0) {
            statItem("PROJECTS", value: stats?.projects_count ?? 0)
            Divider().frame(height: 30).background(Color(white: 0.2))
            statItem("FOLLOWERS", value: stats?.followers_count ?? 0)
            Divider().frame(height: 30).background(Color(white: 0.2))
            statItem("FOLLOWING", value: stats?.following_count ?? 0)
            Divider().frame(height: 30).background(Color(white: 0.2))
            statItem("LIKES", value: stats?.likes_received_count ?? 0)
        }
        .padding(.vertical, 14)
        .background(Color(white: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    func statItem(_ label: String, value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundStyle(.orange)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(white: 0.5))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Action Buttons
    var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                editUsername = auth.currentUser?.username ?? ""
                editBio = auth.currentUser?.bio ?? ""
                isEditing = true
            } label: {
                Label("Edit Profile", systemImage: "pencil")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !auth.isPro {
                Button {} label: {
                    Label("Go Pro", systemImage: "crown.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    // MARK: - Menu Items
    var menuItems: some View {
        VStack(spacing: 0) {
            menuRow("My Animations", icon: "film", color: .orange)
            menuRow("Saved", icon: "bookmark.fill", color: .yellow)
            menuRow("Achievements", icon: "trophy.fill", color: .purple)
            menuRow("Settings", icon: "gearshape.fill", color: Color(white: 0.6)) {
                showSettings = true
            }

            Divider().background(Color(white: 0.15)).padding(.vertical, 8)

            // Logout
            Button {
                Task { await auth.logout() }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                        .frame(width: 28)
                    Text("Sign Out")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .padding(.top, 20)
    }

    func menuRow(_ title: String, icon: String, color: Color, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 28)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.3))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Settings Sheet
    var settingsSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section("Account") {
                        LabeledContent("Email", value: auth.currentUser?.email ?? "—")
                        LabeledContent("Role", value: auth.currentUser?.role ?? "user")
                        LabeledContent("Tier", value: auth.isPro ? "Pro" : "Free")
                    }
                    Section("App") {
                        Toggle("Haptic Feedback", isOn: .constant(true))
                        Toggle("Sound Effects", isOn: .constant(true))
                    }
                    Section("About") {
                        LabeledContent("Version", value: "1.0.0")
                        LabeledContent("App", value: "StickDeath Infinity")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettings = false }
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Data
    func loadStats() async {
        guard let userId = auth.session?.user.id.uuidString else { return }
        do {
            stats = try await supabase
                .from("user_stats")
                .select()
                .eq("user_id", value: userId)
                .single()
                .execute()
                .value
        } catch {
            // Stats may not exist yet — that's fine
            print("⚠️ Stats load: \(error)")
        }
    }
}
