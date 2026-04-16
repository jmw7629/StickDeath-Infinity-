// ProfileView.swift
// Layer 1 ROOT — Profile tab
//
// Why is the user here?  → View identity, settings, notifications, messages
// Next action?           → Check notifications, read messages, edit profile
// Back?                  → Tab root (this IS the root)
// Forward?               → Notifications (push), Messages (push), Settings (push)
//
// RULE: Context screens (Notifications, Messages) are pushed via NavigationLink
//       so back retraces the exact path. Action screens (Edit Profile, Subscription)
//       use sheets because they're temporary and return to Profile.
//
// Flow: Profile → Notifications → Notification → Content → Back → Back → Profile

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.deviceContext) var ctx

    // Sheets (Layer 3 — action screens that close, not navigate)
    @State private var showEditProfile = false
    @State private var showSubscription = false

    // Badge counts
    @State private var unreadNotifications = 0
    @State private var unreadMessages = 0

    var body: some View {
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

                    // ── Achievement Badges ──
                    achievementStrip

                    Divider().background(ThemeManager.border).padding(.horizontal)

                    // ── Navigation Menu (Layer 2 context pushes + Layer 3 sheets) ──
                    navigationMenu
                        .frame(maxWidth: ctx.maxContentWidth)

                    Text("StickDeath Infinity v1.0")
                        .font(.caption2).foregroundStyle(.gray).padding(.top, 8)
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.openSpatter(context: .profile)
                } label: {
                    Image(systemName: "sparkles").foregroundStyle(.red)
                }
            }
        }
        // Layer 3 sheets — close on dismiss, never navigate
        .sheet(isPresented: $showEditProfile) { EditProfileSheet() }
        .sheet(isPresented: $showSubscription) { SubscriptionView() }
        .task { await loadBadgeCounts() }
    }

    // MARK: - Profile Header
    var profileHeader: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                if let url = auth.currentUser?.avatar_url, !url.isEmpty {
                    AsyncImage(url: URL(string: url)) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { avatarPlaceholder }
                    .frame(width: 90, height: 90)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder
                }

                Button { showEditProfile = true } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.title3).foregroundStyle(.red)
                        .background(Circle().fill(ThemeManager.background).frame(width: 26, height: 26))
                }
            }

            Text(auth.currentUser?.username ?? "User").font(.title2.bold())

            if let bio = auth.currentUser?.bio, !bio.isEmpty {
                Text(bio).font(.subheadline).foregroundStyle(.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }

            if let skill = auth.currentUser?.skill_level {
                HStack(spacing: 6) {
                    Image(systemName: skillIcon(skill)).font(.caption2)
                    Text(skill.capitalized).font(.caption.bold())
                }
                .foregroundStyle(skillColor(skill))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(skillColor(skill).opacity(0.15))
                .clipShape(Capsule())
            }

            HStack(spacing: 8) {
                if auth.isPro {
                    Label("PRO", systemImage: "star.fill")
                        .font(.caption.bold()).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(.red).clipShape(Capsule())
                } else {
                    Button { showSubscription = true } label: {
                        Label("Upgrade to Pro", systemImage: "star")
                            .font(.caption.bold()).foregroundStyle(.red)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(.red.opacity(0.15)).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.top, 20)
    }

    var avatarPlaceholder: some View {
        Circle()
            .fill(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 90, height: 90)
            .overlay(
                Text(String(auth.currentUser?.username?.prefix(1) ?? "?").uppercased())
                    .font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
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

    // MARK: - Achievement Strip
    var achievementStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Achievements").font(.subheadline.bold())
                Spacer()
                Button("See All") {
                    router.profilePath.append(ProfileDestination.achievements)
                }
                .font(.caption).foregroundStyle(.red)
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

    // MARK: - Navigation Menu
    // Context screens → NavigationLink (push, back retraces)
    // Action screens → sheet (close, return here)
    var navigationMenu: some View {
        VStack(spacing: 2) {
            // ── Context pushes (Layer 2 — stay in Profile tab) ──
            NavMenuRow(icon: "bell.fill", title: "Notifications", tint: .yellow,
                       badge: unreadNotifications) {
                router.profilePath.append(ProfileDestination.notifications)
            }

            NavMenuRow(icon: "bubble.left.and.bubble.right.fill", title: "Messages", tint: .cyan,
                       badge: unreadMessages) {
                router.profilePath.append(ProfileDestination.messages)
            }

            Divider().background(ThemeManager.border).padding(.vertical, 4).padding(.horizontal)

            // ── Action sheets (Layer 3 — close, return here) ──
            NavMenuRow(icon: "person.circle", title: "Edit Profile") {
                showEditProfile = true
            }

            NavMenuRow(icon: "paintpalette.fill", title: "Personalization", tint: .purple) {
                router.profilePath.append(ProfileDestination.personalization)
            }

            NavMenuRow(icon: "star.circle", title: "Subscription") {
                showSubscription = true
            }

            NavMenuRow(icon: "link.circle", title: "Connected Accounts") {
                router.profilePath.append(ProfileDestination.connectedAccounts)
            }

            NavMenuRow(icon: "trophy.circle", title: "Achievements", tint: .yellow) {
                router.profilePath.append(ProfileDestination.achievements)
            }

            NavMenuRow(icon: "gift.circle", title: "Invite Friends", tint: .green) {
                router.profilePath.append(ProfileDestination.referral)
            }

            NavMenuRow(icon: "gearshape.fill", title: "App Settings", tint: .gray) {
                router.profilePath.append(ProfileDestination.appSettings)
            }

            NavMenuRow(icon: "info.circle", title: "About", tint: .gray) {
                router.profilePath.append(ProfileDestination.about)
            }

            NavMenuRow(icon: "questionmark.circle", title: "Help & Instructions", tint: .cyan) {
                router.profilePath.append(ProfileDestination.help)
            }

            NavMenuRow(icon: "play.circle", title: "Replay Tutorial", tint: .green) {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                NotificationCenter.default.post(name: .replayOnboarding, object: nil)
            }

            if auth.isAdmin {
                NavMenuRow(icon: "shield.checkered", title: "Admin Portal", tint: .purple) {}
            }

            // Sign out
            Button {
                Task { await auth.logout() }
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red).frame(width: 24)
                    Text("Sign Out").foregroundStyle(.red)
                    Spacer()
                }
                .padding()
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Badge Counts
    func loadBadgeCounts() async {
        guard let userId = auth.session?.user.id else { return }
        let unread: [AppNotification] = (try? await supabase
            .from("notifications").select()
            .eq("user_id", value: userId.uuidString)
            .eq("read", value: false)
            .execute().value) ?? []
        unreadNotifications = unread.count
    }

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
        case "intermediate": return .red
        case "advanced": return .red
        default: return .gray
        }
    }
}

// MARK: - Nav Menu Row (with optional badge)
struct NavMenuRow: View {
    let icon: String
    let title: String
    var tint: Color = .red
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
                Text(title).font(.subheadline)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.gray)
            }
            .padding()
            .background(ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Notification for replaying onboarding
extension Notification.Name {
    static let replayOnboarding = Notification.Name("replayOnboarding")
}

// Keep StatItem and helper types for backwards compat
struct StatItem: View {
    let value: String
    let label: String
    var icon: String = ""

    var body: some View {
        VStack(spacing: 4) {
            if !icon.isEmpty {
                Image(systemName: icon).font(.caption2).foregroundStyle(.red)
            }
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}
