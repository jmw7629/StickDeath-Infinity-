import SwiftUI
import AVKit

/// One challenge: brief, server-timed schedule, real eligible entries with
/// playback, the creator's own entry (one per creator, from approved
/// renditions) and one mutable favourite vote. Results come only from the
/// server's finalised record.
struct ChallengeDetailView: View {
    let challenge: ChallengeSummary
    var clock: ChallengeClock?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared
    @State private var entries: [ChallengeEntry] = []
    @State private var phase: ChallengePhase?
    @State private var media: [ApprovedMedia] = []
    @State private var selection = ""
    @State private var player: AVPlayer?
    @State private var playing: UUID?
    @State private var pendingVote: UUID?
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var epoch = UUID()
    private var viewer: UUID? { auth.userId.flatMap(UUID.init(uuidString:)) }
    private var serverNow: Date { clock?.now(deviceNow: Date()) ?? Date() }
    private var currentPhase: ChallengePhase { phase ?? challenge.phase(at: serverNow) }
    private var myEntry: ChallengeEntry? { entries.first { $0.creator == viewer } }
    private var isParticipant: Bool { myEntry != nil || challenge.my_entry }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(challenge.title).communityHeading()
                    Text("Phase: \(currentPhase.title) (server time)").communityCaption()
                    if !challenge.brief.isEmpty { Text(challenge.brief).font(.specialElite(14, relativeTo: .body)) }
                    CommunityCard {
                        Text("Schedule").communitySubheading()
                        if let starts = challenge.starts_at { Text("Opens: \(starts.formatted(date: .abbreviated, time: .shortened))").font(.specialElite(13, relativeTo: .footnote)) }
                        if let closes = challenge.submissions_close_at { Text("Submissions close: \(closes.formatted(date: .abbreviated, time: .shortened))").font(.specialElite(13, relativeTo: .footnote)) }
                        if let ends = challenge.voting_ends_at { Text("Voting ends: \(ends.formatted(date: .abbreviated, time: .shortened))").font(.specialElite(13, relativeTo: .footnote)) }
                        Text("Times shown in \(TimeZone.current.identifier).").communityCaption()
                        if challenge.hasReward { Text("Reward (as configured): \(challenge.reward_text)").communityCaption() }
                        else { Text("No reward is configured for this challenge.").communityCaption() }
                        Text("Rules: enter your own approved, rights-cleared rendition; one entry per creator; viewers who did not enter cast one favourite vote, which they may change until voting ends. Ties record no winner.")
                            .communityCaption()
                    }
                    if let error { CommunityMessage(text: error, kind: .error).accessibilityIdentifier("challenges.detail.error") }
                    if let notice { CommunityMessage(text: notice, kind: .success) }
                    if busy { ProgressView().tint(StudioCraftTheme.accent) }
                    if let outcome = challenge.outcomeText {
                        CommunityCard {
                            Text("Result").communitySubheading()
                            Text(outcome).font(.specialElite(15, relativeTo: .body))
                            if let winner = challenge.winner_entry, let entry = entries.first(where: { $0.id == winner }) {
                                Text("Winning entry: \(entry.title)").font(.specialElite(14, relativeTo: .body))
                            }
                        }.accessibilityIdentifier("challenges.detail.result")
                    }
                    entryCard
                    if let player, let playing, let entry = entries.first(where: { $0.id == playing }) {
                        VideoPlayer(player: player).frame(minHeight: 220).accessibilityLabel("Playing \(entry.title)")
                    }
                    Text("Entries").communitySubheading()
                    if loaded && entries.isEmpty && error == nil { Text("No eligible entries yet.").communityCaption().accessibilityIdentifier("challenges.detail.empty") }
                    ForEach(entries) { entry in entryRow(entry) }
                    Button("Refresh entries") { Task { await load() } }
                        .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("challenges.detail.refresh")
                }.padding(16)
            }
            .communityScreen()
            .navigationTitle("Challenge").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(challenge.id):\(auth.userId ?? "none")") {
            epoch = UUID(); entries = []; phase = nil; media = []; loaded = false; error = nil; notice = nil; stop()
            await load()
        }
        .onDisappear { stop() }
    }

    private var entryCard: some View {
        CommunityCard {
            Text("Your entry").communitySubheading()
            if let mine = myEntry {
                Text(mine.title).font(.specialElite(15, relativeTo: .body))
                if currentPhase != .completed {
                    Button("Withdraw entry") { Task { await act("Entry withdrawn; its votes were removed.") { try await CommunityServices.challenges.withdraw(entry: mine.id) } } }
                        .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).disabled(busy)
                        .accessibilityIdentifier("challenges.detail.withdraw")
                }
            } else if currentPhase == .active {
                Picker("Approved video", selection: $selection) {
                    Text("Select your approved video").tag("")
                    ForEach(media) { Text($0.title).tag($0.id.uuidString) }
                }.pickerStyle(.menu).tint(StudioCraftTheme.accentText)
                    .accessibilityIdentifier("challenges.detail.submit-picker")
                if media.isEmpty { Text("Publish a rights-cleared, approved rendition before entering.").communityCaption() }
                Button("Submit entry") {
                    guard let id = UUID(uuidString: selection) else { return }
                    Task { await act("Entry recorded.") { try await CommunityServices.challenges.submit(challenge: challenge.id, media: id) } }
                }
                .buttonStyle(CommunityPrimaryButtonStyle()).disabled(busy || UUID(uuidString: selection) == nil)
                .accessibilityIdentifier("challenges.detail.submit")
            } else {
                Text(currentPhase == .upcoming ? "Submissions open when the challenge starts." : "Submissions are closed.").communityCaption()
            }
        }
    }
    private func entryRow(_ entry: ChallengeEntry) -> some View {
        CommunityCard(selected: playing == entry.id) {
            Text(entry.title).font(.specialElite(16, relativeTo: .body))
            Text("\(entry.creator == viewer ? "Your entry" : "Creator \(communityShortID(entry.creator))") · \(entry.created_at.formatted(date: .abbreviated, time: .shortened))").communityCaption()
            if let votes = entry.votes { Text("\(votes) \(votes == 1 ? "vote" : "votes")").font(.specialElite(13, relativeTo: .footnote)).monospacedDigit() }
            HStack(spacing: 8) {
                Button(playing == entry.id ? "Playing" : "Play") { play(entry) }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(playing == entry.id)
                    .accessibilityIdentifier("challenges.detail.play")
                if currentPhase == .voting && !isParticipant {
                    Button {
                        Task { await vote(entry) }
                    } label: {
                        Label(entry.my_vote ? "Your favourite" : "Choose as favourite",
                              systemImage: entry.my_vote ? "checkmark.circle.fill" : pendingVote == entry.id ? "clock" : "circle")
                    }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy || pendingVote != nil || entry.my_vote)
                    .accessibilityAddTraits(entry.my_vote ? .isSelected : [])
                    .accessibilityIdentifier("challenges.detail.vote")
                }
            }
        }
    }
    private func play(_ entry: ChallengeEntry) {
        guard let url = entry.safeURL else { error = "Video address is unavailable."; return }
        player?.pause(); player = AVPlayer(url: url); playing = entry.id; player?.play()
    }
    private func stop() { player?.pause(); player = nil; playing = nil }

    @MainActor private func load() async {
        guard auth.isAuthenticated, let account = viewer else { return }
        let revision = epoch
        busy = true; defer { if revision == epoch { busy = false } }
        do {
            let result = try await CommunityServices.challenges.entries(challenge: challenge.id)
            guard !Task.isCancelled, revision == epoch else { return }
            entries = result.entries; phase = result.phase; loaded = true; error = nil
            if (result.phase ?? currentPhase) == .active, !entries.contains(where: { $0.creator == account }) {
                media = try await CommunityServices.warRoom.ownedMedia(account: account)
            }
        } catch { if revision == epoch { entries = []; loaded = true; self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    @MainActor private func act(_ success: String, _ operation: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        let revision = epoch; busy = true; error = nil; notice = nil
        defer { if revision == epoch { busy = false } }
        do { try await operation(); guard revision == epoch else { return }; notice = success; busy = false; await load() }
        catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    @MainActor private func vote(_ entry: ChallengeEntry) async {
        guard pendingVote == nil else { return }
        pendingVote = entry.id
        let revision = epoch
        defer { if revision == epoch { pendingVote = nil } }
        do {
            try await CommunityServices.challenges.vote(challenge: challenge.id, entry: entry.id)
            guard revision == epoch else { return }
            notice = "Favourite recorded. You can change it until voting ends."; await load()
        } catch { if revision == epoch { error = CommunityGateway.normalize(error).errorDescription } }
    }
}
