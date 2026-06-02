import SwiftUI
import WebKit

// MARK: - Admin Dashboard (Superuser Only)
struct AdminDashboardView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var selectedTab = "dashboard"
    @State private var stats = AdminStats()
    @State private var showSpatterAdmin = false
    
    let tabs: [(id: String, icon: String, label: String)] = [
        ("dashboard", "chart.bar.fill", "Dashboard"),
        ("users", "person.2.fill", "Users"),
        ("content", "doc.fill", "Content"),
        ("challenges", "trophy.fill", "Challenges"),
        ("spatter", "brain.fill", "Spatter AI"),
        ("bots", "cpu.fill", "AI Bots"),
        ("analytics", "chart.xyaxis.line", "Analytics"),
        ("moderation", "shield.fill", "Moderation"),
        ("settings", "gearshape.fill", "Settings"),
        ("billing", "creditcard.fill", "Billing"),
    ]
    
    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.fill")
                                .foregroundColor(.red)
                            Text("ADMIN PANEL")
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        Text("StickDeath ∞ Command Center")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    
                    // Live indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                // Tab selector (horizontal scroll)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs, id: \.id) { tab in
                            Button(action: { selectedTab = tab.id }) {
                                HStack(spacing: 4) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 10))
                                    Text(tab.label)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(selectedTab == tab.id ? .white : .white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedTab == tab.id ? Color.red : Color(hex: "1A1A24"))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
                
                Divider().background(Color.white.opacity(0.06))
                
                // Content
                ScrollView {
                    VStack(spacing: 12) {
                        switch selectedTab {
                        case "dashboard":
                            AdminDashboardContent(stats: stats)
                        case "users":
                            AdminUsersContent()
                        case "content":
                            AdminContentContent()
                        case "challenges":
                            AdminChallengesContent()
                        case "spatter":
                            AdminSpatterContent()
                        case "bots":
                            AdminBotsContent()
                        case "analytics":
                            AdminAnalyticsContent()
                        case "moderation":
                            AdminModerationContent()
                        case "settings":
                            AdminSettingsContent()
                        case "billing":
                            AdminBillingContent()
                        default:
                            EmptyView()
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

// MARK: - Admin Stats
struct AdminStats {
    var totalUsers = 1247
    var activeToday = 89
    var totalAnimations = 4521
    var totalRevenue = 12450.00
    var pendingReports = 3
    var aiQueriesDay = 892
}

// MARK: - Dashboard Content
struct AdminDashboardContent: View {
    let stats: AdminStats
    
    var body: some View {
        VStack(spacing: 12) {
            // Stat cards
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                AdminStatCard(icon: "person.2.fill", label: "Total Users", value: "\(stats.totalUsers)", color: "3B82F6")
                AdminStatCard(icon: "person.fill.checkmark", label: "Active Today", value: "\(stats.activeToday)", color: "10B981")
                AdminStatCard(icon: "film.fill", label: "Animations", value: "\(stats.totalAnimations)", color: "8B5CF6")
                AdminStatCard(icon: "dollarsign.circle.fill", label: "Revenue", value: "$\(String(format: "%.0f", stats.totalRevenue))", color: "F59E0B")
                AdminStatCard(icon: "exclamationmark.shield.fill", label: "Reports", value: "\(stats.pendingReports)", color: "EF4444")
                AdminStatCard(icon: "brain", label: "AI Queries/Day", value: "\(stats.aiQueriesDay)", color: "EC4899")
            }
            
            // Recent activity
            VStack(alignment: .leading, spacing: 8) {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(2)
                
                ForEach(0..<5, id: \.self) { i in
                    let activities = [
                        ("StickNinja99 joined", "person.fill.badge.plus", "2m ago"),
                        ("New animation: 'Last Stand'", "film.fill", "5m ago"),
                        ("Creator plan purchased", "creditcard.fill", "12m ago"),
                        ("Report: spam content", "flag.fill", "18m ago"),
                        ("Challenge 'Speed Demon' ended", "trophy.fill", "30m ago"),
                    ]
                    HStack(spacing: 10) {
                        Image(systemName: activities[i].1)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .frame(width: 24)
                        Text(activities[i].0)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text(activities[i].2)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
            .background(Color(hex: "12121A"))
            .cornerRadius(12)
        }
    }
}

struct AdminStatCard: View {
    let icon: String
    let label: String
    let value: String
    let color: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(Color(hex: color))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(hex: "12121A"))
        .cornerRadius(12)
    }
}

// MARK: - Users Tab
struct AdminUsersContent: View {
    @State private var searchText = ""
    let users = [
        ("J_Willy_Style", "joseph@willisnmb.com", "superuser", "👑"),
        ("StickNinja99", "ninja@example.com", "pro", "🥷"),
        ("FightClubArt", "fighter@example.com", "creator", "🥊"),
        ("AnimKing", "king@example.com", "creator", "👑"),
        ("xDeathArtist", "death@example.com", "free", "💀"),
    ]
    
    var body: some View {
        VStack(spacing: 10) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.3))
                TextField("Search users...", text: $searchText)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
            }
            .padding(10)
            .background(Color(hex: "1A1A24"))
            .cornerRadius(10)
            
            ForEach(users, id: \.0) { user in
                HStack(spacing: 10) {
                    Text(user.3)
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.0)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text(user.1)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    Text(user.2.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(user.2 == "superuser" ? .red : user.2 == "pro" ? .purple : .white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: "1A1A24"))
                        .cornerRadius(4)
                }
                .padding(10)
                .background(Color(hex: "12121A"))
                .cornerRadius(10)
            }
        }
    }
}

// MARK: - Content Tab
struct AdminContentContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AdminInfoCard(title: "Total Animations", value: "4,521", detail: "+127 this week")
            AdminInfoCard(title: "Total Storage", value: "2.1 TB", detail: "72% capacity")
            AdminInfoCard(title: "Flagged Content", value: "12", detail: "3 pending review")
        }
    }
}

// MARK: - Challenges Tab
struct AdminChallengesContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AdminInfoCard(title: "Active Challenges", value: "3", detail: "Last Stand, Speed Demon, Glow Up")
            AdminInfoCard(title: "Total Entries", value: "159", detail: "47 + 23 + 89")
            AdminInfoCard(title: "Coins Distributed", value: "12,450", detail: "This month")
        }
    }
}

// MARK: - Spatter AI Tab
struct AdminSpatterContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AdminInfoCard(title: "Brain Modules", value: "51,100", detail: "100 + 1,000 + 50,000")
            AdminInfoCard(title: "AI Queries Today", value: "892", detail: "Avg response: 1.2s")
            AdminInfoCard(title: "Knowledge Categories", value: "20", detail: "Animation, Physics, Anatomy...")
            
            // Spatter Admin iframe link
            Button(action: {}) {
                HStack {
                    Image(systemName: "link")
                    Text("Open Spatter Admin Portal")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red)
                .cornerRadius(12)
            }
        }
    }
}

// MARK: - Bots Tab
struct AdminBotsContent: View {
    let bots = [
        ("Spatter", "🎨", true), ("CoachBot", "🏋️", true),
        ("CritiqueBot", "📝", true), ("MoodBot", "🎭", true),
        ("TutorBot", "📚", true), ("ChallengeBot", "🏆", true),
        ("NewsBot", "📰", true),
    ]
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(bots, id: \.0) { bot in
                HStack(spacing: 10) {
                    Text(bot.1)
                        .font(.system(size: 20))
                    Text(bot.0)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Circle()
                        .fill(bot.2 ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(bot.2 ? "ACTIVE" : "OFFLINE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(bot.2 ? .green : .red)
                }
                .padding(10)
                .background(Color(hex: "12121A"))
                .cornerRadius(10)
            }
        }
    }
}

// MARK: - Analytics Tab
struct AdminAnalyticsContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AdminInfoCard(title: "DAU", value: "89", detail: "+12% from last week")
            AdminInfoCard(title: "WAU", value: "342", detail: "+8% from last week")
            AdminInfoCard(title: "MAU", value: "1,247", detail: "+23% from last month")
            AdminInfoCard(title: "Avg Session", value: "14.2 min", detail: "+3.1 min from last week")
            AdminInfoCard(title: "Retention (D7)", value: "34%", detail: "Target: 40%")
        }
    }
}

// MARK: - Moderation Tab
struct AdminModerationContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AdminInfoCard(title: "Pending Reports", value: "3", detail: "2 content, 1 user")
            AdminInfoCard(title: "Auto-Flagged", value: "7", detail: "NSFW filter catches")
            AdminInfoCard(title: "Banned Users", value: "2", detail: "Last 30 days")
        }
    }
}

// MARK: - Settings Tab
struct AdminSettingsContent: View {
    @State private var maintenanceMode = false
    @State private var allowRegistration = true
    @State private var requireEmailVerification = true
    
    var body: some View {
        VStack(spacing: 10) {
            Toggle("Maintenance Mode", isOn: $maintenanceMode)
                .padding(12)
                .background(Color(hex: "12121A"))
                .cornerRadius(10)
            Toggle("Allow Registration", isOn: $allowRegistration)
                .padding(12)
                .background(Color(hex: "12121A"))
                .cornerRadius(10)
            Toggle("Require Email Verification", isOn: $requireEmailVerification)
                .padding(12)
                .background(Color(hex: "12121A"))
                .cornerRadius(10)
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .tint(.red)
    }
}

// MARK: - Billing Tab
struct AdminBillingContent: View {
    var body: some View {
        VStack(spacing: 10) {
            AdminInfoCard(title: "MRR", value: "$12,450", detail: "+18% from last month")
            AdminInfoCard(title: "Free Users", value: "892", detail: "72% of total")
            AdminInfoCard(title: "Creator Plan", value: "234", detail: "$1,167/mo")
            AdminInfoCard(title: "Pro Plan", value: "98", detail: "$979/mo")
            AdminInfoCard(title: "Studio Plan", value: "23", detail: "$459/mo")
        }
    }
}

// MARK: - Reusable Info Card
struct AdminInfoCard: View {
    let title: String
    let value: String
    let detail: String
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Spacer()
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.trailing)
        }
        .padding(12)
        .background(Color(hex: "12121A"))
        .cornerRadius(12)
    }
}
