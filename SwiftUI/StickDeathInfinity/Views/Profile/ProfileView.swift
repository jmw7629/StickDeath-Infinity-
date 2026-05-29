// ═══════════════════════════════════════════════════════════════════
// ProfileView — User profile with stats, menu items, subscription
// Matches: ProfileScreen.tsx exactly
// Avatar with red ring + initials, username, tier badge
// Stats: Projects / Published / Followers / Likes
// Menu: Messages, Notifications, Invite to SD∞, Settings, Theme, Admin, Sign Out
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var authVM: AuthViewModel

    @State private var subScreen: ProfileSubScreen = .main
    @State private var stats = ProfileStats()

    enum ProfileSubScreen {
        case main, notifications, achievements, subscription, settings, theme, admin
    }

    var body: some View {
        Group {
            switch subScreen {
            case .main:
                mainProfileView
            case .notifications:
                NotificationCenterView(onBack: { subScreen = .main })
            case .settings:
                SettingsView(onBack: { subScreen = .main })
            case .theme:
                ThemeView(onBack: { subScreen = .main })
            case .admin:
                AdminDashboardView(onBack: { subScreen = .main })
            default:
                mainProfileView
            }
        }
    }

    // MARK: - Main Profile
    private var mainProfileView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Profile Header
                HStack(spacing: 14) {
                    // Avatar with red ring + initials
                    ZStack {
                        Circle()
                            .stroke(Color.sdRed, lineWidth: 3)
                            .frame(width: 64, height: 64)

                        Circle()
                            .fill(Color.sdSurface2)
                            .frame(width: 58, height: 58)

                        Text(initials)
                            .font(.specialElite(24))
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(username)
                            .font(.specialElite(20))
                            .fontWeight(.bold)
                            .foregroundColor(.white)

                        HStack(spacing: 8) {
                            // Tier badge
                            Text(tierDisplay)
                                .font(.specialElite(11))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .background(Color.sdRed)
                                .cornerRadius(4)

                            if tier != "free" {
                                Text(tierPrice)
                                    .font(.specialElite(13))
                                    .foregroundColor(.sdTextSecondary)
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 20)

                // Stats Row
                HStack(spacing: 0) {
                    ProfileStatItem(value: "\(stats.projects)", label: "Projects", showDivider: true)
                    ProfileStatItem(value: "\(stats.published)", label: "Published", showDivider: true)
                    ProfileStatItem(value: stats.followers >= 1000 ? String(format: "%.1fk", Double(stats.followers) / 1000) : "\(stats.followers)", label: "Followers", showDivider: true)
                    ProfileStatItem(value: stats.likes >= 1000 ? String(format: "%.1fk", Double(stats.likes) / 1000) : "\(stats.likes)", label: "Likes", showDivider: false)
                }
                .background(Color.sdSurface)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.sdBorder, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

                // Menu Items
                VStack(spacing: 8) {
                    ProfileMenuItem(icon: "💬", label: "Messages") {
                        // Navigate to messages
                    }

                    ProfileMenuItem(icon: "🔔", label: "Notifications") {
                        subScreen = .notifications
                    }

                    ProfileMenuItem(icon: "💀", label: "Invite to SD∞", badge: "⚡ 50 XP", isHighlighted: true) {
                        // Share invite link
                    }

                    ProfileMenuItem(icon: "⚙️", label: "Settings") {
                        subScreen = .settings
                    }

                    ProfileMenuItem(icon: "🎨", label: "Theme") {
                        subScreen = .theme
                    }

                    ProfileMenuItem(icon: "🛡️", label: "Admin Dashboard") {
                        subScreen = .admin
                    }

                    ProfileMenuItem(icon: "🚪", label: "Sign Out") {
                        Task { await authVM.signOut() }
                    }
                }
                .padding(.horizontal, 16)

                // Subscription Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Subscription")
                        .font(.specialElite(16))
                        .foregroundColor(.sdTextSecondary)
                        .italic()
                        .padding(.top, 16)

                    ForEach(subscriptionPlans, id: \.id) { plan in
                        SubscriptionPlanRow(plan: plan, isCurrent: plan.id == "creator")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 100)
            }
        }
        .background(Color.sdBackground)
        .task { await loadStats() }
    }

    // MARK: - Computed
    private var username: String {
        authVM.currentUser?.username ?? "Guest"
    }

    private var initials: String {
        let name = username
        if name.count >= 2 {
            return String(name.prefix(2)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private var tier: String {
        authVM.currentUser?.subscriptionTier ?? "free"
    }

    private var tierDisplay: String {
        tier.prefix(1).uppercased() + tier.dropFirst()
    }

    private var tierPrice: String {
        switch tier {
        case "creator": return "$4.99/mo"
        case "pro": return "$9.99/mo"
        case "studio": return "$19.99/mo"
        default: return ""
        }
    }

    // MARK: - Load Stats
    private func loadStats() async {
        let supabase = SupabaseManager.shared.client
        guard let userId = authVM.currentUser?.id else { return }
        do {
            let projects: [StudioProject] = try await supabase
                .from("studio_projects")
                .select("*")
                .eq("user_id", value: userId)
                .execute()
                .value
            stats.projects = projects.count
            stats.published = projects.filter { $0.thumbnailURL != nil }.count
        } catch {
            print("[Profile] Stats error: \(error)")
        }
    }

    // MARK: - Subscription Plans
    private var subscriptionPlans: [SubscriptionPlan] {
        [
            SubscriptionPlan(id: "free", name: "Free", price: "$0", period: "", tags: ["5 projects", "720p export", "Basic tools"]),
            SubscriptionPlan(id: "pro", name: "Pro", price: "$4.99", period: "/mo", tags: ["Unlimited projects", "1080p export", "All tools", "No ads"]),
            SubscriptionPlan(id: "creator", name: "Creator", price: "$7.99", period: "/mo", tags: ["Everything in Pro", "4K export", "Priority support", "Creator badge"]),
        ]
    }
}

// MARK: - Profile Stats
struct ProfileStats {
    var projects = 0
    var published = 0
    var followers = 0
    var likes = 0
}

// MARK: - Profile Stat Item
struct ProfileStatItem: View {
    let value: String
    let label: String
    let showDivider: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(value)
                    .font(.specialElite(18))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text(label)
                    .font(.specialElite(11))
                    .foregroundColor(.sdTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)

            if showDivider {
                Rectangle()
                    .fill(Color.sdBorder)
                    .frame(width: 1)
                    .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Menu Item
struct ProfileMenuItem: View {
    let icon: String
    let label: String
    var badge: String? = nil
    var isHighlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(icon)
                    .font(.system(size: 20))

                Text(label)
                    .font(.specialElite(15))
                    .foregroundColor(.white)

                Spacer()

                if let badge = badge {
                    Text(badge)
                        .font(.specialElite(11))
                        .fontWeight(.bold)
                        .foregroundColor(.sdRed)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.sdRed.opacity(0.15))
                        .cornerRadius(10)
                }

                Text("›")
                    .font(.specialElite(18))
                    .foregroundColor(.sdTextMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 15)
            .background(isHighlighted ? Color.sdRed.opacity(0.08) : Color.sdSurface)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHighlighted ? Color.sdRed.opacity(0.25) : Color.sdBorder, lineWidth: 1)
            )
        }
    }
}

// MARK: - Subscription Plan
struct SubscriptionPlan: Identifiable {
    let id: String
    let name: String
    let price: String
    let period: String
    let tags: [String]
}

struct SubscriptionPlanRow: View {
    let plan: SubscriptionPlan
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.name)
                    .font(.specialElite(16))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()

                HStack(spacing: 0) {
                    Text(plan.price)
                        .font(.specialElite(16))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text(plan.period)
                        .font(.specialElite(12))
                        .foregroundColor(.sdTextSecondary)
                }

                if isCurrent {
                    Text("Current")
                        .font(.specialElite(11))
                        .fontWeight(.bold)
                        .foregroundColor(.sdRed)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.sdRed.opacity(0.15))
                        .cornerRadius(8)
                }
            }

            // Tag pills
            FlowLayout(spacing: 6) {
                ForEach(plan.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.specialElite(11))
                        .foregroundColor(.sdTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                }
            }
        }
        .padding(14)
        .background(Color.sdSurface)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? Color.sdRed : Color.sdBorder, lineWidth: isCurrent ? 2 : 1)
        )
    }
}

// MARK: - Placeholder Sub-screens
struct NotificationCenterView: View {
    let onBack: () -> Void
    var body: some View {
        VStack {
            HStack {
                Button { onBack() } label: {
                    Text("← Back").font(.specialElite(14)).foregroundColor(.white)
                }
                Spacer()
                Text("🔔 Notifications").font(.specialElite(18)).fontWeight(.bold).foregroundColor(.white)
                Spacer()
            }.padding(16).background(Color.sdSurface)
            Spacer()
            Text("No new notifications").font(.specialElite(14)).foregroundColor(.sdTextSecondary)
            Spacer()
        }.background(Color.sdBackground)
    }
}

struct ThemeView: View {
    let onBack: () -> Void
    var body: some View {
        VStack {
            HStack {
                Button { onBack() } label: {
                    Text("← Back").font(.specialElite(14)).foregroundColor(.white)
                }
                Spacer()
                Text("🎨 Theme").font(.specialElite(18)).fontWeight(.bold).foregroundColor(.white)
                Spacer()
            }.padding(16).background(Color.sdSurface)
            Spacer()
            Text("Dark theme only — as it should be 💀").font(.specialElite(14)).foregroundColor(.sdTextSecondary)
            Spacer()
        }.background(Color.sdBackground)
    }
}

struct AdminDashboardView: View {
    let onBack: () -> Void
    var body: some View {
        VStack {
            HStack {
                Button { onBack() } label: {
                    Text("← Back").font(.specialElite(14)).foregroundColor(.white)
                }
                Spacer()
                Text("🛡️ Admin Dashboard").font(.specialElite(18)).fontWeight(.bold).foregroundColor(.white)
                Spacer()
            }.padding(16).background(Color.sdSurface)
            Spacer()
            Text("Admin controls").font(.specialElite(14)).foregroundColor(.sdTextSecondary)
            Spacer()
        }.background(Color.sdBackground)
    }
}
