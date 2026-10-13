import SwiftUI
import AVKit

/// War Room: a contest between two approved renditions. Both creators agree,
/// viewers watch both videos and cast one mutable authenticated vote, and the
/// server alone finalises the result. No invented opponents, viewers or scores.
struct WarRoomView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var matches: [WarMatch] = []
    @State private var videos: [ApprovedMedia] = []
    @State private var votes: [UUID: WarVoteMachine] = [:]
    @State private var players: [UUID: WarMatchPlayers] = [:]
    @State private var selection = ""
    @State private var opponent = ""
    @State private var agreed = false
    @State private var playbackMode: WarPlaybackMode?
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var reporting: WarMatch?
    @State private var blocking: WarMatch?
    @State private var reportReason = ""
    @State private var epoch = UUID()
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active)" }
    private var viewer: UUID? { auth.userId.flatMap(UUID.init(uuidString:)) }
    private var mode: WarPlaybackMode { playbackMode ?? (sizeClass == .regular ? .sideBySide : .sequential) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("War Room").communityHeading()
                Text("Watch both videos and pick your favorite. One current vote per viewer; participants cannot vote on their own matchup. Voting lasts 24 hours after both creators agree, and proposals expire after seven days.")
                    .font(.specialElite(14, relativeTo: .callout)).foregroundStyle(StudioCraftTheme.textDim)
                if !CommunityServices.isConfigured { CommunityMessage(text: CommunityServices.notConfiguredText, kind: .info) }
                if let error { CommunityMessage(text: error, kind: .error).accessibilityIdentifier("warRoom.error") }
                if let notice { CommunityMessage(text: notice, kind: .success).accessibilityIdentifier("warRoom.notice") }
                if busy { ProgressView().tint(StudioCraftTheme.accent) }
                if auth.isAuthenticated {
                    NavigationLink { LeaderboardView() } label: {
                        Label("Leaderboard", systemImage: "list.number").frame(minHeight: 44)
                    }.accessibilityIdentifier("warRoom.leaderboard-link")
                    WarNoticesView()
                    submission
                    Picker("Playback", selection: Binding(get: { mode }, set: { playbackMode = $0 })) {
                        ForEach(WarPlaybackMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("warRoom.playback.mode")
                    Button("Refresh matchups") { Task { await load() } }
                        .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("warRoom.refresh")
                    ForEach(matches) { match in card(match) }
                    if matches.isEmpty && loaded && !busy && error == nil {
                        Text("No available matchups.").communityCaption().accessibilityIdentifier("warRoom.empty")
                    }
                } else {
                    CommunitySignInPrompt(text: "Sign in to participate", identifier: "warRoom.sign-in")
                }
            }.padding(16).padding(.bottom, 60)
        }
        .communityScreen()
        .navigationTitle("War Room").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: identity) {
            epoch = UUID(); matches = []; videos = []; votes = [:]; stopPlayers(); loaded = false
            reporting = nil; blocking = nil; reportReason = ""; error = nil; notice = nil
            if phase == .active { await load() }
        }
        .refreshable { await load() }
        .sheet(item: $reporting) { match in
            NavigationStack {
                Form {
                    Text("Report a video, voting abuse or another issue in this matchup. Reports are reviewed by administrators, not posted publicly, and the reporter is not identified to participants.")
                    TextField("What happened?", text: $reportReason, axis: .vertical).lineLimit(4...10)
                        .accessibilityIdentifier("warRoom.report.reason")
                    Button("Submit report") { Task { await submitReport(match.id) } }
                        .disabled(busy || reportReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reportReason.count > 2000)
                        .accessibilityIdentifier("warRoom.report.submit")
                    if let error { Text(error).foregroundStyle(StudioCraftTheme.accentText) }
                }.navigationTitle("Report matchup")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reporting = nil } } }
            }.preferredColorScheme(.dark)
        }
        .confirmationDialog("Block this creator?", isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }), titleVisibility: .visible, presenting: blocking) { match in
            Button("Block creator", role: .destructive) { Task { await block(match) } }
            Button("Cancel", role: .cancel) { blocking = nil }
        } message: { _ in
            Text("Their matchups disappear from your War Room and open matchups between you are withdrawn. This does not report them.")
        }
        .onDisappear { stopPlayers() }
        .accessibilityIdentifier("warRoom.screen")
    }

    private var submission: some View {
        CommunityCard {
            Text("Your approved video").communitySubheading()
            Picker("Video", selection: $selection) {
                Text("Select video").tag("")
                ForEach(videos) { Text($0.title).tag($0.id.uuidString) }
            }.pickerStyle(.menu).tint(StudioCraftTheme.accentText)
                .accessibilityIdentifier("warRoom.submission.video")
            if videos.isEmpty { Text("Publish a rights-cleared, approved rendition before submitting.").communityCaption() }
            TextField("Opponent account ID", text: $opponent)
                .textInputAutocapitalization(.never).autocorrectionDisabled().communityField()
                .accessibilityIdentifier("warRoom.submission.opponent")
            Text("Ask the other creator for their account ID from their profile. There is no directory or matchmaking.").communityCaption()
            Toggle("I agree to submit this approved video under the voting rules above.", isOn: $agreed)
                .font(.specialElite(14, relativeTo: .body))
                .accessibilityIdentifier("warRoom.submission.agree")
            Button("Propose matchup") {
                guard let media = UUID(uuidString: selection), let target = UUID(uuidString: opponent) else { return }
                Task { await act("Proposal recorded. The other creator must accept with their own approved video.") {
                    try await CommunityServices.warRoom.propose(media: media, opponent: target, agreed: agreed)
                } }
            }
            .buttonStyle(CommunityPrimaryButtonStyle())
            .disabled(busy || !agreed || UUID(uuidString: opponent) == nil || UUID(uuidString: selection) == nil)
            .accessibilityIdentifier("warRoom.submission.propose")
        }
    }

    private func card(_ match: WarMatch) -> some View {
        let presentation = WarMatchPresentation(match: match, viewer: viewer, now: Date())
        let machine = votes[match.id] ?? WarVoteMachine(serverVote: match.my_vote)
        return CommunityCard {
            Text(presentation.heading).communitySubheading()
            if let end = match.ends_at {
                Text((match.ends_at ?? Date()) > Date() ? "Voting closes \(end.formatted(date: .abbreviated, time: .shortened))" : "Voting closed \(end.formatted(date: .abbreviated, time: .shortened))")
                    .communityCaption()
            }
            playback(match)
            if presentation.showsTallies {
                Text("\(match.left_votes) · \(match.right_votes) votes").font(.specialElite(16, relativeTo: .body)).monospacedDigit()
                    .accessibilityLabel("\(match.left_votes) votes for the first video, \(match.right_votes) for the second")
            }
            if let result = presentation.resultText { Text(result).font(.specialElite(17, relativeTo: .headline)).accessibilityIdentifier("warRoom.match.result") }
            if presentation.phase == .awaitingFinalisation {
                Text("The server finalises results after the deadline; running tallies are not a result.").communityCaption()
            }
            if presentation.canVote {
                HStack(spacing: 10) {
                    voteButton("First video", .left, match, machine)
                    voteButton("Second video", .right, match, machine)
                }
                if case .failed(let message, _) = machine.state { CommunityMessage(text: message, kind: .error) }
                if machine.isPending { Text("Sending your vote…").communityCaption() }
            }
            if presentation.canAccept {
                Button("Accept with my selected video") {
                    guard let media = UUID(uuidString: selection) else { return }
                    Task { await act("Matchup accepted. Voting is open for 24 hours.") {
                        try await CommunityServices.warRoom.accept(match: match.id, media: media, agreed: agreed)
                    } }
                }
                .buttonStyle(CommunityPrimaryButtonStyle())
                .disabled(busy || !agreed || UUID(uuidString: selection) == nil)
                .accessibilityIdentifier("warRoom.match.accept")
                Text("Choose your video and agree to the rules above first.").communityCaption()
            }
            HStack(spacing: 8) {
                if presentation.canWithdraw {
                    Button("Withdraw") { Task { await act("Matchup withdrawn.") { try await CommunityServices.warRoom.withdraw(match: match.id) } } }
                        .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).disabled(busy)
                        .accessibilityIdentifier("warRoom.match.withdraw")
                }
                Button("Report") { reportReason = ""; error = nil; reporting = match }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("warRoom.match.report")
                if !presentation.isParticipant {
                    Button("Block creator") { blocking = match }
                        .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).disabled(busy)
                        .accessibilityIdentifier("warRoom.match.block")
                }
            }
        }
    }

    /// Both renditions play on explicit taps only (no autoplay); side by side on
    /// wide layouts, one at a time on phones. Sound is per device.
    @ViewBuilder private func playback(_ match: WarMatch) -> some View {
        let current = players[match.id]
        if let current {
            if mode == .sideBySide, let right = current.right {
                HStack(spacing: 8) {
                    VideoPlayer(player: current.left).frame(minHeight: 160).accessibilityLabel("First video: \(match.left_title)")
                    VideoPlayer(player: right).frame(minHeight: 160).accessibilityLabel("Second video: \(match.right_title ?? "Second video")")
                }
            } else {
                VideoPlayer(player: current.active).frame(minHeight: 200)
                    .accessibilityLabel(current.showingRight ? "Second video: \(match.right_title ?? "Second video")" : "First video: \(match.left_title)")
            }
            HStack(spacing: 8) {
                Button(current.showingRight ? "Play first: \(match.left_title)" : "Playing first") { switchPlayer(match, right: false) }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(!current.showingRight && mode == .sequential)
                    .accessibilityIdentifier("warRoom.match.play-left")
                if current.right != nil {
                    Button(current.showingRight ? "Playing second" : "Play second: \(match.right_title ?? "Second video")") { switchPlayer(match, right: true) }
                        .buttonStyle(CommunitySecondaryButtonStyle()).disabled(current.showingRight && mode == .sequential)
                        .accessibilityIdentifier("warRoom.match.play-right")
                }
                Button(current.muted ? "Unmute" : "Mute") { toggleMute(match) }
                    .buttonStyle(CommunitySecondaryButtonStyle())
                    .accessibilityIdentifier("warRoom.match.mute")
            }
        } else {
            Button {
                startPlayers(match)
            } label: {
                Label(match.right_url == nil ? "Watch: \(match.left_title)" : "Watch both videos", systemImage: "play.circle.fill").frame(minHeight: 44)
            }.buttonStyle(CommunitySecondaryButtonStyle()).accessibilityIdentifier("warRoom.match.watch")
            Text(match.right_title.map { "\(match.left_title) vs \($0)" } ?? "\(match.left_title) · opponent video pending").communityCaption()
        }
    }
    private func voteButton(_ title: String, _ choice: WarVoteChoice, _ match: WarMatch, _ machine: WarVoteMachine) -> some View {
        Button {
            Task { await vote(match, choice) }
        } label: {
            Label(title, systemImage: machine.isSelected(choice) ? "checkmark.circle.fill" : machine.isPendingChoice(choice) ? "clock" : "circle")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(CommunitySecondaryButtonStyle())
        .disabled(busy || machine.isPending)
        .accessibilityAddTraits(machine.isSelected(choice) ? .isSelected : [])
        .accessibilityValue(machine.isSelected(choice) ? "Your current vote" : machine.isPendingChoice(choice) ? "Pending confirmation" : "")
        .accessibilityIdentifier(choice == .left ? "warRoom.match.vote-left" : "warRoom.match.vote-right")
    }

    private func startPlayers(_ match: WarMatch) {
        guard let left = CommunityMediaURL.checked(match.left_url) else { error = "Video address is unavailable."; return }
        let right = CommunityMediaURL.checked(match.right_url).map { AVPlayer(url: $0) }
        var set = WarMatchPlayers(left: AVPlayer(url: left), right: right)
        set.apply(mode: mode)
        players[match.id] = set
    }
    private func switchPlayer(_ match: WarMatch, right: Bool) {
        guard var set = players[match.id] else { return }
        set.showingRight = right && set.right != nil
        set.apply(mode: mode)
        players[match.id] = set
    }
    private func toggleMute(_ match: WarMatch) {
        guard var set = players[match.id] else { return }
        set.muted.toggle(); set.apply(mode: mode); players[match.id] = set
    }
    private func stopPlayers() {
        for set in players.values { set.left.pause(); set.right?.pause() }
        players = [:]
    }

    @MainActor private func load() async {
        guard auth.isAuthenticated, let account = viewer else { return }
        let revision = epoch
        busy = true; defer { if revision == epoch { busy = false } }
        do {
            let list = try await CommunityServices.warRoom.matches()
            let owned = try await CommunityServices.warRoom.ownedMedia(account: account)
            guard !Task.isCancelled, revision == epoch, account == viewer else { return }
            matches = list; videos = owned; loaded = true; error = nil
            votes = Dictionary(uniqueKeysWithValues: list.map { ($0.id, WarVoteMachine(serverVote: $0.my_vote)) })
            let live = Set(list.map(\.id))
            for key in players.keys where !live.contains(key) { players[key]?.left.pause(); players[key]?.right?.pause(); players[key] = nil }
        } catch {
            if revision == epoch { matches = []; videos = []; loaded = true; self.error = CommunityGateway.normalize(error).errorDescription }
        }
    }
    @MainActor private func act(_ success: String, _ operation: @MainActor () async throws -> Void) async {
        guard !busy, auth.isAuthenticated else { return }
        let revision = epoch; busy = true; notice = nil; error = nil
        defer { if revision == epoch { busy = false } }
        do { try await operation(); guard revision == epoch else { return }; notice = success; busy = false; await load() }
        catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
    /// Pending until the server confirms; a refusal restores the previous vote.
    @MainActor private func vote(_ match: WarMatch, _ choice: WarVoteChoice) async {
        guard auth.isAuthenticated else { return }
        var machine = votes[match.id] ?? WarVoteMachine(serverVote: match.my_vote)
        let previous = machine.serverChoice
        guard machine.tap(choice) else { return }
        votes[match.id] = machine
        let revision = epoch
        do {
            try await CommunityServices.warRoom.vote(match: match.id, choice: choice)
            guard revision == epoch else { return }
            machine.confirm(choice); votes[match.id] = machine
            await load()
        } catch {
            guard revision == epoch else { return }
            machine.fail(CommunityGateway.normalize(error).errorDescription ?? "Vote was not confirmed.", previous: previous)
            votes[match.id] = machine
        }
    }
    @MainActor private func block(_ match: WarMatch) async {
        blocking = nil
        guard let viewer else { return }
        let target = match.creator == viewer ? match.opponent : match.creator
        await act("Creator blocked. Their matchups are hidden from you.") { try await CommunityServices.warRoom.blockCreator(target) }
    }
    @MainActor private func submitReport(_ match: UUID) async {
        guard !busy, auth.isAuthenticated else { return }
        let revision = epoch; busy = true
        defer { if revision == epoch { busy = false } }
        do {
            try await CommunityServices.warRoom.report(match: match, reason: reportReason)
            guard revision == epoch else { return }
            reporting = nil; reportReason = ""; notice = "Report received for administrator review."
        } catch { if revision == epoch { self.error = CommunityGateway.normalize(error).errorDescription } }
    }
}

/// Per-matchup players: created on demand, paused when the card leaves.
private struct WarMatchPlayers {
    let left: AVPlayer
    let right: AVPlayer?
    var showingRight = false
    var muted = false
    var active: AVPlayer { showingRight ? (right ?? left) : left }
    func apply(mode: WarPlaybackMode) {
        left.isMuted = muted; right?.isMuted = muted
        if mode == .sideBySide, right != nil {
            left.play(); right?.play()
        } else {
            if showingRight { left.pause(); right?.play() } else { right?.pause(); left.play() }
        }
    }
}

/// Participant notices from moderation decisions and the appeal path.
@MainActor
private struct WarNoticesView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var notices: [WarNotice] = []
    @State private var selected: WarNotice?
    @State private var explanation = ""
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Button("Refresh notices") { Task { await request("list") } }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("warRoom.notices.refresh")
                if let error { CommunityMessage(text: error, kind: .error) }
                if busy { ProgressView().tint(StudioCraftTheme.accent) }
                if notices.isEmpty && !busy && error == nil { Text("No moderation notices for your matchups.").communityCaption() }
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice.message).font(.specialElite(14, relativeTo: .body))
                        Text("Match \(communityShortID(notice.match_id)) · \(notice.created_at.formatted())").communityCaption()
                        if let state = notice.appeal_state { Text("Appeal: \(state)").communityCaption() }
                        else if notice.appeal_deadline > Date() {
                            Button("Appeal this decision") { selected = notice; explanation = "" }
                                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                                .accessibilityIdentifier("warRoom.notices.appeal")
                        } else { Text("The 30-day appeal window has closed.").communityCaption() }
                    }.padding(.vertical, 8)
                }
                if let selected {
                    Text("Appeal matchup \(communityShortID(selected.match_id))").communitySubheading()
                    TextField("Explain why this decision should be reviewed", text: $explanation, axis: .vertical).lineLimit(3...8)
                        .communityField().accessibilityIdentifier("warRoom.notices.explanation")
                    HStack {
                        Button("Submit appeal") { Task { await request("appeal") } }
                            .buttonStyle(CommunityPrimaryButtonStyle())
                            .disabled(busy || explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || explanation.count > 2000)
                            .accessibilityIdentifier("warRoom.notices.submit")
                        Button("Cancel") { self.selected = nil; explanation = "" }
                            .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                    }
                }
            }
        } label: {
            Text("Your matchup notices").font(.specialElite(16, relativeTo: .body))
        }
        .tint(StudioCraftTheme.accentText)
        .task(id: "\(auth.userId ?? "none"):\(auth.isAuthenticated):\(phase == .active)") {
            clear(); if auth.isAuthenticated && phase == .active { await request("list") }
        }
        .onDisappear { clear() }
    }
    private func clear() { requestID = UUID(); busy = false; notices = []; selected = nil; explanation = ""; error = nil }
    private func request(_ action: String) async {
        guard !busy, auth.isAuthenticated, phase == .active else { return }
        let id = UUID(); requestID = id; busy = true
        defer { if requestID == id { busy = false } }
        do {
            if action == "appeal", let selected {
                try await CommunityServices.warRoom.appeal(decision: selected.id, explanation: explanation)
                guard requestID == id else { return }
                self.selected = nil; explanation = ""; busy = false; await request("list"); return
            }
            let items = try await CommunityServices.warRoom.notices()
            guard !Task.isCancelled, requestID == id else { return }
            notices = items; error = nil
        } catch { if requestID == id { if action == "list" { notices = [] }; self.error = CommunityGateway.normalize(error).errorDescription } }
    }
}
