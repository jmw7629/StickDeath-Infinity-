import SwiftUI

struct ChallengeDetailView: View {
    let challenge: ChallengeItem
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ChallengeTab = .submissions
    
    enum ChallengeTab: String, CaseIterable {
        case submissions = "Submissions"
        case leaderboard = "Leaderboard"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.gray)
                        .font(.system(size: 18))
                }
                Text("⚔️").font(.system(size: 18))
                Text(challenge.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            ScrollView {
                VStack(spacing: 0) {
                    // Stats row
                    HStack(spacing: 12) {
                        StatCard(value: "\(challenge.entries)", label: "Entries", color: .red)
                        StatCard(value: challenge.timeLeft, label: "Left", color: .green)
                        StatCard(value: "\(challenge.coins)", label: "Coins", color: .yellow)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    // Description
                    VStack(alignment: .leading, spacing: 12) {
                        Text(challenge.description)
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .lineSpacing(4)
                        
                        Text("Rules:")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            RuleRow(text: "Max 5 seconds")
                            RuleRow(text: "Must include at least 2 characters")
                            RuleRow(text: "No NSFW content")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    
                    // Tab picker
                    HStack(spacing: 8) {
                        ForEach(ChallengeTab.allCases, id: \.self) { tab in
                            Button(action: { selectedTab = tab }) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(selectedTab == tab ? .red : .gray)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedTab == tab
                                            ? Color.red.opacity(0.15)
                                            : Color.white.opacity(0.05)
                                    )
                                    .cornerRadius(10)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    
                    // Tab content
                    if selectedTab == .submissions {
                        SubmissionsGrid()
                    } else {
                        LeaderboardList()
                    }
                }
            }
            
            // Submit button
            Button(action: { /* Navigate to submission */ }) {
                Text("Submit Entry 🎬")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.red)
                    .cornerRadius(12)
            }
            .padding(16)
        }
        .background(Color(hex: "0A0A14"))
    }
}

struct StatCard: View {
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(hex: "0E0E1A"))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

struct RuleRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text("•").foregroundColor(.gray)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.gray)
        }
    }
}

struct SubmissionsGrid: View {
    let submissions = [
        ("StickNinja99", "⚔️", 48),
        ("AnimKing", "🗡️", 42),
        ("xDeathArtist", "💀", 38),
        ("FightClubArt", "🔥", 35),
        ("PixelWarrior", "🥷", 31),
        ("StickLord", "🏹", 28),
    ]
    
    let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(submissions, id: \.0) { sub in
                VStack(spacing: 6) {
                    Text(sub.1).font(.system(size: 32))
                    Text(sub.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    Text("\(sub.2) votes")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color(hex: "0E0E1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .cornerRadius(10)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct LeaderboardList: View {
    let leaders = [
        ("xDeathArtist", 1240),
        ("StickNinja99", 1180),
        ("AnimKing", 980),
        ("FightClubArt", 840),
        ("PixelWarrior", 720),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(leaders.enumerated()), id: \.offset) { idx, leader in
                HStack(spacing: 12) {
                    Text("#\(idx + 1)")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(
                            idx == 0 ? .yellow :
                            idx == 1 ? Color(hex: "9CA3AF") :
                            idx == 2 ? Color(hex: "B45309") :
                            .gray
                        )
                        .frame(width: 24)
                    
                    Text(leader.0)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Text("\(leader.1) pts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                
                if idx < leaders.count - 1 {
                    Divider()
                        .background(Color.white.opacity(0.04))
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

struct ChallengeItem {
    let id: String
    let title: String
    let entries: Int
    let timeLeft: String
    let coins: Int
    let description: String
}
