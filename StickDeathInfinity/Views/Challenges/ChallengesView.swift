import SwiftUI

/// Scheduled community challenges from `sdi_challenge_action`. Phases come
/// from the server clock, entry counts are server totals, and reward text is
/// shown only when a moderator configured one. No coins, prizes or money.
struct ChallengesView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var selectedPhase: ChallengePhase = .active
    @State private var challenges: [ChallengeSummary] = []
    @State private var clock: ChallengeClock?
    @State private var tick = Date()
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selected: ChallengeSummary?
    @State private var epoch = UUID()
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active)" }
    private var serverNow: Date { clock?.now(deviceNow: tick) ?? tick }
    private var visible: [ChallengeSummary] { challenges.filter { $0.phase(at: serverNow) == selectedPhase } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Challenges").communityHeading()
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .disabled(busy).accessibilityLabel("Refresh challenges")
                    .accessibilityIdentifier("challenges.list.refresh")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ChallengePhase.listed, id: \.self) { phaseOption in
                        Button(phaseOption.title) { selectedPhase = phaseOption }
                            .font(.specialElite(13, relativeTo: .footnote))
                            .padding(.horizontal, 14).frame(minHeight: 40)
                            .background(selectedPhase == phaseOption ? StudioCraftTheme.accent : StudioCraftTheme.card)
                            .foregroundStyle(Color.white)
                            .clipShape(Capsule())
                            .accessibilityAddTraits(selectedPhase == phaseOption ? .isSelected : [])
                            .accessibilityIdentifier("challenges.filter." + phaseOption.rawValue)
                    }
                }.padding(.horizontal, 16)
            }.padding(.bottom, 8)
            Divider().background(StudioCraftTheme.separator)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !CommunityServices.isConfigured { CommunityMessage(text: CommunityServices.notConfiguredText, kind: .info) }
                    if !auth.isAuthenticated {
                        CommunitySignInPrompt(text: "Sign in to see scheduled challenges", identifier: "challenges.sign-in")
                    }
                    if busy { ProgressView().tint(StudioCraftTheme.accent) }
                    if let error { CommunityMessage(text: error, kind: .error).accessibilityIdentifier("challenges.list.error") }
                    if let clock { Text("Phases use the server clock (\(clock.serverTime.formatted(date: .omitted, time: .shortened)) at last refresh).").communityCaption() }
                    ForEach(visible) { challenge in
                        ChallengeCard(challenge: challenge, serverNow: serverNow) { selected = challenge }
                    }
                    if auth.isAuthenticated && loaded && !busy && visible.isEmpty && error == nil {
                        Text("No \(selectedPhase.title.lowercased()) challenges.").communityCaption().padding()
                            .accessibilityIdentifier("challenges.list.empty")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12).padding(.bottom, 60)
            }
        }
        .communityScreen()
        .task(id: identity) {
            epoch = UUID(); challenges = []; clock = nil; loaded = false; error = nil; selected = nil
            if phase == .active { await load() }
            // Recompute phases against the server anchor without re-fetching.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                tick = Date()
            }
        }
        .refreshable { await load() }
        .sheet(item: $selected) { challenge in
            ChallengeDetailView(challenge: challenge, clock: clock)
        }
    }
    @MainActor private func load() async {
        guard !busy, auth.isAuthenticated, let account = auth.userId else { return }
        let revision = epoch
        busy = true; defer { if revision == epoch { busy = false } }
        do {
            let listing = try await CommunityServices.challenges.list()
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            challenges = listing.challenges; clock = listing.clock; tick = Date(); loaded = true; error = nil
        } catch {
            if revision == epoch { challenges = []; clock = nil; loaded = true; self.error = CommunityGateway.normalize(error).errorDescription }
        }
    }
}

struct ChallengeCard: View {
    let challenge: ChallengeSummary
    let serverNow: Date
    let onTap: () -> Void
    private var phase: ChallengePhase { challenge.phase(at: serverNow) }
    private var timing: String {
        switch phase {
        case .upcoming: return challenge.starts_at.map { "Opens \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Start not scheduled"
        case .active: return challenge.submissions_close_at.map { "Submissions close \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        case .voting: return challenge.voting_ends_at.map { "Voting ends \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        case .completed: return challenge.voting_ends_at.map { "Ended \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Ended"
        case .cancelled: return "Cancelled"
        case .draft: return "Not scheduled"
        }
    }
    var body: some View {
        Button(action: onTap) {
            CommunityCard {
                HStack(alignment: .top) {
                    Text(challenge.title).font(.specialElite(18, relativeTo: .title3)).foregroundStyle(StudioCraftTheme.text)
                    Spacer()
                    Text(phase.title).font(.specialElite(11, relativeTo: .caption2))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(StudioCraftTheme.accentSoft).foregroundStyle(StudioCraftTheme.accentText)
                        .clipShape(Capsule())
                }
                if !challenge.brief.isEmpty { Text(challenge.brief).font(.specialElite(13, relativeTo: .footnote)).foregroundStyle(StudioCraftTheme.textDim).lineLimit(3) }
                HStack(spacing: 14) {
                    Label("\(challenge.entry_count) \(challenge.entry_count == 1 ? "entry" : "entries")", systemImage: "person.2")
                    Label(timing, systemImage: "clock")
                }.font(.specialElite(12, relativeTo: .caption)).foregroundStyle(StudioCraftTheme.textDim)
                if challenge.hasReward { Text("Reward (as configured): \(challenge.reward_text)").communityCaption() }
                if challenge.my_entry { Text("You have an entry in this challenge.").communityCaption() }
                if let outcome = challenge.outcomeText { Text(outcome).font(.specialElite(13, relativeTo: .footnote)).foregroundStyle(StudioCraftTheme.accentText) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("challenges.list.card")
    }
}
