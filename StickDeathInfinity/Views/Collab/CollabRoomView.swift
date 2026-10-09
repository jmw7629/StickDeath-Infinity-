import SwiftUI
import Supabase

/// Membership UI contains no chat or calling. A code permits a request only;
/// accepted members still need owner approval before room data becomes visible.
struct CollabRoomView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var rooms: [RoomSummary] = []
    @State private var members: [RoomMember] = []
    @State private var selected: RoomSummary?
    @State private var title = ""
    @State private var code = ""
    @State private var invitation: String?
    @State private var preview: RoomActionResult?
    @State private var consent = false
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var epoch = UUID()
    private var client: SupabaseClient { get throws { try SupabaseManager.shared.client } }
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active)" }
    private var owner: Bool { selected?.owner_id.uuidString.lowercased() == auth.userId?.lowercased() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Rooms").font(.specialElite(24))
                    Text("Collaborate by agreement. Invitation codes never grant access on their own.")
                        .foregroundColor(.sdTextSecondary)
                    if !auth.isAuthenticated { Label("Sign in to create or join rooms", systemImage: "lock") }
                    if let failure { Text(failure).foregroundColor(.sdRed) }
                    if let message { Text(message).foregroundColor(.sdTextSecondary) }
                    if busy { ProgressView() }
                    if auth.isAuthenticated {
                        if let selected { roomControls(selected) }
                        else { browser }
                    }
                    NavigationLink { CalendarEventView() } label: { route("Calendar", "calendar") }
                        .accessibilityIdentifier("rooms.calendar")
                    NavigationLink { WatchTogetherView() } label: { route("Watch Together", "play.rectangle") }
                        .accessibilityIdentifier("rooms.watchTogether")
                    NavigationLink { WarRoomView() } label: { route("War Room", "flag.checkered") }
                        .accessibilityIdentifier("rooms.warRoom")
                    Text("Project editing synchronization is not connected yet. Creating a room does not upload or share your device projects.")
                        .font(.caption).foregroundColor(.sdTextSecondary)
                }.padding(16).padding(.bottom, 60)
            }
            .background(Color.sdBackground.ignoresSafeArea()).foregroundColor(.sdTextPrimary)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: identity) {
                epoch = UUID(); rooms = []; members = []; selected = nil
                invitation = nil; preview = nil; code = ""; consent = false; message = nil; failure = nil
                if phase == .active { await load() }
            }
            .refreshable { await load() }
        }
    }
    private func route(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.specialElite(18))
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private var browser: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Room name", text: $title).textFieldStyle(.roundedBorder)
            Button("Create room") { Task { await act("create", title: title, accepted: true) } }
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100)
            Divider()
            TextField("Invitation code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onChange(of: code) { _, _ in preview = nil; consent = false }
            Button("Review invitation") { Task { await act("preview", token: code) } }
                .disabled(busy || code.count != 64)
            if let preview {
                Text(preview.title ?? "Shared room").font(.specialElite(18))
                Toggle("I agree to join this room and let its owner see my account identifier.", isOn: $consent)
                Text("The owner must approve your request. No Studio project is shared by joining.")
                    .font(.caption).foregroundColor(.sdTextSecondary)
                Button("Request admission") { Task { await act("request", token: code, accepted: consent) } }
                    .disabled(!consent || busy)
            }
            Text("Your rooms").font(.specialElite(18))
            ForEach(rooms) { room in
                Button(room.title) { selected = room; invitation = nil; Task { await loadMembers(room) } }
                    .font(.specialElite(17)).frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if rooms.isEmpty && !busy { Text("No accepted rooms.").foregroundColor(.sdTextSecondary) }
            Button("Refresh rooms") { Task { await load() } }.disabled(busy)
        }
    }
    private func roomControls(_ room: RoomSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Back to rooms") { selected = nil; invitation = nil; members = [] }
            Text(room.title).font(.specialElite(21))
            if owner {
                Button("Create 24-hour invite") { Task { await act("invite", room: room.id) } }.disabled(busy)
                if let invitation {
                    ShareLink("Share invitation code", item: invitation)
                    Text("Expires after 24 hours or 20 requests. A new code revokes the old code and pending requests.")
                        .font(.caption).foregroundColor(.sdTextSecondary)
                }
                Button("Revoke invites and pending requests") { Task { await act("revoke_invites", room: room.id) } }.disabled(busy)
            }
            ForEach(members) { member in
                VStack(alignment: .leading, spacing: 8) {
                    Text(member.user_id.uuidString).font(.caption).textSelection(.enabled)
                    Text(member.revoked ? "Removed" : member.owner_approved && member.member_accepted ? "Accepted" : "Awaiting owner approval")
                    if owner && !member.revoked {
                        if !member.owner_approved {
                            Button("Approve member") { Task { await act("approve", room: room.id, subject: member.user_id) } }
                        }
                        Button("Remove member", role: .destructive) { Task { await act("remove", room: room.id, subject: member.user_id) } }
                        Button("Block from room", role: .destructive) { Task { await act("block", room: room.id, subject: member.user_id) } }
                    }
                }.disabled(busy).padding().background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button("Refresh members") { Task { await loadMembers(room) } }.disabled(busy)
            Button(owner ? "Close room" : "Leave room", role: .destructive) {
                Task { await act(owner ? "close" : "leave", room: room.id) }
            }.disabled(busy)
        }
    }
    @MainActor private func load() async {
        guard auth.isAuthenticated, let account = auth.userId else { return }
        let revision = epoch
        do {
            let result: [RoomSummary] = try await client.from("sdi_rooms").select().limit(100).execute().value
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            rooms = result; failure = nil
        } catch { if revision == epoch { rooms = []; failure = "Rooms could not be loaded. Check your connection and service configuration." } }
    }
    @MainActor private func loadMembers(_ room: RoomSummary) async {
        let revision = epoch
        do {
            let result: [RoomMember] = try await client.from("sdi_room_members").select().eq("room_id", value: room.id.uuidString).limit(100).execute().value
            guard !Task.isCancelled, revision == epoch, selected?.id == room.id else { return }
            members = result
        } catch { if revision == epoch { members = []; failure = "Membership could not be refreshed." } }
    }
    @MainActor private func act(_ action: String, room: UUID? = nil, subject: UUID? = nil,
                                token: String? = nil, title: String? = nil, accepted: Bool = false) async {
        guard !busy, auth.isAuthenticated, let account = auth.userId else { return }
        let revision = epoch; busy = true; failure = nil; message = nil
        defer { busy = false }
        do {
            let payload = RoomAction(action: action, room: room, subject: subject, code: token, title: title, consent: accepted)
            let result: RoomActionResult = try await client.rpc("sdi_room_action", params: payload).execute().value
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            if let error = result.error { failure = error; return }
            if action == "preview" { preview = result; return }
            if action == "invite" { invitation = result.code; return }
            if action == "revoke_invites" { invitation = nil }
            if action == "request" { preview = nil; code = ""; consent = false; message = "Request recorded. The owner must approve admission." }
            if action == "create" { self.title = ""; message = "Room created." }
            if action == "close" || action == "leave" { selected = nil; members = []; invitation = nil }
            await load()
            if let selected { await loadMembers(selected) }
        } catch { if revision == epoch { failure = "The room operation was not confirmed. Refresh before retrying." } }
    }
}
private struct RoomSummary: Decodable, Identifiable { let id: UUID; let owner_id: UUID; let title: String }
private struct RoomMember: Decodable, Identifiable {
    var id: UUID { user_id }
    let user_id: UUID; let owner_approved: Bool; let member_accepted: Bool; let revoked: Bool
}
private struct RoomAction: Encodable {
    let action: String; let room: UUID?; let subject: UUID?; let code: String?; let title: String?; let consent: Bool
}
private struct RoomActionResult: Decodable {
    let status: String?; let error: String?; let room_id: UUID?; let title: String?; let code: String?
}
