// AdminDashboardView.swift
// Admin panel — user management, content moderation, analytics
// Only visible to users with role == "admin" or "superadmin"

import SwiftUI

struct AdminDashboardView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var selectedTab = AdminTab.overview
    @State private var stats: AdminStats?
    @State private var users: [AdminUserRow] = []
    @State private var reports: [ContentReport] = []
    @State private var loading = true

    enum AdminTab: String, CaseIterable {
        case overview = "Overview"
        case users = "Users"
        case content = "Content"
        case challenges = "Challenges"

        var icon: String {
            switch self {
            case .overview: return "chart.bar.fill"
            case .users: return "person.3.fill"
            case .content: return "flag.fill"
            case .challenges: return "trophy.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if !auth.isAdmin {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                        Text("Admin Access Required")
                            .font(.title2.bold())
                        Text("You need admin privileges to view this page.")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                } else {
                    VStack(spacing: 0) {
                        // Tab bar
                        HStack(spacing: 0) {
                            ForEach(AdminTab.allCases, id: \.self) { tab in
                                Button {
                                    selectedTab = tab
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: tab.icon)
                                            .font(.system(size: 14))
                                        Text(tab.rawValue)
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(selectedTab == tab ? .red : .gray)
                                    .background(selectedTab == tab ? Color.red.opacity(0.1) : .clear)
                                }
                            }
                        }
                        .background(ThemeManager.surface)

                        // Content
                        ScrollView {
                            switch selectedTab {
                            case .overview:
                                overviewSection
                            case .users:
                                usersSection
                            case .content:
                                contentSection
                            case .challenges:
                                challengesSection
                            }
                        }
                        .refreshable { await loadData() }
                    }
                }
            }
            .navigationTitle("Admin Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadData() }
        }
    }

    // MARK: - Overview
    var overviewSection: some View {
        VStack(spacing: 16) {
            if let stats {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCard("Total Users", value: "\(stats.totalUsers)", icon: "person.fill", color: .blue)
                    statCard("Pro Users", value: "\(stats.proUsers)", icon: "star.fill", color: .yellow)
                    statCard("Projects", value: "\(stats.totalProjects)", icon: "film.fill", color: .green)
                    statCard("Published", value: "\(stats.publishedProjects)", icon: "globe", color: .cyan)
                    statCard("Challenges", value: "\(stats.activeChallenges)", icon: "trophy.fill", color: .orange)
                    statCard("Reports", value: "\(stats.pendingReports)", icon: "flag.fill", color: .red)
                }
                .padding()
            } else if loading {
                ProgressView().padding(.top, 40)
            }
        }
    }

    // MARK: - Users
    var usersSection: some View {
        VStack(spacing: 8) {
            if users.isEmpty && !loading {
                Text("No users loaded").font(.caption).foregroundStyle(.gray).padding(.top, 40)
            }
            ForEach(users) { user in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.username).font(.subheadline.bold())
                        Text(user.email).font(.caption).foregroundStyle(.gray)
                    }

                    Spacer()

                    Text(user.role)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(roleColor(user.role).opacity(0.2))
                        .foregroundStyle(roleColor(user.role))
                        .clipShape(Capsule())

                    Text(user.tier)
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
                .padding()
                .background(ThemeManager.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    // MARK: - Content Moderation
    var contentSection: some View {
        VStack(spacing: 8) {
            if reports.isEmpty && !loading {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("No pending reports").font(.subheadline).foregroundStyle(.gray)
                }
                .padding(.top, 40)
            }

            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "flag.fill").foregroundStyle(.red).font(.caption)
                        Text(report.reason).font(.subheadline.bold())
                        Spacer()
                        Text(report.status).font(.caption).foregroundStyle(.orange)
                    }

                    Text(report.description).font(.caption).foregroundStyle(.gray)

                    HStack(spacing: 8) {
                        Button("Dismiss") {
                            Task { await handleReport(report.id, action: "dismiss") }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.gray.opacity(0.2))
                        .clipShape(Capsule())

                        Button("Remove Content") {
                            Task { await handleReport(report.id, action: "remove") }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.red.opacity(0.2))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())

                        Button("Ban User") {
                            Task { await handleReport(report.id, action: "ban") }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                }
                .padding()
                .background(ThemeManager.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    // MARK: - Challenges
    var challengesSection: some View {
        VStack(spacing: 12) {
            Button {
                // TODO: Create challenge sheet
            } label: {
                Label("Create Challenge", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.red)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            Text("Manage weekly challenges, review entries, pick winners.")
                .font(.caption)
                .foregroundStyle(.gray)
                .padding(.horizontal)
        }
        .padding(.top, 16)
    }

    // MARK: - Helpers

    func statCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(ThemeManager.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    func roleColor(_ role: String) -> Color {
        switch role {
        case "superadmin": return .red
        case "admin": return .orange
        case "pro": return .yellow
        default: return .gray
        }
    }

    // MARK: - Data Loading

    func loadData() async {
        loading = true
        defer { loading = false }

        do {
            // Load stats via admin-actions edge function
            guard let accessToken = auth.session?.accessToken else { return }

            var request = URLRequest(url: AppConfig.edgeFunction("admin-actions"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "get_stats"])

            let (data, _) = try await URLSession.shared.data(for: request)
            stats = try JSONDecoder().decode(AdminStats.self, from: data)

            // Load users
            let usersResult: [AdminUserRow] = try await supabase
                .from("users")
                .select("id, username, email, role, subscription_tier, created_at")
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
            users = usersResult
        } catch {
            print("⚠️ Admin data load failed: \(error)")
        }
    }

    func handleReport(_ id: UUID, action: String) async {
        guard let accessToken = auth.session?.accessToken else { return }
        do {
            var request = URLRequest(url: AppConfig.edgeFunction("admin-actions"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "action": "handle_report",
                "report_id": id.uuidString,
                "resolution": action,
            ])
            let _ = try await URLSession.shared.data(for: request)
            reports.removeAll { $0.id == id }
        } catch {
            print("⚠️ Report action failed: \(error)")
        }
    }
}

// MARK: - Admin Models

struct AdminStats: Decodable {
    let totalUsers: Int
    let proUsers: Int
    let totalProjects: Int
    let publishedProjects: Int
    let activeChallenges: Int
    let pendingReports: Int

    enum CodingKeys: String, CodingKey {
        case totalUsers = "total_users"
        case proUsers = "pro_users"
        case totalProjects = "total_projects"
        case publishedProjects = "published_projects"
        case activeChallenges = "active_challenges"
        case pendingReports = "pending_reports"
    }
}

struct AdminUserRow: Identifiable, Decodable {
    let id: UUID
    let username: String
    let email: String
    let role: String
    let tier: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, username, email, role
        case tier = "subscription_tier"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "—"
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? "—"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? "free"
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct ContentReport: Identifiable, Decodable {
    let id: UUID
    let reason: String
    let description: String
    let status: String
    let reportedBy: String
    let contentId: String

    enum CodingKeys: String, CodingKey {
        case id, reason, description, status
        case reportedBy = "reported_by"
        case contentId = "content_id"
    }
}
