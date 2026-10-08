import SwiftUI

/// Reference-shaped profile. Connected facts remain unavailable until verified.
struct ProfileView: View {
    @EnvironmentObject var authVM: AuthViewModel
    let onOpenProjects: () -> Void
    @State private var destination: Destination?
    @State private var localProjectCount: Int?

    private enum Destination: String, Identifiable {
        case account, analytics, subscription
        var id: String { rawValue }
        var title: String {
            switch self {
            case .account: return "Settings"
            case .analytics: return "Analytics"
            case .subscription: return "Subscription"
            }
        }
    }
    private var profile: UserProfile? {
        guard authVM.isAuthenticated, let user = authVM.user,
              let id = UUID(uuidString: user.id), let current = authVM.userId,
              id == UUID(uuidString: current) else { return nil }
        return user
    }
    private var displayName: String {
        let name = profile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (authVM.isAuthenticated ? "Your profile" : "Guest") : name
    }
    private var reportedPlan: String? {
        guard let tier = profile?.subscriptionTier?.lowercased(),
              ["free", "pro", "creator", "studio"].contains(tier) else { return nil }
        return tier.capitalized
    }
    private var avatarURL: URL? {
        guard let raw = profile?.avatarURL, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Text(String(displayName.prefix(2)).uppercased())
                            .font(.specialElite(24)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(hex: "1E1E1E"))
                    }
                    .frame(width: 64, height: 64).clipShape(Circle())
                    .overlay(Circle().stroke(Color.sdRed, lineWidth: 3))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName).font(.specialElite(20)).foregroundStyle(.white)
                        Text(reportedPlan.map { "Reported plan: \($0)" } ?? (authVM.isAuthenticated ? "Plan unavailable" : "On-device guest"))
                            .font(.specialElite(11)).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.sdRed.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.top, 24)
                .accessibilityIdentifier("profile.identity")

                if let bio = profile?.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(bio).font(.specialElite(13)).foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    statistic(localProjectCount.map(String.init) ?? "—", "Projects")
                    statistic("—", "Published")
                    statistic("—", "Followers")
                    statistic("—", "Likes")
                }
                .padding(.vertical, 14).background(Color(hex: "141414"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Projects counts saved animations on this device. Published, followers and likes are unavailable.")
                    .font(.specialElite(11)).foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Button(action: onOpenProjects) {
                        rowLabel("Projects on this device", icon: "folder")
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("profile.projects.open")
                    row("Analytics", icon: "chart.bar", destination: .analytics)
                    row("Settings", icon: "gearshape", destination: .account)
                    row("Subscription", icon: "creditcard", destination: .subscription)
                }

                Text("Subscription").font(.specialElite(16)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(reportedPlan ?? "Plan unavailable").font(.specialElite(16))
                    Text("Pricing, renewal and purchase information are not connected. No payment or subscription change is available here.")
                        .font(.specialElite(12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color(hex: "141414")).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("profile.subscription-status")
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Color(hex: "0A0A0A").ignoresSafeArea())
        .foregroundStyle(.white)
        .task(id: authVM.userId) {
            // Device-level inventory, never presented as a server/account portfolio.
            localProjectCount = nil
            if let listing = try? DeviceStorageManager.shared.listAnimationsReportingFailures(), listing.failures.isEmpty {
                localProjectCount = listing.animations.count
            }
        }
        .onChange(of: authVM.userId) { _ in destination = nil }
        .sheet(item: $destination) { page in
            NavigationStack {
                Group {
                    switch page {
                    case .account: ProfileSettingsView()
                    case .analytics:
                        detail("Analytics unavailable", "Views, likes and engagement have not been loaded. No activity totals are estimated.")
                    case .subscription:
                        detail(reportedPlan.map { "Reported plan: \($0)" } ?? "Plan unavailable",
                               "Verified pricing and billing management are not connected. No purchase or renewal is claimed.")
                    }
                }
                .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { destination = nil } } }
            }
        }
    }

    private func statistic(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.specialElite(18))
            Text(label).font(.specialElite(11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private func row(_ title: String, icon: String, destination page: Destination) -> some View {
        Button { destination = page } label: {
            rowLabel(title, icon: icon)
        }.buttonStyle(.plain)
    }
    private func rowLabel(_ title: String, icon: String) -> some View {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(.specialElite(15))
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(15).background(Color(hex: "141414"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.specialElite(20))
            Text(text).font(.specialElite(14)).foregroundStyle(.secondary)
            Spacer()
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Replace the old disconnected toggles, invented disk usage and inert Sign Out.
struct ProfileSettingsView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @State private var showingProfileEditor = false
    private var accountEmail: String {
        guard authVM.isAuthenticated, let user = authVM.user,
              let id = UUID(uuidString: user.id), let current = authVM.userId,
              id == UUID(uuidString: current) else { return "No signed-in account" }
        return user.email ?? "Email unavailable"
    }
    var body: some View {
        List {
            Section("Account") {
                Text(accountEmail)
                if authVM.captureProfileEdit() != nil {
                    Button("Edit username and bio") { showingProfileEditor = true }
                        .accessibilityIdentifier("profile.edit.open")
                } else {
                    Text("Sign in with an available profile to edit username and bio.").foregroundStyle(.secondary)
                }
            }
            Section("Studio") {
                Text("Change grid, onion skin and project settings in the Studio menu. Those controls apply to the actual project.")
            }
            if authVM.isAuthenticated {
                Section {
                    Button("Sign Out", role: .destructive) { Task { await authVM.signOut() } }
                        .disabled(authVM.isLoading)
                    if let error = authVM.error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .sheet(isPresented: $showingProfileEditor) { EditProfileView() }
        .onChange(of: authVM.userId) { _ in showingProfileEditor = false }
    }
}
