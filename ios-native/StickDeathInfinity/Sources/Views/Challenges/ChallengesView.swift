// ═══════════════════════════════════════════════════════════════════
// ChallengesView — Animation challenges with gradient cards
// Matches: ChallengesScreen.tsx exactly
// Filters: Active / Upcoming / Voting / Completed
// Gradient cards: red Death Battle, blue Parkour, purple Dance Off
// Tapping card → detail view with stats, rules, submissions tab
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

struct ChallengesView: View {
    @State private var filter: ChallengeFilter = .active
    @State private var selectedChallenge: SDChallenge?

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            if let ch = selectedChallenge {
                ChallengeDetailView(challenge: ch, onBack: { selectedChallenge = nil })
            } else {
                challengeListView
            }
        }
    }

    // MARK: - Challenge List
    private var challengeListView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("⚔️")
                        .font(.system(size: 20))
                    Text("Challenges")
                        .font(.specialElite(18))
                        .fontWeight(.bold)
                        .foregroundColor(.sdTextPrimary)
                        .tracking(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 16)

                // Filter tabs
                HStack(spacing: 0) {
                    ForEach(ChallengeFilter.allCases, id: \.self) { f in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { filter = f }
                        } label: {
                            VStack(spacing: 0) {
                                Text(f.rawValue)
                                    .font(.specialElite(12))
                                    .foregroundColor(filter == f ? .sdRed : .sdTextSecondary)
                                    .fontWeight(filter == f ? .bold : .regular)
                                    .padding(.vertical, 10)

                                Rectangle()
                                    .fill(filter == f ? Color.sdRed : Color.clear)
                                    .frame(height: 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .background(Color.sdSurface)

            // Challenge cards
            ScrollView {
                let filtered = sampleChallenges.filter { $0.status == filter }

                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Text("⚔️")
                            .font(.system(size: 48))
                        Text(filter.emptyMessage)
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                    }
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        ForEach(filtered) { ch in
                            Button {
                                selectedChallenge = ch
                            } label: {
                                ChallengeCard(challenge: ch)
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 80)
                }
            }
        }
    }
}

// MARK: - Challenge Card (gradient)
struct ChallengeCard: View {
    let challenge: SDChallenge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row + time badge
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Text(challenge.icon)
                        .font(.system(size: 24))
                    Text(challenge.title)
                        .font(.specialElite(18))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }

                Spacer()

                Text("\(challenge.endsIn) left")
                    .font(.specialElite(12))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
            }

            // Description
            Text(challenge.description)
                .font(.specialElite(13))
                .foregroundColor(.white.opacity(0.85))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)

            // Bottom row: entries + coins
            HStack(spacing: 16) {
                Text("\(challenge.entries) entries")
                    .font(.specialElite(12))
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 4) {
                    Text("🪙")
                        .font(.system(size: 12))
                    Text("\(challenge.coins) coins")
                        .font(.specialElite(12))
                        .foregroundColor(.sdWarning)
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: challenge.gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(16)
    }
}

// MARK: - Challenge Detail View
struct ChallengeDetailView: View {
    let challenge: SDChallenge
    let onBack: () -> Void

    @State private var activeDetailTab: DetailTab = .submissions
    @State private var showSubmitConfirm = false

    enum DetailTab: String, CaseIterable {
        case submissions = "Submissions"
        case leaderboard = "Leaderboard"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Button { onBack() } label: {
                    Text("←")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }

                Text("⚔️")
                    .font(.system(size: 20))

                Text(challenge.title)
                    .font(.specialElite(18))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()
            }
            .padding(16)
            .background(Color.sdSurface)

            ScrollView {
                VStack(spacing: 0) {
                    // Stats row
                    HStack(spacing: 12) {
                        StatBox(value: "\(challenge.entries)", label: "Entries", color: .sdRed)
                        StatBox(value: challenge.endsIn, label: "Left", color: .white)
                        StatBox(value: "\(challenge.coins)", label: "Coins", color: .sdWarning)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                    // Description
                    Text(challenge.description)
                        .font(.specialElite(14))
                        .foregroundColor(.sdTextSecondary)
                        .lineSpacing(4)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)

                    // Rules
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rules:")
                            .font(.specialElite(14))
                            .fontWeight(.bold)
                            .foregroundColor(.white)

                        ForEach(challenge.rules, id: \.self) { rule in
                            Text("• \(rule)")
                                .font(.specialElite(13))
                                .foregroundColor(.sdTextSecondary)
                                .padding(.leading, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                    // Tabs: Submissions / Leaderboard
                    HStack(spacing: 8) {
                        ForEach(DetailTab.allCases, id: \.self) { tab in
                            Button {
                                activeDetailTab = tab
                            } label: {
                                Text(tab.rawValue)
                                    .font(.specialElite(13))
                                    .fontWeight(.bold)
                                    .foregroundColor(activeDetailTab == tab ? .white : .sdTextSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(activeDetailTab == tab ? Color.sdRed : Color.sdSurface)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                    // Tab content - empty states
                    VStack(spacing: 12) {
                        Text(activeDetailTab == .submissions ? "🎬" : "🏆")
                            .font(.system(size: 40))
                        Text(activeDetailTab == .submissions
                            ? "No submissions yet. Be the first!"
                            : "Leaderboard populates after voting begins.")
                            .font(.specialElite(14))
                            .foregroundColor(.sdTextSecondary)
                    }
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
                    .background(Color.sdSurface)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                    // Submit Entry button
                    if challenge.status == .active {
                        Button {
                            showSubmitConfirm = true
                        } label: {
                            Text("Submit Entry 🎬")
                                .font(.specialElite(16))
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.sdRed)
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                    }

                    // Submit confirmation
                    if showSubmitConfirm {
                        VStack(spacing: 12) {
                            Text("Open Studio to create your entry?")
                                .font(.specialElite(14))
                                .foregroundColor(.white)

                            HStack(spacing: 8) {
                                Button {
                                    // Navigate to studio
                                } label: {
                                    Text("Open Studio")
                                        .font(.specialElite(13))
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.sdRed)
                                        .cornerRadius(8)
                                }

                                Button {
                                    showSubmitConfirm = false
                                } label: {
                                    Text("Cancel")
                                        .font(.specialElite(13))
                                        .foregroundColor(.sdTextSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.sdSurface2)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color.sdSurface)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.sdBorder, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                }
                .padding(.bottom, 100)
            }
        }
    }
}

// MARK: - Stat Box
struct StatBox: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.specialElite(22))
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.specialElite(11))
                .foregroundColor(.sdTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.sdSurface)
        .cornerRadius(12)
    }
}

// MARK: - Filter Enum
enum ChallengeFilter: String, CaseIterable {
    case active = "Active"
    case upcoming = "Upcoming"
    case voting = "Voting"
    case completed = "Completed"

    var emptyMessage: String {
        switch self {
        case .active: return "No active challenges right now."
        case .upcoming: return "New challenges coming soon."
        case .voting: return "No challenges in voting phase."
        case .completed: return "No completed challenges yet."
        }
    }
}

// MARK: - Challenge Model
struct SDChallenge: Identifiable {
    let id: String
    let title: String
    let description: String
    let entries: Int
    let coins: Int
    let endsIn: String
    let gradientColors: [Color]
    let icon: String
    let rules: [String]
    let status: ChallengeFilter
}

// MARK: - Sample Data (matches ChallengesScreen.tsx exactly)
let sampleChallenges: [SDChallenge] = [
    SDChallenge(
        id: "death-battle",
        title: "Death Battle Royale",
        description: "Create a 5-second animation of an epic battle scene between two stick figures.",
        entries: 0,
        coins: 500,
        endsIn: "3d",
        gradientColors: [Color(hex: "#DC2626"), Color(hex: "#991B1B")],
        icon: "⚔️",
        rules: ["Max 5 seconds", "Must include at least 2 characters", "No NSFW content"],
        status: .active
    ),
    SDChallenge(
        id: "parkour-run",
        title: "Parkour Run",
        description: "Animate a stick figure doing the most insane parkour sequence you can imagine.",
        entries: 0,
        coins: 300,
        endsIn: "5d",
        gradientColors: [Color(hex: "#3B82F6"), Color(hex: "#1D4ED8")],
        icon: "🏃",
        rules: ["Max 8 seconds", "Single character", "Must include at least 3 moves"],
        status: .active
    ),
    SDChallenge(
        id: "dance-off",
        title: "Dance Off",
        description: "Make your stick figure bust the sickest moves. Style points matter.",
        entries: 0,
        coins: 250,
        endsIn: "7d",
        gradientColors: [Color(hex: "#A855F7"), Color(hex: "#7C3AED")],
        icon: "💃",
        rules: ["Max 10 seconds", "Must loop cleanly", "Bonus for music sync"],
        status: .upcoming
    ),
]
