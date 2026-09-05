import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var selectedTab = "projects"
    @State private var bio = "Creator & Animator 💀 Building the future of stick figure animation."
    @State private var isEditing = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Profile")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                ScrollView {
                    VStack(spacing: 16) {
                        // Avatar & name
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: "1A1A24"))
                                    .frame(width: 80, height: 80)
                                Text("👑")
                                    .font(.system(size: 40))
                            }

                            Text(authManager.currentUser?.handle ?? "J_Willy_Style")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)

                            Text(authManager.currentUser?.email ?? "joseph@willisnmb.com")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))

                            // Role badge
                            if authManager.currentUser?.role == "superuser" {
                                HStack(spacing: 4) {
                                    Image(systemName: "shield.fill")
                                    Text("SUPERUSER")
                                }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }

                        // Bio
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Bio")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.4))
                                Spacer()
                                Button(action: { isEditing.toggle() }) {
                                    Text(isEditing ? "Save" : "Edit")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.red)
                                }
                            }

                            if isEditing {
                                TextEditor(text: $bio)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white)
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 60)
                                    .padding(8)
                                    .background(Color(hex: "1A1A24"))
                                    .cornerRadius(8)
                            } else {
                                Text(bio)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .padding(.horizontal, 16)

                        // Stats
                        HStack(spacing: 0) {
                            ProfileStat(value: "42", label: "Projects")
                            Divider().background(Color.white.opacity(0.1)).frame(height: 30)
                            ProfileStat(value: "1.2K", label: "Followers")
                            Divider().background(Color.white.opacity(0.1)).frame(height: 30)
                            ProfileStat(value: "89", label: "Following")
                            Divider().background(Color.white.opacity(0.1)).frame(height: 30)
                            ProfileStat(value: "3.4K", label: "Coins")
                        }
                        .padding(.vertical, 12)
                        .background(Color(hex: "12121A"))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)

                        // Tab selector
                        HStack(spacing: 0) {
                            ForEach(["projects", "analytics", "subscription"], id: \.self) { tab in
                                Button(action: { selectedTab = tab }) {
                                    Text(tab.capitalized)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(selectedTab == tab ? .red : .white.opacity(0.4))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(selectedTab == tab ? Color.red.opacity(0.1) : Color.clear)
                                }
                            }
                        }
                        .background(Color(hex: "12121A"))
                        .cornerRadius(10)
                        .padding(.horizontal, 16)

                        // Tab content
                        switch selectedTab {
                        case "projects":
                            ProjectsGrid()
                        case "analytics":
                            AnalyticsView()
                        case "subscription":
                            SubscriptionView()
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            ProfileSettingsView()
        }
    }
}

struct ProfileStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProjectsGrid: View {
    let projects = [
        ("Last Stand", "⚔️", "48 frames"),
        ("Speed Run", "🏃", "24 frames"),
        ("Meteor Strike", "☄️", "36 frames"),
        ("Final Boss", "👹", "120 frames"),
        ("Combo Attack", "💥", "60 frames"),
        ("Training", "🎯", "16 frames"),
    ]

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ], spacing: 8) {
            ForEach(projects, id: \.0) { project in
                VStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: "1A1A24"))
                            .frame(height: 100)
                        Text(project.1)
                            .font(.system(size: 32))
                    }
                    Text(project.0)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(project.2)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

struct AnalyticsView: View {
    var body: some View {
        VStack(spacing: 12) {
            AnalyticsCard(title: "Total Views", value: "12.4K", change: "+18%", positive: true)
            AnalyticsCard(title: "Total Likes", value: "3.2K", change: "+24%", positive: true)
            AnalyticsCard(title: "Avg. Watch Time", value: "4.2s", change: "-3%", positive: false)
            AnalyticsCard(title: "Engagement Rate", value: "68%", change: "+7%", positive: true)
        }
        .padding(.horizontal, 16)
    }
}

struct AnalyticsCard: View {
    let title: String
    let value: String
    let change: String
    let positive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Spacer()
            Text(change)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(positive ? .green : .red)
        }
        .padding(16)
        .background(Color(hex: "12121A"))
        .cornerRadius(12)
    }
}

struct ProfileSettingsView: View {
    @State private var darkMode = true
    @State private var soundEffects = true
    @State private var autoSave = true
    @State private var haptics = true
    @State private var showGrid = true
    @State private var onionSkin = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0A0A0F").ignoresSafeArea()

                List {
                    Section("GENERAL") {
                        Toggle("Dark Mode", isOn: $darkMode)
                        Toggle("Sound Effects", isOn: $soundEffects)
                        Toggle("Haptic Feedback", isOn: $haptics)
                    }

                    Section("DRAWING") {
                        Toggle("Auto Save", isOn: $autoSave)
                        Toggle("Show Grid", isOn: $showGrid)
                        Toggle("Onion Skinning", isOn: $onionSkin)
                    }

                    Section("STORAGE") {
                        HStack {
                            Text("Device Storage")
                            Spacer()
                            Text("2.4 GB / 64 GB")
                                .foregroundColor(.white.opacity(0.4))
                        }

                        ProgressView(value: 2.4, total: 64)
                            .tint(.red)
                    }

                    Section("ACCOUNT") {
                        Button("Sign Out") {}
                            .foregroundColor(.red)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView()
    }
}
