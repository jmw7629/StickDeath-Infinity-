import SwiftUI
import AVKit
import Supabase

/// Uses the same accepted project-room membership as collaboration. No local
/// room invention, participant counts, chat, microphone or camera access.
struct WatchTogetherView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestSignIn) private var requestSignIn
    @State private var rooms: [WatchRoom] = []
    @State private var media: [WatchMedia] = []
    /// Read-only membership rows (account identifiers only). RLS returns the
    /// viewer's own row, or every row when the viewer owns the room.
    @State private var participants: [WatchParticipant] = []
    @State private var selected: WatchRoom?
    @State private var selectedMedia = ""
    @State private var state: WatchPlayback?
    @State private var player: AVPlayer?
    @State private var loadedMedia: UUID?
    @State private var error: String?
    @State private var busy = false
    @State private var seekPosition = 0.0
    @State private var seeking = false
    @State private var refresh = 0
    @State private var generation = UUID()
    @State private var localMuted = false
    @State private var localVolume = 1.0
    /// (server − device) clock offset estimated from reply `Date` headers so
    /// members on skewed clocks agree on the shared position within seconds.
    @State private var clock = ServerClockEstimator()

    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active):\(refresh)" }
    private var isHost: Bool { selected?.owner_id.uuidString.lowercased() == auth.userId?.lowercased() }
    private var currentMedia: WatchMedia? { media.first { $0.id == state?.media_id } }
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Watch Together").font(.specialElite(24))
                Text("Watch an approved video with the members of a shared room.")
                    .foregroundColor(.sdTextSecondary)
                if !auth.isAuthenticated {
                    Label("Sign in to view your rooms", systemImage: "lock")
                    Button("Sign In") { requestSignIn() }
                        .font(.specialElite(16)).foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.sdPrimaryGradient).cornerRadius(12)
                        .accessibilityIdentifier("watchTogether.sign-in")
                }
                if let error {
                    Text(error).foregroundColor(.sdRed)
                    Button("Reconnect") { refresh += 1 }.accessibilityIdentifier("watchTogether.reconnect")
                }
                if let selected {
                    HStack {
                        Text(selected.title).font(.specialElite(20))
                        Spacer()
                        Button("Leave") { leave() }.accessibilityIdentifier("watchTogether.leave")
                    }
                    if let player, let currentMedia {
                        VideoPlayer(player: player).frame(minHeight: 220)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Shared playback: \(currentMedia.title)")
                        Text(currentMedia.title).font(.specialElite(18))
                        localAudioControls
                        if isHost, let state {
                            Slider(value: $seekPosition, in: 0...max(1,currentMedia.duration), onEditingChanged: { editing in
                                seeking = editing
                                if !editing { Task { await control(position: seekPosition, playing: state.playing) } }
                            }).accessibilityLabel("Shared video position").accessibilityIdentifier("watchTogether.seek")
                            Button(state.playing ? "Pause for everyone" : "Play for everyone") {
                                Task { await control(position: finitePosition(), playing: !state.playing) }
                            }.disabled(busy).accessibilityIdentifier("watchTogether.play-pause")
                        } else {
                            Text("The host controls shared playback.").foregroundColor(.sdTextSecondary)
                        }
                        Text(clock.best == nil
                             ? "Position uses the server's last update time and this device's clock; the clock offset has not been measured yet, so members may drift by their clock skew."
                             : "Position uses the server's last update time and a measured clock offset of \(String(format: "%+.1f", clock.offset)) s (±\(String(format: "%.1f", clock.uncertainty)) s); a drift of a few seconds between members is expected.")
                            .font(.caption).foregroundColor(.sdTextSecondary)
                            .accessibilityIdentifier("watchTogether.clock")
                    } else if state == nil {
                        Text("No video selected in this room.")
                    }
                    participantList
                    if isHost {
                        Picker("Approved video", selection: $selectedMedia) {
                            Text("Choose video").tag("")
                            ForEach(media) { Text($0.title).tag($0.id.uuidString) }
                        }.accessibilityIdentifier("watchTogether.media-picker")
                        Button("Share selected video") { Task { await share() } }
                            .disabled(selectedMedia.isEmpty || busy)
                            .accessibilityIdentifier("watchTogether.share-video")
                        if media.isEmpty { Text("No approved videos are available.").foregroundColor(.sdTextSecondary) }
                    }
                } else {
                    if busy { ProgressView("Loading rooms…") }
                    ForEach(rooms) { room in
                        Button { leave(); selected = room; error = nil } label: {
                            Label(room.title, systemImage: "play.rectangle")
                                .font(.specialElite(18)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding().background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.accessibilityIdentifier("watchTogether.room")
                    }
                    if rooms.isEmpty && !busy && error == nil && auth.isAuthenticated {
                        Text("No accepted rooms yet. Join a collaboration room before watching together.")
                    }
                }
            }.padding(16).padding(.bottom, 60)
        }
        .foregroundColor(.sdTextPrimary).background(Color.sdBackground.ignoresSafeArea())
        .navigationTitle("Watch Together").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: identity) { await load() }
        .task(id: selected?.id) {
            guard let room = selected else { return }
            while !Task.isCancelled && selected?.id == room.id {
                await synchronize(room)
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
        .onDisappear { leave() }
        .accessibilityIdentifier("watchTogether.screen")
    }

    private var participantList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isHost ? "Members" : "Your membership").font(.specialElite(16))
            if participants.isEmpty {
                Text("No membership rows are visible for this room.").font(.caption).foregroundColor(.sdTextSecondary)
            }
            ForEach(participants) { member in
                HStack {
                    Text(member.user_id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Text(member.revoked ? "Removed" : member.owner_approved && member.member_accepted ? "Accepted" : "Pending")
                        .font(.caption).foregroundColor(.sdTextSecondary)
                }
            }
            Text("Shows account identifiers from room membership only. Presence, chat, microphone and camera are not part of Watch Together.")
                .font(.caption).foregroundColor(.sdTextSecondary)
        }
        .accessibilityIdentifier("watchTogether.participants")
    }

    private var localAudioControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    localMuted.toggle(); applyLocalAudio()
                } label: {
                    Label(localMuted ? "Unmute" : "Mute",
                          systemImage: localMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(minHeight: 44)
                }
                .accessibilityLabel(localMuted ? "Unmute this device" : "Mute this device")
                .accessibilityIdentifier("watchTogether.localMute")
                Slider(value: Binding(get: { localVolume }, set: { value in
                    guard value.isFinite else { return }
                    localVolume = min(1, max(0, value)); applyLocalAudio()
                }), in: 0...1)
                    .accessibilityLabel("Volume on this device")
                    .accessibilityValue("\(Int(localVolume * 100)) percent")
                    .accessibilityIdentifier("watchTogether.localVolume")
                Text("\(Int(localVolume * 100))%")
                    .font(.specialElite(12)).monospacedDigit()
            }
            Text("Sound controls affect only this device.")
                .font(.caption).foregroundColor(.sdTextSecondary)
        }
    }
    @MainActor private func applyLocalAudio() {
        player?.isMuted = localMuted
        player?.volume = Float(min(1, max(0, localVolume)))
    }
    @MainActor private func clearPlayback() {
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        state = nil; loadedMedia = nil; seeking = false; seekPosition = 0
    }
    @MainActor private func leave() {
        generation = UUID(); clearPlayback(); selected = nil; selectedMedia = ""; busy = false; participants = []; clock = ServerClockEstimator()
    }
    @MainActor private func isCurrent(_ room: WatchRoom, account: String?, epoch: UUID) -> Bool {
        !Task.isCancelled && generation == epoch && selected?.id == room.id &&
            auth.isAuthenticated && auth.userId == account && phase == .active
    }
    @MainActor private func load() async {
        leave(); rooms = []; media = []; error = nil
        guard auth.isAuthenticated, phase == .active, let account = auth.userId else { return }
        let epoch = generation
        busy = true; defer { if generation == epoch { busy = false } }
        do {
            let values: [WatchRoom] = try await client.from("sdi_rooms").select().eq("closed", value: false).limit(100).execute().value
            let videos: [WatchMedia] = try await client.from("sdi_watch_media").select().limit(100).execute().value
            guard !Task.isCancelled, generation == epoch, phase == .active, account == auth.userId, auth.isAuthenticated else { return }
            rooms = values; media = videos.filter { $0.validURL != nil && $0.duration.isFinite && $0.duration > 0 }
        } catch {
            guard !Task.isCancelled, generation == epoch, phase == .active, account == auth.userId else { return }
            self.error = "Watch Together is unavailable. Check your connection and room service configuration."
        }
    }
    @MainActor private func synchronize(_ room: WatchRoom) async {
        guard auth.isAuthenticated, phase == .active else { leave(); return }
        let account = auth.userId; let epoch = generation
        do {
            // Recheck room visibility every poll, even when no playback exists.
            let membership: [WatchRoom] = try await client.from("sdi_rooms").select().eq("id", value: room.id.uuidString).limit(1).execute().value
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            guard let refreshedRoom = membership.first, membership.count == 1 else { leave(); error = "Room access ended."; return }
            selected = refreshedRoom
            let members: [WatchParticipant] = try await client.from("sdi_room_members").select("user_id,owner_approved,member_accepted,revoked")
                .eq("room_id", value: room.id.uuidString).limit(100).execute().value
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            participants = members.sorted { $0.user_id.uuidString < $1.user_id.uuidString }
            let sentAt = Date()
            let playbackResponse: PostgrestResponse<[WatchPlayback]> = try await client.from("sdi_watch_sessions").select().eq("room_id", value: room.id.uuidString).limit(1).execute()
            let values = playbackResponse.value
            clock.record(sentAt: sentAt, receivedAt: Date(),
                         serverDate: playbackResponse.response.value(forHTTPHeaderField: "Date").flatMap(CommunityDates.parseHTTPDate))
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            guard let value = values.first else { clearPlayback(); return }
            // Rights withdrawal/expiry removes media immediately on the next poll.
            let videos: [WatchMedia] = try await client.from("sdi_watch_media").select().eq("id", value: value.media_id.uuidString).limit(1).execute().value
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            guard let video = videos.first, let url = video.validURL, value.position.isFinite,
                  video.duration.isFinite, video.duration > 0 else { leave(); error = "Shared video is no longer available."; return }
            media.removeAll { $0.id == video.id }; media.append(video)
            if loadedMedia != video.id { player?.pause(); player = AVPlayer(url: url); loadedMedia = video.id }
            applyLocalAudio()
            state = value; error = nil
            // `updated_at` is server time; the estimator converts this device's
            // clock to server time using the measured reply-header offset.
            let target = clock.sharedPosition(position: value.position, playing: value.playing, updatedAt: value.updated_at,
                                              duration: video.duration, deviceNow: Date())
            if !seeking {
                if abs(finitePosition()-target) > 0.75 { await player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                guard isCurrent(room, account: account, epoch: epoch) else { return }
                seekPosition = target
            }
            if value.playing && target < video.duration { player?.play() } else { player?.pause() }
        } catch {
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            clearPlayback()
            self.error = "Playback paused because room access could not be refreshed. Reconnecting…"
        }
    }
    private func finitePosition() -> Double {
        let position = player?.currentTime().seconds ?? 0
        return position.isFinite ? max(0, position) : 0
    }
    @MainActor private func control(position: Double, playing: Bool) async {
        guard !busy, isHost, let current = state, let room = selected, position.isFinite else { return }
        let epoch = generation; let account = auth.userId
        busy = true; defer { if generation == epoch { busy = false } }
        do {
            struct Change: Encodable { let position: Double; let playing: Bool }
            let rows: [WatchPlayback] = try await client.from("sdi_watch_sessions")
                .update(Change(position: min(currentMedia?.duration ?? 3600, max(0,position)), playing: playing))
                .eq("id", value: current.id.uuidString).eq("revision", value: current.revision).select().execute().value
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            guard rows.count == 1 else { error = "Playback changed elsewhere. Refreshing before the next control."; return }
            await synchronize(room)
        } catch {
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            self.error = "Playback change was not confirmed. Try again."
        }
    }
    @MainActor private func share() async {
        guard !busy, isHost, let room = selected, let mediaID = UUID(uuidString: selectedMedia), media.contains(where: {$0.id == mediaID}) else { return }
        let epoch = generation; let account = auth.userId
        busy = true; defer { if generation == epoch { busy = false } }
        do {
            struct Selection: Encodable { let room_id: UUID; let media_id: UUID; let position = 0.0; let playing = false }
            let value = Selection(room_id: room.id, media_id: mediaID)
            if let state {
                struct Replacement: Encodable { let media_id: UUID; let position = 0.0; let playing = false }
                let rows: [WatchPlayback] = try await client.from("sdi_watch_sessions").update(Replacement(media_id: mediaID))
                    .eq("id", value: state.id.uuidString).eq("revision", value: state.revision).select().execute().value
                guard isCurrent(room, account: account, epoch: epoch) else { return }
                guard rows.count == 1 else { error = "Session changed. Refresh before sharing."; return }
            } else {
                try await client.from("sdi_watch_sessions").insert(value).execute()
            }
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            await synchronize(room)
        } catch {
            guard isCurrent(room, account: account, epoch: epoch) else { return }
            self.error = "Video selection was not confirmed. Refresh and try again."
        }
    }
}

private struct WatchRoom: Decodable, Identifiable { let id: UUID; let owner_id: UUID; let title: String }
private struct WatchParticipant: Decodable, Identifiable {
    var id: UUID { user_id }
    let user_id: UUID; let owner_approved: Bool; let member_accepted: Bool; let revoked: Bool
}
private struct WatchPlayback: Decodable, Identifiable {
    let id: UUID; let media_id: UUID; let position: Double; let playing: Bool
    let revision: Int; let updated_at: Date
}
private struct WatchMedia: Decodable, Identifiable {
    let id: UUID; let title: String; let url: String; let duration: Double
    var validURL: URL? {
        guard let components = URLComponents(string: url), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}
