import SwiftUI

struct ChallengesView: View {
    @State private var selectedFilter = "active"
    @State private var challenges: [Challenge] = ChallengeItem.samples
    @State private var selectedChallenge: Challenge?

    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("🏆")
                        .font(.system(size: 24))
                    Text("Challenges")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Filter tabs
                HStack(spacing: 8) {
                    ForEach(["active", "upcoming", "completed"], id: \.self) { filter in
                        Button(action: { selectedFilter = filter }) {
                            Text(filter.capitalized)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(selectedFilter == filter ? .white : .white.opacity(0.4))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(selectedFilter == filter ? Color.red : Color(hex: "1A1A24"))
                                .cornerRadius(8)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider().background(Color.white.opacity(0.06))

                // Challenges list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(challenges.filter { $0.status == selectedFilter }) { challenge in
                            ChallengeCard(challenge: challenge) {
                                selectedChallenge = challenge
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .sheet(item: $selectedChallenge) { challenge in
            ChallengeDetailView(challenge: challenge)
        }
    }
}

struct ChallengeCard: View {
    let challenge: Challenge
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Banner
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: challenge.gradientStart), Color(hex: challenge.gradientEnd)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 100)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(challenge.emoji)
                                .font(.system(size: 28))
                            Text(challenge.title)
                                .font(.system(size: 16, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(challenge.reward)
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                            Text("coins")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Info
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                        Text("\(challenge.participants) entries")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.white.opacity(0.4))

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 9))
                        Text(challenge.timeLeft)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.red)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
            .padding(12)
            .background(Color(hex: "12121A"))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct InlineChallengeDetailView: View {
    let challenge: Challenge
    @State private var hasEntered = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // Banner
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: challenge.gradientStart), Color(hex: challenge.gradientEnd)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 160)

                        VStack(spacing: 8) {
                            Text(challenge.emoji)
                                .font(.system(size: 48))
                            Text(challenge.title)
                                .font(.system(size: 22, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                            Text("\(challenge.reward) coins")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }

                    // Description
                    Text(challenge.description)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 16)

                    // Rules
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RULES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .tracking(2)

                        ForEach(challenge.rules, id: \.self) { rule in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundColor(.red)
                                Text(rule)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Enter button
                    Button(action: { hasEntered.toggle() }) {
                        Text(hasEntered ? "✅ Entered" : "Enter Challenge")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(hasEntered ? Color.green : Color.red)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
        }
    }
}

struct ChallengeItem: Identifiable {
    let id: String
    let title: String
    let emoji: String
    let description: String
    let reward: String
    let participants: Int
    let timeLeft: String
    let status: String
    let gradientStart: String
    let gradientEnd: String
    let rules: [String]

    static let samples: [Challenge] = [
        ChallengeItem(id: "ch1", title: "Last Stand",
                  emoji: "⚔️",
                  description: "Create a 2-5 second animation of a stick figure making their last stand. Use dramatic angles and dynamic poses.",
                  reward: "500",
                  participants: 47,
                  timeLeft: "2d 14h",
                  status: "active",
                  gradientStart: "7F1D1D", gradientEnd: "991B1B",
                  rules: ["2-5 seconds long", "12+ FPS", "At least 24 frames", "Original work only"]),
        ChallengeItem(id: "ch2", title: "Speed Demon",
                  emoji: "🏃",
                  description: "Animate the fastest possible action sequence. Speed is everything!",
                  reward: "250",
                  participants: 23,
                  timeLeft: "5d 8h",
                  status: "active",
                  gradientStart: "1E3A5F", gradientEnd: "2563EB",
                  rules: ["Under 2 seconds", "24 FPS minimum", "Must include motion blur"]),
        ChallengeItem(id: "ch3", title: "Glow Up",
                  emoji: "✨",
                  description: "Use glow effects and neon colors to create something magical.",
                  reward: "750",
                  participants: 0,
                  timeLeft: "Starts in 3d",
                  status: "upcoming",
                  gradientStart: "581C87", gradientEnd: "7C3AED",
                  rules: ["Must use glow layers", "Neon color palette", "3-10 seconds"]),
        ChallengeItem(id: "ch4", title: "Comedy Gold",
                  emoji: "😂",
                  description: "Make us laugh! Funniest animation wins.",
                  reward: "400",
                  participants: 89,
                  timeLeft: "Ended",
                  status: "completed",
                  gradientStart: "713F12", gradientEnd: "B45309",
                  rules: ["Any length", "Must be funny", "No NSFW content"]),
    ]
}

struct ChallengesView_Previews: PreviewProvider {
    static var previews: some View {
        ChallengesView()
    }
}
