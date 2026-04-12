// ConnectedAccountsView.swift
// Manage social platform connections — connect/disconnect OAuth accounts

import SwiftUI

struct ConnectedAccountsView: View {
    @StateObject private var manager = SocialAccountsManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var connectingPlatform: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "link.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text("Connect your social accounts to publish videos to your own channels alongside StickDeath's.")
                                .font(.caption)
                                .foregroundStyle(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 8)

                        if let error {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            .padding(10)
                            .background(.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        // All platforms
                        ForEach(SocialAccountsManager.allPlatforms) { platform in
                            let connected = manager.userAccounts.first { $0.platform == platform.id }

                            HStack(spacing: 14) {
                                // Platform icon
                                Image(systemName: platform.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color(hex: platform.color))
                                    .frame(width: 36, height: 36)
                                    .background(Color(hex: platform.color).opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                // Info
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(platform.name)
                                        .font(.subheadline.bold())
                                    if let conn = connected {
                                        Text(conn.handle)
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else {
                                        Text("Not connected")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                }

                                Spacer()

                                // Action
                                if let _ = connected {
                                    // Disconnect button
                                    Button {
                                        Task {
                                            try? await manager.disconnectPlatform(platform.id)
                                        }
                                    } label: {
                                        Text("Disconnect")
                                            .font(.caption.bold())
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(.red.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                } else if connectingPlatform == platform.id {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .tint(Color(hex: platform.color))
                                } else {
                                    // Connect button
                                    Button {
                                        Task { await connect(platform.id) }
                                    } label: {
                                        Text("Connect")
                                            .font(.caption.bold())
                                            .foregroundStyle(Color(hex: platform.color))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color(hex: platform.color).opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    .disabled(!platform.supportsDirectUpload)
                                }
                            }
                            .padding(14)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            if !platform.supportsDirectUpload {
                                Text("Direct upload coming soon")
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                                    .padding(.top, -12)
                                    .padding(.leading, 8)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Connected Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await manager.fetchUserAccounts() }
    }

    func connect(_ platformId: String) async {
        connectingPlatform = platformId
        error = nil
        do {
            let oauthURL = try await manager.connectPlatform(platformId)
            await MainActor.run {
                UIApplication.shared.open(oauthURL)
            }
        } catch {
            self.error = "Failed to connect: \(error.localizedDescription)"
        }
        connectingPlatform = nil
    }
}
