import SwiftUI

/// Rooms: invitation-based collaboration on an explicitly shared Studio
/// project. A code permits an admission request only; the recipient consents
/// and the owner approves before any room data is visible. No chat, calls,
/// camera, microphone or media streams exist here, and creating or joining a
/// room never uploads a project.
struct CollabRoomView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var phase
    @State private var rooms: [RoomSummary] = []
    @State private var pending: [RoomPendingRequest] = []
    @State private var selected: RoomSummary?
    @State private var showingCreate = false
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var epoch = UUID()
    private var identity: String { "\(auth.userId ?? "guest"):\(auth.isAuthenticated):\(phase == .active)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Rooms").communityHeading()
                    Text("Collaborate by agreement. Invitation codes never grant access on their own.")
                        .font(.specialElite(14, relativeTo: .callout)).foregroundStyle(StudioCraftTheme.textDim)
                    if !CommunityServices.isConfigured {
                        CommunityMessage(text: CommunityServices.notConfiguredText, kind: .info)
                            .accessibilityIdentifier("rooms.not-configured")
                    }
                    if !auth.isAuthenticated {
                        CommunitySignInPrompt(text: "Sign in to create or join rooms", identifier: "rooms.sign-in")
                    }
                    if let failure { CommunityMessage(text: failure, kind: .error).accessibilityIdentifier("rooms.error") }
                    if let message { CommunityMessage(text: message, kind: .success).accessibilityIdentifier("rooms.notice") }
                    if busy { ProgressView().tint(StudioCraftTheme.accent) }
                    if auth.isAuthenticated {
                        if let selected {
                            RoomDetailView(room: selected, onBack: { self.selected = nil; Task { await load() } },
                                           onLeft: { note in self.selected = nil; message = note; Task { await load() } })
                        } else {
                            browser
                        }
                    }
                    NavigationLink { CalendarEventView() } label: { route("Calendar", "calendar") }
                        .accessibilityIdentifier("rooms.calendar")
                    NavigationLink { WatchTogetherView() } label: { route("Watch Together", "play.rectangle") }
                        .accessibilityIdentifier("rooms.watchTogether")
                    NavigationLink { WarRoomView() } label: { route("War Room", "flag.checkered") }
                        .accessibilityIdentifier("rooms.warRoom")
                    Text("Rooms share a project's title and an opaque reference. Editable projects and originals stay on this device.")
                        .communityCaption()
                }.padding(16).padding(.bottom, 60)
            }
            .communityScreen()
            .toolbar(.hidden, for: .navigationBar)
            .task(id: identity) {
                epoch = UUID(); rooms = []; pending = []; selected = nil; message = nil; failure = nil; showingCreate = false
                if phase == .active { await load() }
            }
            .refreshable { await load() }
            .sheet(isPresented: $showingCreate) {
                RoomCreateSheet { outcome in
                    showingCreate = false
                    switch outcome {
                    case .created(let room, _): message = "Room created and project share recorded (room \(communityShortID(room)))."
                    case .createdWithoutProject(let room, let problem): failure = "Room \(communityShortID(room)) exists, but the project share was not recorded: \(problem) Open the room to retry or close it."
                    }
                    Task { await load() }
                }
            }
        }
    }
    private func route(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.specialElite(18, relativeTo: .title3))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
            .background(StudioCraftTheme.card).clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radiusLarge))
            .foregroundStyle(StudioCraftTheme.text)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("Create room") { showingCreate = true }
                .buttonStyle(CommunityPrimaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("rooms.browser.create")
            RoomJoinSection(onRequested: { note in message = note; Task { await load() } })
            Text("Your rooms").communitySubheading()
            ForEach(rooms) { room in
                Button { selected = room; message = nil; failure = nil } label: {
                    CommunityCard {
                        Text(room.title).font(.specialElite(17, relativeTo: .headline))
                        Text(room.project_title.map { "Shared project: \($0)" } ?? "No project shared yet")
                            .communityCaption()
                        Text(room.owner_id.uuidString.lowercased() == auth.userId?.lowercased() ? "You own this room" : "Member")
                            .communityCaption()
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("rooms.browser.room")
            }
            if rooms.isEmpty && !busy { Text("No accepted rooms.").communityCaption().accessibilityIdentifier("rooms.browser.empty") }
            if !pending.isEmpty {
                Text("Your pending requests").communitySubheading()
                ForEach(pending) { request in
                    CommunityCard {
                        Text(request.title).font(.specialElite(16, relativeTo: .body))
                        Text("Awaiting owner approval · request expires \(request.request_expires_at.formatted(date: .abbreviated, time: .shortened))")
                            .communityCaption()
                    }.accessibilityIdentifier("rooms.requests.item")
                }
            }
            Button("Refresh rooms") { Task { await load() } }
                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("rooms.browser.refresh")
        }
    }

    @MainActor private func load() async {
        guard auth.isAuthenticated, let account = auth.userId else { return }
        let revision = epoch
        busy = true; defer { if revision == epoch { busy = false } }
        do {
            let result = try await CommunityServices.rooms.myRooms()
            guard !Task.isCancelled, revision == epoch, account == auth.userId else { return }
            rooms = result; failure = nil
            // Pending requests need rooms-v2; an older service answers with an error we report, not hide.
            do { pending = try await CommunityServices.rooms.pendingRequests() }
            catch { pending = []; if revision == epoch, case .server = CommunityGateway.normalize(error) { message = "Pending-request listing is not available from this service version." } }
        } catch {
            if revision == epoch { rooms = []; pending = []; failure = CommunityGateway.normalize(error).errorDescription }
        }
    }
}

/// Redeem a forwarded code: review the room, consent explicitly, then request admission.
private struct RoomJoinSection: View {
    let onRequested: (String) -> Void
    @State private var code = ""
    @State private var preview: RoomsClient.InvitationPreview?
    @State private var consent = false
    @State private var busy = false
    @State private var problem: String?
    var body: some View {
        CommunityCard {
            Text("Join with an invitation").communitySubheading()
            TextField("Invitation code", text: $code)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .communityField()
                .onChange(of: code) { _, _ in preview = nil; consent = false; problem = nil }
                .accessibilityIdentifier("rooms.join.code")
            Button("Review invitation") { Task { await review() } }
                .buttonStyle(CommunitySecondaryButtonStyle())
                .disabled(busy || !RoomInvitationPolicy.isWellFormed(code))
                .accessibilityIdentifier("rooms.join.review")
            if let problem { CommunityMessage(text: problem, kind: .error) }
            if let preview {
                Text(preview.title).font(.specialElite(18, relativeTo: .title3))
                Text("Permission summary: the owner decides what is shared and whether members may edit. Until the owner approves you, nothing from the room is visible.")
                    .communityCaption()
                Toggle("I agree to join this room and let its owner see my account identifier.", isOn: $consent)
                    .font(.specialElite(14, relativeTo: .body))
                    .accessibilityIdentifier("rooms.join.consent")
                Button("Request admission") { Task { await request() } }
                    .buttonStyle(CommunityPrimaryButtonStyle())
                    .disabled(!consent || busy)
                    .accessibilityIdentifier("rooms.join.request")
            }
        }
    }
    @MainActor private func review() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { preview = try await CommunityServices.rooms.previewInvitation(code: code); problem = nil }
        catch { preview = nil; problem = CommunityGateway.normalize(error).errorDescription }
    }
    @MainActor private func request() async {
        guard !busy, consent else { return }
        busy = true; defer { busy = false }
        do {
            let outcome = try await CommunityServices.rooms.requestAdmission(code: code, consent: consent)
            code = ""; preview = nil; consent = false; problem = nil
            switch outcome {
            case .pendingOwnerApproval: onRequested("Request recorded. The owner must approve admission before anything is shared.")
            case .alreadyRequested: onRequested("You already requested admission to this room. The owner still needs to approve it.")
            }
        } catch { problem = CommunityGateway.normalize(error).errorDescription }
    }
}

/// Owner chooses a specific device project and permissions before the room exists.
private struct RoomCreateSheet: View {
    let onFinished: (RoomsClient.CreationOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var projects: [AnimationMetadata] = []
    @State private var listingProblem: String?
    @State private var projectID: String = ""
    @State private var allowEdit = false
    @State private var consent = false
    @State private var busy = false
    @State private var problem: String?
    private var selectedProject: AnimationMetadata? { projects.first { $0.id.uuidString == projectID } }
    private var canCreate: Bool {
        !busy && consent && selectedProject != nil && (1...100).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Share a project in a new room").communityHeading()
                    TextField("Room name", text: $title).communityField()
                        .accessibilityIdentifier("rooms.create.title")
                    Text("Project on this device").communitySubheading()
                    if let listingProblem { CommunityMessage(text: listingProblem, kind: .error) }
                    Picker("Project", selection: $projectID) {
                        Text("Choose a project").tag("")
                        ForEach(projects, id: \.id) { project in
                            Text("\(project.title) · \(project.frameCount) frames").tag(project.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu).tint(StudioCraftTheme.accentText)
                    .accessibilityIdentifier("rooms.create.project-picker")
                    if projects.isEmpty && listingProblem == nil {
                        Text("No saved projects on this device. Save a project in Studio first.").communityCaption()
                    }
                    Toggle("Members may edit (otherwise view only)", isOn: $allowEdit)
                        .font(.specialElite(14, relativeTo: .body))
                        .accessibilityIdentifier("rooms.create.permission-edit")
                    Text("Only the project's title and an opaque reference are sent. Frames, images and audio stay on this device; synchronized editing sends bounded Studio commands, never files.")
                        .communityCaption()
                    Toggle("I choose to share this project with the members I approve.", isOn: $consent)
                        .font(.specialElite(14, relativeTo: .body))
                        .accessibilityIdentifier("rooms.create.consent")
                    if let problem { CommunityMessage(text: problem, kind: .error) }
                    Button(busy ? "Creating…" : "Create room and record share") { Task { await create() } }
                        .buttonStyle(CommunityPrimaryButtonStyle()).disabled(!canCreate)
                        .accessibilityIdentifier("rooms.create.submit")
                }.padding(16)
            }
            .communityScreen()
            .navigationTitle("New room").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear {
                do {
                    let listing = try DeviceStorageManager.shared.listAnimationsReportingFailures()
                    projects = listing.animations.sorted { $0.modifiedAt > $1.modifiedAt }
                    if !listing.failures.isEmpty { listingProblem = "\(listing.failures.count) project folders could not be read and are not offered." }
                } catch { listingProblem = "Projects on this device could not be listed." }
            }
        }
    }
    @MainActor private func create() async {
        guard canCreate, let project = selectedProject else { return }
        busy = true; defer { busy = false }
        let share = RoomProjectShare(projectID: project.id, title: project.title, permissions: allowEdit ? [.view, .edit] : [.view])
        do { onFinished(try await CommunityServices.rooms.createRoom(title: title, share: share, consent: consent)) }
        catch { problem = CommunityGateway.normalize(error).errorDescription }
    }
}

/// One room: summary, roles, invitations, members, activity, quotas, reporting.
private struct RoomDetailView: View {
    let room: RoomSummary
    let onBack: () -> Void
    let onLeft: (String) -> Void
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var studio = StudioViewModel.shared
    @State private var summary: RoomManageResponse?
    @State private var summaryProblem: String?
    @State private var members: [RoomMember] = []
    @State private var invitation: String?
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var showingReport = false
    @State private var confirmClose = false
    @State private var activity: [RoomCommandRecord] = []
    @State private var syncStatus = "Not synchronising."
    @State private var epoch = UUID()
    private var owner: Bool { room.owner_id.uuidString.lowercased() == auth.userId?.lowercased() }
    private var account: UUID? { auth.userId.flatMap(UUID.init(uuidString:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { onBack() } label: { Label("Back to rooms", systemImage: "chevron.left") }
                .buttonStyle(CommunitySecondaryButtonStyle())
                .accessibilityIdentifier("rooms.room.back")
            Text(room.title).communityHeading()
            if let failure { CommunityMessage(text: failure, kind: .error).accessibilityIdentifier("rooms.room.error") }
            if let notice { CommunityMessage(text: notice, kind: .success).accessibilityIdentifier("rooms.room.notice") }
            if busy { ProgressView().tint(StudioCraftTheme.accent) }
            projectCard
            if owner { invitationCard }
            membersCard
            activityCard
            RoomQuotaPanel(head: summary?.command_revision ?? room.command_revision ?? 0)
            HStack(spacing: 10) {
                if !owner {
                    Button("Report room") { showingReport = true }
                        .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                        .accessibilityIdentifier("rooms.room.report")
                }
                Button(owner ? "Close room" : "Leave room") { confirmClose = true }
                    .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).disabled(busy)
                    .accessibilityIdentifier(owner ? "rooms.room.close" : "rooms.room.leave")
            }
        }
        .task(id: "\(room.id):\(auth.userId ?? "none")") {
            epoch = UUID(); summary = nil; summaryProblem = nil; members = []; invitation = nil; activity = []; failure = nil; notice = nil
            await refresh()
            await pollActivity()
        }
        .onDisappear { RoomSessionCoordinator.shared.end(); epoch = UUID() }
        .confirmationDialog(owner ? "Close this room for everyone?" : "Leave this room?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button(owner ? "Close room" : "Leave room", role: .destructive) { Task { await closeOrLeave() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(owner ? "Members lose access immediately. Nobody's device project is deleted." : "You stop receiving the shared project immediately. Anything already on your device stays yours.")
        }
        .sheet(isPresented: $showingReport) {
            RoomReportSheet(room: room.id) { showingReport = false; notice = "Report recorded for administrator review. Reporter identity is not shown to the owner." }
        }
    }

    private var projectCard: some View {
        CommunityCard {
            Text("Shared project").communitySubheading()
            if let summary {
                Text(summary.project_title ?? "No project shared yet").font(.specialElite(16, relativeTo: .body))
                Text("Permissions: \((summary.permissions ?? ["view"]).joined(separator: ", ")) · Your role: \(summary.my_role ?? "member") · \(summary.can_edit == true ? "You can edit" : "View only")")
                    .communityCaption()
                Text("Project revision \(summary.project_revision ?? 0) · Edit stream revision \(summary.command_revision ?? 0) · \(summary.members ?? 0) accepted members")
                    .communityCaption()
                if summary.project_ref != nil {
                    Button("Open shared project in Studio") { Task { await openInStudio() } }
                        .buttonStyle(CommunityPrimaryButtonStyle()).disabled(busy || studio.isEditing)
                        .accessibilityIdentifier("rooms.room.open-studio")
                    if studio.isEditing { Text("Finish and save the project that is open in Studio first.").communityCaption() }
                }
            } else if let summaryProblem {
                CommunityMessage(text: summaryProblem, kind: .info)
            } else {
                Text("Loading room summary…").communityCaption()
            }
        }.accessibilityIdentifier("rooms.room.project")
    }

    private var invitationCard: some View {
        CommunityCard {
            Text("Invitations").communitySubheading()
            Button("Create 24-hour invite") { Task { await mint() } }
                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("rooms.room.invite")
            if let invitation {
                Text(invitation).font(.specialElite(12, relativeTo: .caption).monospaced()).textSelection(.enabled).privacySensitive()
                HStack(spacing: 10) {
                    ShareLink(item: RoomInvitationPolicy.shareText(code: invitation, roomTitle: room.title)) {
                        Label("Share code", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                    }.accessibilityIdentifier("rooms.room.share-code")
                    Button { UIPasteboard.general.string = invitation; notice = "Invitation code copied. It allows an admission request only." } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(minHeight: 44)
                    }.accessibilityIdentifier("rooms.room.copy-code")
                }
                Text("Expires after 24 hours or 20 requests. A new code revokes the old code and pending requests. The code is not an account credential.")
                    .communityCaption()
            }
            Button("Revoke invites and pending requests") { Task { await revoke() } }
                .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).disabled(busy)
                .accessibilityIdentifier("rooms.room.revoke-invites")
        }
    }

    private var membersCard: some View {
        CommunityCard {
            Text(owner ? "Members" : "Your membership").communitySubheading()
            if members.isEmpty { Text("No membership rows are visible for this room.").communityCaption() }
            ForEach(members) { member in
                VStack(alignment: .leading, spacing: 6) {
                    Text(member.user_id.uuidString.lowercased()).font(.specialElite(12, relativeTo: .caption).monospaced()).textSelection(.enabled)
                    Text("\(member.statusText)\(member.role.map { " · \($0)" } ?? "")").font(.specialElite(14, relativeTo: .body))
                    if let expiry = member.request_expires_at, !member.owner_approved, !member.revoked {
                        Text("Request expires \(expiry.formatted(date: .abbreviated, time: .shortened))").communityCaption()
                    }
                    if owner && !member.revoked {
                        HStack(spacing: 8) {
                            if !member.owner_approved {
                                Button("Approve") { Task { await act { try await CommunityServices.rooms.approve(room: room.id, member: member.user_id) } } }
                                    .buttonStyle(CommunitySecondaryButtonStyle()).accessibilityIdentifier("rooms.member.approve")
                            }
                            if member.isActive {
                                Button(member.role == RoomRole.editor.rawValue ? "Make viewer" : "Make editor") {
                                    let role: RoomRole = member.role == RoomRole.editor.rawValue ? .viewer : .editor
                                    Task { await act { try await CommunityServices.rooms.setRole(room: room.id, member: member.user_id, role: role) } }
                                }
                                .buttonStyle(CommunitySecondaryButtonStyle())
                                .disabled(!(summary?.permissions?.contains(RoomPermission.edit.rawValue) ?? room.sharesEdit) && member.role != RoomRole.editor.rawValue)
                                .accessibilityIdentifier("rooms.member.role")
                            }
                            Button("Remove") { Task { await act { try await CommunityServices.rooms.remove(room: room.id, member: member.user_id) } } }
                                .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.member.remove")
                            Button("Block") { Task { await act { try await CommunityServices.rooms.block(room: room.id, member: member.user_id) } } }
                                .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.member.block")
                        }.disabled(busy)
                    }
                }.padding(.vertical, 4)
            }
            Button("Refresh members") { Task { await refresh() } }
                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("rooms.room.refresh")
        }
    }

    private var activityCard: some View {
        CommunityCard {
            Text("Shared edit stream").communitySubheading()
            Text(syncStatus).communityCaption().accessibilityIdentifier("rooms.room.sync-status")
            if activity.isEmpty { Text("No shared edits recorded yet.").communityCaption() }
            ForEach(activity.suffix(20)) { record in
                HStack(alignment: .top, spacing: 8) {
                    Text("#\(record.revision)").font(.specialElite(12, relativeTo: .caption).monospaced()).foregroundStyle(StudioCraftTheme.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.kind).font(.specialElite(14, relativeTo: .body))
                        Text("\(record.author.uuidString.lowercased() == auth.userId?.lowercased() ? "You" : communityShortID(record.author)) · \(record.created_at.formatted(date: .omitted, time: .shortened))")
                            .communityCaption()
                    }
                }
            }
            Text("Edits are versioned Studio commands with an idempotent operation id and a base revision. A conflict is shown explicitly and never overwrites another creator's edit. Applying remote edits inside Studio is not connected in this build; the stream is shown as recorded by the server.")
                .communityCaption()
            Button("Refresh edit stream") { Task { await pollActivity() } }
                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("rooms.room.sync-refresh")
        }
    }

    @MainActor private func refresh() async {
        guard auth.isAuthenticated else { return }
        let revision = epoch
        busy = true; defer { if revision == epoch { busy = false } }
        do {
            let rows = try await CommunityServices.rooms.members(of: room.id)
            guard !Task.isCancelled, revision == epoch else { return }
            members = rows; failure = nil
        } catch { if revision == epoch { members = []; failure = CommunityGateway.normalize(error).errorDescription } }
        do {
            let value = try await CommunityServices.rooms.summary(of: room.id)
            guard !Task.isCancelled, revision == epoch else { return }
            summary = value; summaryProblem = nil
            if let account {
                RoomSessionCoordinator.shared.attachClient(CommunityServices.rooms)
                RoomSessionCoordinator.shared.begin(room: room.id, head: value.command_revision ?? 0,
                    projectID: RoomProjectShare.projectID(from: value.project_ref), canEdit: value.can_edit ?? false, account: account)
            }
        } catch {
            guard revision == epoch else { return }
            summary = nil
            summaryProblem = "Project sharing details are unavailable from this service version. Membership still works; no project is shared."
        }
    }
    @MainActor private func pollActivity() async {
        guard auth.isAuthenticated, summary != nil else { return }
        let revision = epoch
        do {
            let response = try await CommunityServices.rooms.commands(RoomCommandRequest(action: "since", room: room.id, after: 0, page_size: 200))
            guard !Task.isCancelled, revision == epoch else { return }
            if let problem = response.error, !problem.isEmpty {
                if problem.contains("unavailable") { RoomSessionCoordinator.shared.end(); onLeft("Room access ended.") }
                else { syncStatus = problem }
                return
            }
            activity = (response.commands ?? []).sorted { $0.revision < $1.revision }
            let outcome = await RoomSessionCoordinator.shared.catchUp()
            guard revision == epoch else { return }
            let pendingRemote = RoomSessionCoordinator.shared.pendingRemoteCount
            syncStatus = "Server head revision \(response.head ?? 0). \(pendingRemote) remote edit\(pendingRemote == 1 ? "" : "s") waiting for the Studio hook. \(outcome == .accessEnded ? "Access ended." : "")"
        } catch { if revision == epoch { syncStatus = CommunityGateway.normalize(error).errorDescription ?? "Edit stream unavailable." } }
    }
    @MainActor private func act(_ operation: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        let revision = epoch; busy = true; failure = nil; notice = nil
        defer { if revision == epoch { busy = false } }
        do { try await operation(); guard revision == epoch else { return }; busy = false; await refresh() }
        catch { if revision == epoch { failure = CommunityGateway.normalize(error).errorDescription } }
    }
    @MainActor private func mint() async {
        await act {
            let code = try await CommunityServices.rooms.mintInvitation(room: room.id)
            invitation = code; notice = "Invitation created. Pending requests from older codes were revoked."
        }
    }
    @MainActor private func revoke() async {
        await act { try await CommunityServices.rooms.revokeInvitations(room: room.id); invitation = nil; notice = "Invitations and pending requests revoked." }
    }
    @MainActor private func closeOrLeave() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if owner { try await CommunityServices.rooms.close(room: room.id) } else { try await CommunityServices.rooms.leave(room: room.id) }
            RoomSessionCoordinator.shared.end()
            onLeft(owner ? "Room closed. Members lost access; no project was deleted." : "You left the room. Synchronisation stopped.")
        } catch { failure = CommunityGateway.normalize(error).errorDescription }
    }
    /// Safe handoff: open the exact device project the owner shared. Members
    /// without a local copy are told so; nothing is downloaded or invented.
    @MainActor private func openInStudio() async {
        guard !busy, let summary, let projectID = RoomProjectShare.projectID(from: summary.project_ref) else {
            failure = "This room's project reference is not a device project."; return
        }
        guard !studio.isEditing else { failure = "Finish and save the project that is open in Studio first."; return }
        guard let metadata = DeviceStorageManager.shared.listAnimations().first(where: { $0.id == projectID }) else {
            failure = "The shared project is on the owner's device, not this one. Synchronized editing needs the Studio command hook, which is not connected yet; nothing was downloaded."; return
        }
        busy = true; defer { busy = false }
        if await studio.openProject(metadata) {
            notice = "Opened \(metadata.title) in Studio. Edits are saved on this device; the shared stream shows server-recorded commands only."
            NotificationCenter.default.post(name: .sdiCommunityOpenStudio, object: nil)
        } else {
            failure = studio.message ?? "Studio could not open the project."
        }
    }
}

/// Server bounds from rooms-v2.sql shown honestly; binary asset transfer has
/// no service in this build, so originals never leave the device.
private struct RoomQuotaPanel: View {
    let head: Int
    var body: some View {
        CommunityCard {
            Text("Quotas and transfers").communitySubheading()
            Text("Edit payloads up to \(RoomQuotaPolicy.commandPayloadBytes / 1024) KB · \(RoomQuotaPolicy.commandsPerMinute) edits per minute · \(RoomQuotaPolicy.remainingRevisions(head: head)) of \(RoomQuotaPolicy.roomRevisionLimit) revisions remaining")
                .communityCaption()
            Text("Up to \(RoomQuotaPolicy.membersPerRoom) members per room and \(RoomQuotaPolicy.openRoomsPerOwner) open rooms per owner · \(RoomQuotaPolicy.dailyReports) reports per day")
                .communityCaption()
            CommunityMessage(text: "Asset transfer is not available: no bounded transfer service is configured. Images, audio and originals stay on each device.", kind: .info)
                .accessibilityIdentifier("rooms.quotas.transfer-unavailable")
        }.accessibilityIdentifier("rooms.quotas")
    }
}

private struct RoomReportSheet: View {
    let room: UUID
    let onRecorded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoomReportDraft()
    @State private var busy = false
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Report this room's shared project or a collaborator. Administrators review reports; reporters are not identified to the owner. This is not a message to anyone.")
                    Picker("Reason", selection: $draft.reason) {
                        ForEach(FeedReportReason.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("rooms.report.reason")
                    TextField("What happened? (optional, up to 2000 characters)", text: $draft.detail, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("rooms.report.detail")
                    if let problem { Text(problem).foregroundStyle(StudioCraftTheme.accentText) }
                    Button(busy ? "Sending…" : "Submit report") { Task { await submit() } }
                        .disabled(busy || draft.validation != nil)
                        .accessibilityIdentifier("rooms.report.submit")
                }
            }
            .navigationTitle("Report room").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
        }.preferredColorScheme(.dark)
    }
    @MainActor private func submit() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await CommunityServices.rooms.report(room: room, draft: draft); onRecorded() }
        catch { problem = CommunityGateway.normalize(error).errorDescription }
    }
}
