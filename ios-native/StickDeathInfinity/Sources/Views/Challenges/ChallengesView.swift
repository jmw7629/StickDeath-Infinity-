// ChallengesView.swift
// "Challenges" — "Compete. Create. Win."
// Cards with ACTIVE (green), VOTING (yellow), COMPLETED (gray) badges

import SwiftUI

struct ChallengesView: View {
    @EnvironmentObject var router: NavigationRouter
    @State private var challenges = Challenge.sampleChallenges

    var body: some View {
        ZStack {
            ThemeManager.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // ── Header ──
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Challenges")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Compete. Create. Win.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(hex: "#9090a8"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    // ── Challenge Cards ──
                    ForEach(challenges) { challenge in
                        ChallengeCard(challenge: challenge)
                            .onTapGesture {
                                router.push(ChallengesDestination.challengeDetail(challenge))
                            }
                    }

                    // Bottom padding for tab bar
                    Spacer().frame(height: 80)
                }
            }
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Challenge Card
struct ChallengeCard: View {
    let challenge: Challenge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Title + Badge ──
            HStack {
                Text(challenge.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                statusBadge
            }

            // ── Description ──
            Text(challenge.description)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "#9090a8"))

            // ── Stats Row ──
            HStack(spacing: 16) {
                Label("\(challenge.entries) entries", systemImage: "person.2.fill")
                    .foregroundStyle(Color(hex: "#9090a8"))
                Label(challenge.prize, systemImage: "trophy.fill")
                    .foregroundStyle(Color.yellow)
                Spacer()
                Text(challenge.endDate)
                    .foregroundStyle(Color(hex: "#9090a8"))
            }
            .font(.system(size: 12))

            // ── Enter Button (only for active) ──
            if challenge.status == .active {
                Button {
                    // Enter challenge
                } label: {
                    Text("Enter Challenge")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(ThemeManager.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(ThemeManager.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ThemeManager.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    var statusBadge: some View {
        Text(challenge.status.label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(challenge.status.color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Sample Data
extension Challenge {
    static let sampleChallenges: [Challenge] = [
        Challenge(id: 1, title: "Free Fall", description: "Gravity-defying action",
                  entries: 47, prize: "Featured + Pro badge", endDate: "Ends Apr 20",
                  status: .active),
        Challenge(id: 2, title: "Epic Showdown", description: "2-figure fight scenes",
                  entries: 83, prize: "1 month Creator", endDate: "Ended Apr 13",
                  status: .voting),
        Challenge(id: 3, title: "Walk This Way", description: "Best walk cycle loop",
                  entries: 121, prize: "Community spotlight", endDate: "Ended Apr 6",
                  status: .completed),
        Challenge(id: 4, title: "Speed Run", description: "Complete in under 60 seconds",
                  entries: 65, prize: "Pro badge", endDate: "Ended Mar 30",
                  status: .completed),
    ]
}
