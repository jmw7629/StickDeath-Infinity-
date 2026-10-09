import SwiftUI
import AVKit
import Supabase

struct WarRoomView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var matches: [WarMatch] = []
    @State private var videos: [WarVideo] = []
    @State private var selection = ""
    @State private var opponent = ""
    @State private var agreed = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var playback: WarPlayback?
    @State private var reporting: WarMatch?
    @State private var reportReason = ""
    @State private var epoch = UUID()
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active)" }
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("War Room").font(.specialElite(24))
                Text("Watch both videos and pick your favorite. One current vote per viewer; participants cannot vote on their own matchup. Voting lasts 24 hours after both creators agree.")
                    .foregroundColor(.sdTextSecondary)
                if let error { Text(error).foregroundColor(.sdRed) }
                if let notice { Text(notice).foregroundColor(.sdTextSecondary) }
                if busy { ProgressView() }
                if auth.isAuthenticated {
                    NavigationLink("Leaderboard") { LeaderboardView() }
                    WarNoticesView()
                    submission
                    Button("Refresh matchups") { Task { await load() } }.disabled(busy)
                    ForEach(matches) { match in card(match) }
                    if matches.isEmpty && !busy { Text("No available matchups.").foregroundColor(.sdTextSecondary) }
                } else { Label("Sign in to participate", systemImage: "lock") }
            }.padding(16).padding(.bottom, 60)
        }
        .foregroundColor(.sdTextPrimary).background(Color.sdBackground.ignoresSafeArea())
        .navigationTitle("War Room").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: identity) {
            epoch = UUID(); matches = []; videos = []; playback?.player.pause(); playback = nil
            reporting = nil; reportReason = ""
            error = nil; notice = nil
            if phase == .active { await load() }
        }
        .refreshable { await load() }
        .sheet(item: $playback, onDismiss: { playback?.player.pause() }) { item in
            VideoPlayer(player: item.player).onAppear { item.player.play() }.onDisappear { item.player.pause() }
        }
        .sheet(item: $reporting) { match in
            NavigationStack {
                Form {
                    Text("Report a video, voting abuse or another issue in this matchup. Reports are reviewed by administrators, not posted publicly.")
                    TextField("What happened?", text: $reportReason, axis: .vertical).lineLimit(4...10)
                    Button("Submit report") { Task { await submitReport(match.id) } }
                        .disabled(busy || reportReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reportReason.count > 2000)
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle("Report matchup")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reporting = nil } } }
            }
        }
        .onDisappear { playback?.player.pause(); playback = nil }
        .accessibilityIdentifier("warRoom.screen")
    }
    private var submission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your approved video").font(.specialElite(18))
            Picker("Video", selection: $selection) {
                Text("Select video").tag("")
                ForEach(videos) { Text($0.title).tag($0.id.uuidString) }
            }
            if videos.isEmpty { Text("Publish a rights-cleared, approved rendition before submitting.").font(.caption) }
            TextField("Opponent account ID", text: $opponent)
                .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            Toggle("I agree to submit this approved video under the voting rules above.", isOn: $agreed)
            Button("Propose matchup") {
                Task { await action(WarAction(action: "propose", media: UUID(uuidString: selection), opponent: UUID(uuidString: opponent))) }
            }.disabled(busy || !agreed || UUID(uuidString: opponent) == nil || selection.isEmpty)
        }.padding().background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private func card(_ match: WarMatch) -> some View {
        let participant = [match.creator,match.opponent].contains { $0.uuidString.lowercased() == auth.userId?.lowercased() }
        let ended = match.ends_at.map { $0 <= Date() } ?? false
        return VStack(alignment: .leading, spacing: 12) {
            Text(match.status == "pending" ? "Awaiting opponent consent" : match.status == "completed" ? "Final result" : ended ? "Awaiting server result" : "Choose your favorite")
                .font(.specialElite(18))
            Button { play(match.left_url) } label: { Label(match.left_title, systemImage: "play.circle.fill") }
            if let title = match.right_title, let url = match.right_url {
                Button { play(url) } label: { Label(title, systemImage: "play.circle.fill") }
            }
            if let end = match.ends_at { Text("Closes \(end.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
            if match.status == "active" || match.status == "completed" {
                Text("\(match.left_votes) · \(match.right_votes) votes").font(.specialElite(16))
                if match.status == "completed" {
                    Text(match.outcome == "tie" ? "Tie — no winner or loser" : match.outcome == "left" ? "Winner: \(match.left_title)" : match.outcome == "right" ? "Winner: \(match.right_title ?? "Second video")" : "Result unavailable")
                        .font(.specialElite(17))
                }
                if match.status == "active" && !participant && !ended {
                    HStack {
                        voteButton("First video", "left", match)
                        voteButton("Second video", "right", match)
                    }
                }
            }
            if match.status == "pending", match.opponent.uuidString.lowercased() == auth.userId?.lowercased() {
                Button("Accept with my selected video") {
                    Task { await action(WarAction(action: "accept", match: match.id, media: UUID(uuidString: selection))) }
                }.disabled(busy || !agreed || selection.isEmpty)
            }
            if participant && !ended {
                Button("Withdraw matchup", role: .destructive) { Task { await action(WarAction(action: "withdraw", match: match.id)) } }.disabled(busy)
            }
            Button("Report matchup") { reportReason = ""; error = nil; reporting = match }.disabled(busy)
        }.padding().background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private func voteButton(_ title: String, _ choice: String, _ match: WarMatch) -> some View {
        Button {
            Task { await action(WarAction(action: "vote", match: match.id, choice: choice)) }
        } label: {
            Label(title, systemImage: match.my_vote == choice ? "checkmark.circle.fill" : "circle")
        }.disabled(busy).accessibilityAddTraits(match.my_vote == choice ? .isSelected : [])
    }
    private func play(_ value: String) {
        guard let parts = URLComponents(string: value), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, let url = parts.url else { error = "Video address is unavailable."; return }
        playback?.player.pause(); playback = WarPlayback(player: AVPlayer(url: url))
    }
    @MainActor private func load() async {
        guard auth.isAuthenticated, let account = auth.userId else { return }
        let revision = epoch
        do {
            let response: WarResponse = try await client.rpc("sdi_war_action", params: WarAction(action: "list")).execute().value
            let owned: [WarVideo] = try await client.from("sdi_watch_media").select("id,title").eq("owner_id", value: account).limit(100).execute().value
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            if let problem = response.error { matches = []; error = problem; return }
            matches = response.matches ?? []; videos = owned; error = nil
        } catch { if revision == epoch { matches = []; videos = []; self.error = "War Room could not be refreshed. Check your connection and service configuration." } }
    }
    @MainActor private func action(_ payload: WarAction) async {
        guard !busy, auth.isAuthenticated else { return }
        let revision = epoch; busy = true; notice = nil
        defer { busy = false }
        do {
            let response: WarResponse = try await client.rpc("sdi_war_action", params: payload).execute().value
            guard !Task.isCancelled, revision == epoch else { return }
            if let problem = response.error { error = problem; return }
            guard response.status == "confirmed" else { error = "Operation was not confirmed."; return }
            notice = "Saved by the server."; await load()
        } catch { if revision == epoch { self.error = "Operation was not confirmed. Refresh before retrying." } }
    }
    @MainActor private func submitReport(_ match: UUID) async {
        guard !busy, auth.isAuthenticated else { return }
        let revision = epoch; busy = true
        defer { busy = false }
        do {
            let response: WarResponse = try await client.rpc("sdi_war_report", params: WarReportRequest(match: match, reason: reportReason)).execute().value
            guard !Task.isCancelled, revision == epoch else { return }
            guard response.error == nil, response.status == "recorded" else { error = response.error ?? "Report was not confirmed."; return }
            reporting = nil; reportReason = ""; notice = "Report received for administrator review."
        } catch { if revision == epoch { self.error = "Report not confirmed. Refresh before retrying." } }
    }
}
private struct WarReportRequest: Encodable { let match: UUID; let reason: String }
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
        DisclosureGroup("Your matchup notices") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Refresh notices") { Task { await request("list") } }.disabled(busy)
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice.message)
                        Text("Match \(notice.match_id.uuidString.prefix(8)) · \(notice.created_at.formatted())").font(.caption)
                        if let state = notice.appeal_state { Text("Appeal: \(state)").font(.caption) }
                        else if notice.appeal_deadline > Date() {
                            Button("Appeal this decision") { selected = notice; explanation = "" }.disabled(busy)
                        }
                    }.padding(.vertical, 8)
                }
                if let selected {
                    Text("Appeal matchup \(selected.match_id.uuidString.prefix(8))").font(.specialElite(16))
                    TextField("Explain why this decision should be reviewed", text: $explanation, axis: .vertical).lineLimit(3...8)
                    Button("Submit appeal") { Task { await request("appeal") } }
                        .disabled(busy || explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || explanation.count > 2000)
                    Button("Cancel") { self.selected = nil; explanation = "" }.disabled(busy)
                }
            }
        }
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
            let client = try SupabaseManager.shared.client
            let response: WarNoticesResponse = try await client.rpc("sdi_war_notices", params: WarNoticeRequest(action: action, decision: selected?.id, explanation: explanation)).execute().value
            guard !Task.isCancelled, requestID == id else { return }
            if let problem = response.error { error = problem; return }
            if action == "list", let items = response.notices { notices = items; selected = nil; error = nil }
            else if response.status == "recorded" { busy = false; await request("list") }
            else { error = "Response unavailable. Refresh before retrying." }
        } catch { if requestID == id { notices = []; selected = nil; self.error = "Notices unavailable. Check your connection." } }
    }
}
private struct WarNoticeRequest: Encodable { let action: String; let decision: UUID?; let explanation: String }
private struct WarNoticesResponse: Decodable { let error: String?; let status: String?; let notices: [WarNotice]? }
private struct WarNotice: Decodable, Identifiable {
    let id: UUID; let match_id: UUID; let message: String; let created_at: Date; let appeal_state: String?; let appeal_deadline: Date
}
private struct WarPlayback: Identifiable { let id = UUID(); let player: AVPlayer }
private struct WarVideo: Decodable, Identifiable { let id: UUID; let title: String }
private struct WarAction: Encodable {
    let action: String
    var match: UUID? = nil; var media: UUID? = nil; var opponent: UUID? = nil; var choice: String? = nil
}
private struct WarResponse: Decodable { let status: String?; let error: String?; let matches: [WarMatch]? }
private struct WarMatch: Decodable, Identifiable {
    let id: UUID; let creator: UUID; let opponent: UUID; let status: String; let ends_at: Date?
    let left_title: String; let left_url: String; let right_title: String?; let right_url: String?
    let left_votes: Int; let right_votes: Int; let my_vote: String?
    let outcome: String?
}
