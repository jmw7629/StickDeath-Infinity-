import SwiftUI

struct ChallengesView: View {
    @State private var selectedFilter = "active"
    @State private var challenges: [Challenge] = []
    @State private var isLoading = false
    @State private var loadError: String?
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
                    ForEach(["active", "upcoming", "voting", "completed"], id: \.self) { filter in
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
                        if isLoading { ProgressView().tint(.red) }
                        if let loadError { Text(loadError).font(.caption).foregroundColor(.gray) }
                        if !isLoading && challenges.filter({ $0.presentationStatus == selectedFilter }).isEmpty {
                            Text(selectedFilter == "voting" ? "Voting challenges are unavailable from the current service." : "No challenges in this category.")
                                .font(.callout).foregroundColor(.gray).padding()
                        }
                        ForEach(challenges.filter { $0.presentationStatus == selectedFilter }) { challenge in
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
        .task { await loadChallenges() }
        .refreshable { await loadChallenges() }
        .sheet(item: $selectedChallenge) { challenge in
            ChallengeDetailView(challenge: challenge)
        }
    }
    @MainActor private func loadChallenges() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            challenges = try await ChallengeService.shared.fetchChallenges()
            loadError = nil
        } catch {
            loadError = "Challenges could not be loaded. Check your connection and account configuration."
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
                            Text("Prize")
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
                        Text(challenge.entriesLabel)
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

// The inline route shares the canonical detail view and Challenge model.
struct InlineChallengeDetailView: View {
    let challenge: Challenge
    var body: some View { ChallengeDetailView(challenge: challenge) }
}

extension Challenge {
    var presentationStatus: String { status == .ended ? "completed" : (status?.rawValue ?? "unknown") }
    var gradientStart: String { status == .upcoming ? "581C87" : status == .ended ? "713F12" : "7F1D1D" }
    var gradientEnd: String { status == .upcoming ? "7C3AED" : status == .ended ? "B45309" : "991B1B" }
    var emoji: String { "🏆" }
    var reward: String { prizeDescription ?? "Not specified" }
    var entriesLabel: String { submissionCount.map { "\($0) entries" } ?? "Entries unavailable" }
    var timeLeft: String {
        if status == .ended { return "Ended" }
        guard let raw = status == .upcoming ? startDate : endDate else { return "Date unavailable" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsedDate = parser.date(from: raw)
        if parsedDate == nil {
            parser.formatOptions = [.withInternetDateTime]
            parsedDate = parser.date(from: raw)
        }
        guard let date = parsedDate else { return "Date unavailable" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ChallengesView_Previews: PreviewProvider {
    static var previews: some View {
        ChallengesView()
    }
}
