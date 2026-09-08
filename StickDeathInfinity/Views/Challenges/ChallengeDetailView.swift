import SwiftUI

struct ChallengeDetailView: View {
    let challenge: Challenge
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: ChallengeTab = .submissions
    @State private var submissions: [ChallengeSubmission] = []
    @State private var loadError: String?
    @State private var showSubmissionNotice = false
    
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
                        StatCard(value: challenge.submissionCount.map(String.init) ?? "—", label: "Entries", color: .red)
                        StatCard(value: challenge.timeLeft, label: "Left", color: .green)
                        StatCard(value: challenge.reward, label: "Prize", color: .yellow)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    // Description
                    VStack(alignment: .leading, spacing: 12) {
                        Text(challenge.description ?? "No description provided.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .lineSpacing(4)
                        
                        Text("Rules:")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            RuleRow(text: "Follow the rules in this challenge's description. Additional structured rules are not available from the service.")
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
                    
                    if let loadError { Text(loadError).font(.caption).foregroundColor(.gray).padding() }
                    // Tab content
                    if selectedTab == .submissions {
                        SubmissionsGrid(submissions: submissions)
                    } else {
                        LeaderboardList(submissions: submissions)
                    }
                }
            }
            
            // Submit button
            Button(action: { showSubmissionNotice = true }) {
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
        .task {
            do { submissions = try await ChallengeService.shared.fetchSubmissions(challengeID: challenge.id) }
            catch { loadError = "Submissions could not be loaded. Try again when connected." }
        }
        .alert("Submission unavailable", isPresented: $showSubmissionNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A rendered Studio file and the rights/consent submission flow are required. Nothing has been submitted.")
        }
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
    let submissions: [ChallengeSubmission]

    let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            if submissions.isEmpty { Text("No submissions available.").font(.caption).foregroundColor(.gray) }
            ForEach(submissions) { sub in
                VStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 32)).foregroundColor(.red)
                    Text("Submission #\(sub.id)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    Text(sub.voteCount.map { "\($0) votes" } ?? "Votes unavailable")
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
    let submissions: [ChallengeSubmission]
    private var leaders: [ChallengeSubmission] {
        submissions.filter { $0.voteCount != nil }.sorted { ($0.voteCount ?? 0) > ($1.voteCount ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if leaders.isEmpty { Text("No recorded votes available.").font(.caption).foregroundColor(.gray).padding() }
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
                    
                    Text("Submission #\(leader.id)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Text("\(leader.voteCount ?? 0) votes")
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
