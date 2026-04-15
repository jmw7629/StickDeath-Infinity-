// ChallengeDetailView.swift
// Layer 2 — CONTEXT SCREEN (within Challenges tab)
//
// Why is the user here?  → Tapped a challenge to see details + entries
// Next action?           → Join → create animation, or view entries
// Back?                  → Returns to Challenges list
// Forward?               → Join → Editor (within this tab), or Creator Profile
//
// RULE: Back from editor returns HERE, not Home or Studio tab

import SwiftUI

struct ChallengeDetailView: View {
    let challenge: Challenge
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var auth: AuthManager
    @State private var entries: [ChallengeEntry] = []
    @State private var loading = true
    @State private var hasJoined = false
    @State private var showCreateProject = false
    @State private var newProjectTitle = ""

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    // ── Challenge Header ──
                    VStack(spacing: 12) {
                        // Hero
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    LinearGradient(
                                        colors: [.red.opacity(0.3), .purple.opacity(0.2), .black],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                                .frame(height: 180)

                            VStack(spacing: 8) {
                                Image(systemName: "trophy.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.yellow)
                                Text(challenge.title)
                                    .font(.title2.bold())
                                    .multilineTextAlignment(.center)
                                if let theme = challenge.theme {
                                    Text(theme)
                                        .font(.subheadline)
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        // Description
                        if let desc = challenge.description, !desc.isEmpty {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                                .padding(.horizontal, 16)
                        }

                        // Info row
                        HStack(spacing: 16) {
                            if let entries = challenge.entry_count {
                                infoChip(icon: "person.3.fill", text: "\(entries) entries", color: .cyan)
                            }
                            if let end = challenge.end_date?.prefix(10) {
                                infoChip(icon: "clock", text: "Ends \(end)", color: .yellow)
                            }
                            if let prize = challenge.prize_description {
                                infoChip(icon: "gift.fill", text: prize, color: .green)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    // ── JOIN BUTTON (primary forward action) ──
                    if challenge.status == "active" {
                        Button {
                            showCreateProject = true
                            HapticManager.shared.buttonTap()
                        } label: {
                            HStack {
                                Image(systemName: hasJoined ? "checkmark.circle.fill" : "plus.circle.fill")
                                Text(hasJoined ? "Submit Another Entry" : "Join Challenge")
                            }
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 16)
                    }

                    Divider().background(ThemeManager.border).padding(.horizontal)

                    // ── Entries (tappable → forward to creator) ──
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Entries (\(entries.count))")
                            .font(.headline)
                            .padding(.horizontal, 16)

                        if loading {
                            ProgressView().tint(.red).frame(maxWidth: .infinity).padding()
                        } else if entries.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray")
                                    .font(.title).foregroundStyle(.gray)
                                Text("No entries yet — be the first!")
                                    .font(.subheadline).foregroundStyle(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(entries) { entry in
                                    ChallengeEntryRow(entry: entry) {
                                        if let userId = entry.user_id {
                                            router.challengesPath.append(
                                                ChallengesDestination.creatorProfile(userId)
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // ── Ask Spatter for ideas (overlay, not navigation) ──
                    Button {
                        router.openSpatter(context: .challenges)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(.purple)
                            Text("Ask Spatter for entry ideas")
                                .font(.subheadline.bold()).foregroundStyle(.purple)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.purple.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("Challenge")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Create Entry", isPresented: $showCreateProject) {
            TextField("Animation title", text: $newProjectTitle)
            Button("Create & Open Editor") {
                Task { await createAndOpenEditor() }
            }
            Button("Cancel", role: .cancel) { newProjectTitle = "" }
        } message: {
            Text("Name your animation for this challenge")
        }
        .task { await loadEntries() }
    }

    // MARK: - Helpers
    func infoChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.caption2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    // MARK: - Data
    func loadEntries() async {
        loading = true
        entries = (try? await supabase
            .from("challenge_entries")
            .select("*, user:users(username, avatar_url)")
            .eq("challenge_id", value: challenge.id)
            .order("vote_count", ascending: false)
            .execute()
            .value) ?? []
        loading = false
    }

    func createAndOpenEditor() async {
        let title = newProjectTitle.isEmpty ? "Challenge Entry" : newProjectTitle
        newProjectTitle = ""
        if let project = try? await ProjectService.shared.createProject(title: title) {
            hasJoined = true
            // Push editor WITHIN Challenges tab — back returns here
            router.challengesPath.append(
                ChallengesDestination.challengeEditor(project, challenge.id)
            )
        }
    }
}

// MARK: - Entry Row (tappable → forward to creator)
struct ChallengeEntryRow: View {
    let entry: ChallengeEntry
    let onCreatorTap: () -> Void

    var body: some View {
        Button(action: onCreatorTap) {
            HStack(spacing: 12) {
                // Thumbnail
                RoundedRectangle(cornerRadius: 8)
                    .fill(ThemeManager.surface)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "figure.run")
                            .foregroundStyle(.red.opacity(0.4))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.project_title ?? "Untitled")
                        .font(.subheadline.bold())
                    Text(entry.user?.username ?? "Anonymous")
                        .font(.caption).foregroundStyle(.gray)
                }

                Spacer()

                if let votes = entry.vote_count, votes > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup.fill")
                            .font(.caption2)
                        Text("\(votes)")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.yellow)
                }

                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.gray)
            }
            .padding(12)
            .background(ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
