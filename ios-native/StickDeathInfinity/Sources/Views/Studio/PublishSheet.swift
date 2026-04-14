// PublishSheet.swift
// Enhanced publish flow — official StickDeath channels + user platforms + watermark

import SwiftUI

struct PublishSheet: View {
    @ObservedObject var vm: EditorViewModel
    @EnvironmentObject var auth: AuthManager
    @StateObject private var socialManager = SocialAccountsManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var publishToOwn = false
    @State private var selectedUserPlatforms: Set<String> = []
    @State private var removeWatermark = false
    @State private var isPublishing = false
    @State private var published = false
    @State private var publishError: String?
    @State private var showConnectAccounts = false
    @State private var publishProgress: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeManager.background.ignoresSafeArea()

                if published {
                    successView
                } else {
                    publishForm
                }
            }
            .navigationTitle("Publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await socialManager.fetchUserAccounts() }
    }

    // MARK: - Publish Form
    private var publishForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── Video Title & Description ──
                VStack(alignment: .leading, spacing: 8) {
                    Text("Title").font(.subheadline.bold())
                    TextField("My Awesome Animation", text: $title)
                        .padding()
                        .background(ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text("Description").font(.subheadline.bold()).padding(.top, 4)
                    TextField("What's this animation about?", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                        .padding()
                        .background(ThemeManager.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // ── Official StickDeath Channels (always on) ──
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "megaphone.fill")
                            .foregroundStyle(.red)
                        Text("StickDeath Official Channels")
                            .font(.subheadline.bold())
                    }

                    Text("Your video will be published to all official channels — this builds the community and generates ad revenue for everyone.")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    ForEach(SocialAccountsManager.officialChannels) { channel in
                        if let platform = SocialAccountsManager.platform(for: channel.platform) {
                            HStack(spacing: 12) {
                                Image(systemName: platform.icon)
                                    .foregroundStyle(Color(hex: platform.color))
                                    .frame(width: 20)
                                VStack(alignment: .leading) {
                                    Text(platform.name)
                                        .font(.subheadline.bold())
                                    Text(channel.handle)
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            .padding(10)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                // ── Watermark ──
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "seal.fill")
                            .foregroundStyle(.red)
                        Text("Video Branding")
                            .font(.subheadline.bold())
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("\"StickDeath ∞\" watermark")
                                .font(.subheadline)
                            Text("Appears on all videos posted to official channels")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .padding(12)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if auth.isPro {
                        Toggle(isOn: $removeWatermark) {
                            VStack(alignment: .leading) {
                                Text("Remove watermark on personal export")
                                    .font(.caption.bold())
                                Text("Only for copies sent to your own accounts")
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                            }
                        }
                        .tint(.red)
                        .padding(.horizontal, 4)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text("Upgrade to Pro to remove watermark on personal exports")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(10)
                        .background(.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider().background(ThemeManager.border)

                // ── User's Own Channels (optional) ──
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $publishToOwn) {
                        VStack(alignment: .leading) {
                            Text("Also publish to my channels")
                                .font(.subheadline.bold())
                            Text("Upload to your connected social accounts too")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                    }
                    .tint(.red)

                    if publishToOwn {
                        // Connected accounts
                        if socialManager.userAccounts.isEmpty {
                            VStack(spacing: 12) {
                                Text("No accounts connected yet")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                Button {
                                    showConnectAccounts = true
                                } label: {
                                    Label("Connect Accounts", systemImage: "link.badge.plus")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.red)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity)
                                        .background(.red.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            .padding(12)
                            .background(ThemeManager.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            ForEach(socialManager.userAccounts) { account in
                                if let platform = SocialAccountsManager.platform(for: account.platform) {
                                    HStack(spacing: 12) {
                                        Image(systemName: platform.icon)
                                            .foregroundStyle(Color(hex: platform.color))
                                            .frame(width: 20)
                                        VStack(alignment: .leading) {
                                            Text(platform.name)
                                                .font(.subheadline.bold())
                                            Text(account.handle)
                                                .font(.caption)
                                                .foregroundStyle(.gray)
                                        }
                                        Spacer()
                                        Image(systemName: selectedUserPlatforms.contains(account.platform) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedUserPlatforms.contains(account.platform) ? Color(hex: platform.color) : .gray)
                                    }
                                    .padding(10)
                                    .background(ThemeManager.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .onTapGesture {
                                        if selectedUserPlatforms.contains(account.platform) {
                                            selectedUserPlatforms.remove(account.platform)
                                        } else {
                                            selectedUserPlatforms.insert(account.platform)
                                        }
                                    }
                                }
                            }
                        }

                        // Quick connect more
                        Button {
                            showConnectAccounts = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle")
                                Text("Connect more platforms")
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        .padding(.top, 4)
                    }
                }

                // ── Error ──
                if let error = publishError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(10)
                    .background(.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // ── Progress ──
                if isPublishing && !publishProgress.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().tint(.red).scaleEffect(0.8)
                        Text(publishProgress)
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    .padding(10)
                    .background(ThemeManager.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // ── Publish Button ──
                Button {
                    Task { await publish() }
                } label: {
                    if isPublishing {
                        ProgressView().tint(.black)
                    } else {
                        Label("Publish Animation", systemImage: "paperplane.fill")
                            .font(.headline)
                            .foregroundStyle(.black)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(title.isEmpty ? .gray : .red)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(title.isEmpty || isPublishing)

                // Terms
                Text("By publishing, you agree that your video will be uploaded to StickDeath official channels. Videos may appear on YouTube, TikTok, Instagram, Discord, Facebook, and other platforms to build community reach and ad revenue.")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(24)
        }
        .sheet(isPresented: $showConnectAccounts) {
            ConnectedAccountsView()
        }
    }

    // MARK: - Success View
    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Published! 🎉")
                .font(.title.bold())
            Text("Your animation is being uploaded to all selected platforms.")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("Uploading to:")
                    .font(.caption.bold())
                    .foregroundStyle(.gray)

                ForEach(SocialAccountsManager.officialChannels) { ch in
                    if let p = SocialAccountsManager.platform(for: ch.platform) {
                        HStack(spacing: 8) {
                            Image(systemName: p.icon)
                                .foregroundStyle(Color(hex: p.color))
                                .frame(width: 16)
                            Text("\(p.name) — \(ch.handle)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                                .font(.caption2)
                        }
                    }
                }
            }
            .padding()
            .background(ThemeManager.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 40)

            Button("Done") { dismiss() }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 40)
        }
        .padding()
    }

    // MARK: - Publish Logic
    func publish() async {
        isPublishing = true
        publishError = nil

        do {
            // Step 1: Save project
            publishProgress = "Saving project..."
            await vm.saveProject()

            // Step 2: Mark as published
            publishProgress = "Preparing video..."
            try await ProjectService.shared.publishProject(projectId: vm.project.id)

            // Step 3: Determine watermark config
            let watermarkEnabled = !(auth.isPro && removeWatermark)

            // Step 4: Upload to official StickDeath channels (always)
            publishProgress = "Publishing to StickDeath channels..."
            let officialPlatforms = SocialAccountsManager.officialChannels.map { $0.platform }
            try await PublishService.shared.publishToSocial(
                projectId: vm.project.id,
                platforms: officialPlatforms,
                title: title,
                description: description,
                watermark: true,  // Always watermarked on official channels
                accountType: "official"
            )

            // Step 5: Upload to user's own channels (optional)
            if publishToOwn && !selectedUserPlatforms.isEmpty {
                publishProgress = "Publishing to your channels..."
                try await PublishService.shared.publishToSocial(
                    projectId: vm.project.id,
                    platforms: Array(selectedUserPlatforms),
                    title: title,
                    description: description,
                    watermark: watermarkEnabled,
                    accountType: "user"
                )
            }

            published = true
        } catch {
            publishError = error.localizedDescription
        }

        isPublishing = false
        publishProgress = ""
    }
}
