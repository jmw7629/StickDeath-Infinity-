// ChallengesView.swift
// Layer 1 ROOT — Challenges tab
//
// Why is the user here?  → Browse & join community challenges
// Next action?           → Tap a challenge → see details → join → create
// Back?                  → Tab root (this IS the root)
// Forward?               → ChallengeDetail → Join → Editor
//
// Flow: Challenges → Detail → Join → Create → Back → Detail (not Home)

import SwiftUI

struct ChallengesView: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var challenges: [Challenge] = []
    @State private var loading = true
    @State private var filter: ChallengeFilter = .active

    enum ChallengeFilter: String, CaseIterable {
        case active = "Active"
        case voting = "Voting"
        case completed = "Past"
        case all = "All"
    }

    var filteredChallenges: [Challenge] {
        switch filter {
        case .all: return challenges
        case .active: return challenges.filter { $0.status == "active" }
        case .voting: return challenges.filter { $0.status == "voting" }
        case .completed: return challenges.filter { $0.status == "completed" }
        }
    }

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            if loading && challenges.isEmpty {
                ProgressView().tint(.red)
            } else if challenges.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    // ── Filter pills ──
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ChallengeFilter.allCases, id: \.self) { f in
                                Button {
                                    filter = f
                                    HapticManager.shared.buttonTap()
                                } label: {
                                    Text(f.rawValue)
                                        .font(.caption.bold())
                                        .foregroundStyle(filter == f ? .black : .white)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(filter == f ? Color.red : ThemeManager.surface)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    // ── Challenge Cards ──
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(filteredChallenges) { challenge in
                                ChallengeCard(challenge: challenge) {
                                    router.challengesPath.append(
                                        ChallengesDestination.challengeDetail(challenge)
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                    .refreshable { await loadChallenges() }
                }
            }
        }
        .navigationTitle("Challenges")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.openSpatter(context: .challenges)
                } label: {
                    Image(systemName: "sparkles").foregroundStyle(.red)
                }
            }
        }
        .task { await loadChallenges() }
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 56)).foregroundStyle(.red.opacity(0.5))
            Text("No challenges yet")
                .font(.title3.bold())
            Text("Check back soon for community challenges!")
                .font(.subheadline).foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    func loadChallenges() async {
        loading = true
        challenges = (try? await supabase
            .from("challenges")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value) ?? []
        loading = false
    }
}

// MARK: - Challenge Card (tappable → forward to detail)
struct ChallengeCard: View {
    let challenge: Challenge
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                // Header with status badge
                HStack {
                    statusBadge
                    Spacer()
                    if let entries = challenge.entry_count, entries > 0 {
                        Label("\(entries) entries", systemImage: "person.3.fill")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                }

                // Title + theme
                Text(challenge.title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)

                if let theme = challenge.theme, !theme.isEmpty {
                    Text(theme)
                        .font(.subheadline)
                        .foregroundStyle(.red.opacity(0.8))
                }

                if let desc = challenge.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                }

                // Footer: dates + prize
                HStack {
                    if let prize = challenge.prize_description, !prize.isEmpty {
                        Label(prize, systemImage: "gift.fill")
                            .font(.caption2).foregroundStyle(.yellow)
                    }
                    Spacer()
                    if let end = challenge.end_date?.prefix(10) {
                        Label("Ends \(end)", systemImage: "clock")
                            .font(.caption2).foregroundStyle(.gray)
                    }
                }

                // CTA: clear forward action
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Text("View Challenge")
                            .font(.caption.bold())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(ThemeManager.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch challenge.status {
            case "active": return ("Active", .green)
            case "voting": return ("Voting", .yellow)
            case "completed": return ("Completed", .gray)
            default: return ("Upcoming", .cyan)
            }
        }()

        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}
