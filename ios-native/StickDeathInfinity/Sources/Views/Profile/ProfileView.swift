// ProfileView.swift
// User profile — settings, subscription, published work

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var showSettings = false
    @State private var showSubscription = false

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Profile header
                        VStack(spacing: 12) {
                            Circle()
                                .fill(ThemeManager.surface)
                                .frame(width: 80, height: 80)
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.largeTitle)
                                        .foregroundStyle(.orange)
                                )

                            Text(auth.currentUser?.username ?? "User")
                                .font(.title2.bold())

                            if let bio = auth.currentUser?.bio, !bio.isEmpty {
                                Text(bio)
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)
                            }

                            // Subscription badge
                            if auth.isPro {
                                Label("PRO", systemImage: "star.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(.orange)
                                    .clipShape(Capsule())
                            } else {
                                Button { showSubscription = true } label: {
                                    Label("Upgrade to Pro", systemImage: "star")
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 4)
                                        .background(.orange.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.top, 20)

                        // Stats
                        HStack(spacing: 32) {
                            StatItem(value: "0", label: "Animations")
                            StatItem(value: "0", label: "Views")
                            StatItem(value: "0", label: "Likes")
                        }
                        .padding(.vertical, 12)

                        Divider().background(ThemeManager.border)

                        // Settings menu
                        VStack(spacing: 2) {
                            SettingsRow(icon: "person.circle", title: "Edit Profile") {
                                showSettings = true
                            }
                            SettingsRow(icon: "star.circle", title: "Subscription") {
                                showSubscription = true
                            }
                            SettingsRow(icon: "link.circle", title: "Connected Accounts") {}
                            SettingsRow(icon: "bell.circle", title: "Notifications") {}
                            SettingsRow(icon: "questionmark.circle", title: "Help & Support") {}

                            // Admin access
                            if auth.isAdmin {
                                SettingsRow(icon: "shield.checkered", title: "Admin Portal", tint: .purple) {}
                            }

                            // Logout
                            Button {
                                Task { await auth.logout() }
                            } label: {
                                HStack {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .foregroundStyle(.red)
                                        .frame(width: 24)
                                    Text("Sign Out")
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                                .padding()
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showSettings) {
                EditProfileView()
            }
            .sheet(isPresented: $showSubscription) {
                SubscriptionView()
            }
        }
    }
}

struct StatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.gray)
        }
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
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .padding()
            .background(ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Edit Profile
struct EditProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var username = ""
    @State private var bio = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Username") {
                    TextField("Username", text: $username)
                }
                Section("Bio") {
                    TextEditor(text: $bio)
                        .frame(height: 80)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            try? await auth.updateProfile(username: username, bio: bio)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(saving)
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
                    Image(systemName: "star.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.orange)

                    Text("StickDeath Pro")
                        .font(.title.bold())

                    VStack(alignment: .leading, spacing: 12) {
                        ProFeature(text: "AI Animation Assistant")
                        ProFeature(text: "Unlimited Projects")
                        ProFeature(text: "HD Export (1080p+)")
                        ProFeature(text: "Custom Stick Figures")
                        ProFeature(text: "Priority Publishing")
                        ProFeature(text: "No Watermark")
                    }

                    Text("$4.99 / month")
                        .font(.title2.bold())
                        .foregroundStyle(.orange)

                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await subscribe() }
                    } label: {
                        if loading {
                            ProgressView().tint(.black)
                        } else {
                            Text("Subscribe Now")
                                .font(.headline)
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 40)

                    Text("Cancel anytime. Billed monthly through Stripe.")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    func subscribe() async {
        loading = true
        error = nil
        do {
            let checkoutURL = try await StripeService.shared.createCheckoutSession()
            // Open Stripe checkout in Safari
            await MainActor.run {
                UIApplication.shared.open(checkoutURL)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
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
