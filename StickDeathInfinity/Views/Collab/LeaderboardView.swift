import SwiftUI
import Supabase

/// Server-filtered records only. No persistent or offline leaderboard cache.
@MainActor
struct LeaderboardView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var leaders: [WarLeader] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var message: String?
    @State private var requestID = UUID()
    @State private var refreshedAt: Date?
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("War Room leaderboard").font(.specialElite(24))
                Text("Up to 100 creators who choose to show their records. Ranked by finalized wins; equal wins share a rank. Removed matches do not count.")
                    .font(.callout).foregroundStyle(Color.sdTextSecondary)
                Text("Manage your visibility in Profile → Records & badges.").font(.caption)
                if !auth.isAuthenticated { Label("Sign in to view records", systemImage: "lock") }
                else {
                    Button("Refresh records") { Task { await load() } }.disabled(busy)
                    if busy { ProgressView() }
                    if let message { Text(message).foregroundStyle(Color.sdRed) }
                    if loaded && leaders.isEmpty { Text("No public finalized records yet.") }
                    ForEach(leaders) { leader in
                        HStack(alignment: .top, spacing: 12) {
                            Text("#\(leader.rank)").font(.specialElite(22)).foregroundStyle(Color.sdRed)
                                .frame(minWidth: 44, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(leader.name).font(.specialElite(18))
                                Text("\(leader.wins) wins · \(leader.losses) losses · \(leader.ties) ties").font(.callout)
                                ForEach(leader.badges ?? []) { badge in
                                    Label(badge.title, systemImage: "seal").font(.caption)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if let refreshedAt {
                        Text("Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))").font(.caption)
                    }
                }
            }.padding()
        }.background(Color.sdBackground.ignoresSafeArea()).foregroundStyle(Color.sdTextPrimary)
            .navigationTitle("Leaderboard").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: identity) {
                clear()
                if phase == .active && auth.isAuthenticated { await load() }
            }
            .refreshable { await load() }
            .onDisappear { clear() }
            .accessibilityIdentifier("warRoom.leaderboard")
    }

    private func clear() {
        requestID = UUID(); leaders = []; busy = false; loaded = false; message = nil; refreshedAt = nil
    }
    private func load() async {
        guard !busy, phase == .active, auth.isAuthenticated, let account = auth.userId else { return }
        let id = UUID(); requestID = id; busy = true
        // Never retain previous records if their current visibility cannot be confirmed.
        leaders = []; loaded = false; message = nil; refreshedAt = nil
        defer { if requestID == id { busy = false } }
        do {
            let client = try SupabaseManager.shared.client
            let response: WarLeaderboardResponse = try await client.rpc("sdi_war_leaderboard").execute().value
            guard !Task.isCancelled, requestID == id, account == auth.userId, phase == .active else { return }
            guard response.error == nil, let rows = response.leaders, let date = response.generated_at else {
                message = response.error ?? "Records unavailable. Try refreshing."; return
            }
            leaders = rows; refreshedAt = date; loaded = true
        } catch {
            if requestID == id { message = "Records could not be refreshed. Check your connection and try again." }
        }
    }
}

private struct WarLeaderboardResponse: Decodable {
    let error: String?
    let leaders: [WarLeader]?
    let generated_at: Date?
}
private struct WarLeader: Decodable, Identifiable {
    let id: UUID
    let name: String
    let rank: Int
    let wins: Int
    let losses: Int
    let ties: Int
    let badges: [WarLeaderBadge]?
}
private struct WarLeaderBadge: Decodable, Identifiable {
    let id: UUID
    let title: String
}
