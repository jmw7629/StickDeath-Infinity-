import SwiftUI
import UniformTypeIdentifiers

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
                            RoomDetailView(room: selected, onBack: {
                                RoomSessionCoordinator.shared.end(); self.selected = nil; Task { await load() }
                            },
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
                if phase == .active { await load(); restoreHandoff() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .sdiCommunityReturnToRoom)) { _ in restoreHandoff() }
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
                        Text("\(room.owner_id.uuidString.lowercased() == auth.userId?.lowercased() ? "You own this room" : "Member") · \(room.project_title == nil ? "nothing shared" : room.sharesEdit ? "members may edit" : "view only")\(RoomSessionCoordinator.shared.returnRoom == room.id ? " · open in Studio" : "")")
                            .communityCaption()
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("rooms.browser.room")
            }
            if rooms.isEmpty && !busy { Text("No accepted rooms. Rooms appear here once you create one or an owner approves your request.").communityCaption().accessibilityIdentifier("rooms.browser.empty") }
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

    /// Coming back from Studio lands on the room whose project is open there.
    @MainActor private func restoreHandoff() {
        guard selected == nil, let room = RoomSessionCoordinator.shared.returnRoom, let match = rooms.first(where: { $0.id == room }) else { return }
        selected = match
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
            if summary?.project_ref != nil {
                RoomProjectHandoffCard(room: room.id, isOwner: owner, projectRef: summary?.project_ref, projectTitle: summary?.project_title)
            }
            if owner { invitationCard }
            membersCard
            activityCard
            RoomAssetsCard(room: room.id, canSend: summary?.can_edit == true && summary?.project_ref != nil, isOwner: owner)
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
        .onDisappear {
            // Opening the shared project in Studio keeps synchronisation alive;
            // any other exit ends it. The device project is never touched.
            if !RoomSessionCoordinator.shared.isHandedOff(room: room.id) { RoomSessionCoordinator.shared.end() }
            epoch = UUID()
        }
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
            if let held = RoomSessionCoordinator.shared.heldConflict {
                CommunityMessage(text: "Your edit\(held.target.map { " to \($0)" } ?? "") overlaps \(held.overlapping.count) edit\(held.overlapping.count == 1 ? "" : "s") by another creator. Nothing was overwritten. Decide after reviewing their change. Discarding stops sending your edit; it stays in your device copy until you undo it there.", kind: .info)
                    .accessibilityIdentifier("rooms.room.conflict")
                HStack(spacing: 8) {
                    Button("Keep mine on top") { RoomSessionCoordinator.shared.resolveHeldConflict(keepMine: true); Task { await pollActivity() } }
                        .buttonStyle(CommunitySecondaryButtonStyle()).accessibilityIdentifier("rooms.room.conflict-keep")
                    Button("Discard mine") { RoomSessionCoordinator.shared.resolveHeldConflict(keepMine: false); Task { await pollActivity() } }
                        .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.room.conflict-discard")
                }
            }
            if let reason = RoomSessionCoordinator.shared.endReason { Text(reason).communityCaption() }
            if let blocked = RoomSessionCoordinator.shared.blockedRemote {
                CommunityMessage(text: "Shared edit #\(blocked.revision) is waiting: \(blocked.reason)", kind: .info)
                    .accessibilityIdentifier("rooms.room.blocked")
                Button("Skip this edit (my copy will differ)") {
                    RoomSessionCoordinator.shared.skipBlockedRemote(); Task { await pollActivity() }
                }
                .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.room.blocked-skip")
            }
            if RoomSessionCoordinator.shared.isHandedOff(room: room.id) {
                let coordinator = RoomSessionCoordinator.shared
                Text("In Studio this session: \(coordinator.appliedRemoteCount) shared edit\(coordinator.appliedRemoteCount == 1 ? "" : "s") applied, \(coordinator.publishedLocalCount) of yours queued for sending, \(coordinator.pendingLocalCount) still unsent, \(coordinator.skippedRemote.count) skipped, \(coordinator.unsharedLocalCount) local change\(coordinator.unsharedLocalCount == 1 ? "" : "s") not shared\(coordinator.lastUnsharedReason.map { " (latest: \($0))" } ?? "").")
                    .communityCaption().accessibilityIdentifier("rooms.room.studio-sync")
            }
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
            Text("Edits are versioned Studio commands with an idempotent operation id, a per-room sequence number and a base revision. The server places an edit on top of concurrent edits only when they touched different frames, layers or sounds; overlapping edits are held for your decision and never overwrite another creator's work. You can undo only your own edits. While the shared project is open in Studio, its typed edits and exactly replayable drawings are sent here, and other creators' edits are applied in order with the identities they created. Anything Studio cannot replay exactly (for example a fill, a paste from this device's clipboard, Undo or a room undo) is never claimed as shared: it is listed as not shared or waits for you to skip it.")
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
                if problem.contains("unavailable") {
                RoomSessionCoordinator.shared.end(reason: "Room access ended. Your device copy of the project is unchanged.")
                onLeft("Room access ended. Your device copy of the project is unchanged; nothing was deleted.")
            }
                else { syncStatus = problem }
                return
            }
            activity = (response.commands ?? []).sorted { $0.revision < $1.revision }
            let outcome = await RoomSessionCoordinator.shared.catchUp()
            guard revision == epoch else { return }
            let pendingRemote = RoomSessionCoordinator.shared.pendingRemoteCount
            let waitingFor = RoomSessionCoordinator.shared.isHandedOff(room: room.id) ? "to apply in Studio" : "until you open the shared project in Studio"
            syncStatus = "Server head revision \(response.head ?? 0). \(pendingRemote) remote edit\(pendingRemote == 1 ? "" : "s") waiting \(waitingFor). \(outcome == .accessEnded ? "Access ended." : "")"
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
    /// Safe handoff: open the exact device project the owner shared, or the
    /// copy this device imported from the owner's handoff. Members without
    /// either are told to download it; nothing is invented.
    @MainActor private func openInStudio() async {
        guard !busy, let summary, let ownerProjectID = RoomProjectShare.projectID(from: summary.project_ref) else {
            failure = "This room's project reference is not a device project."; return
        }
        guard !studio.isEditing else { failure = "Finish and save the project that is open in Studio first."; return }
        let library = DeviceStorageManager.shared.listAnimations()
        let linked = RoomProjectLinkStore.device.link(room: room.id, projectRef: summary.project_ref)?.localProjectID
        guard let metadata = library.first(where: { $0.id == ownerProjectID }) ?? linked.flatMap({ id in library.first(where: { $0.id == id }) }) else {
            failure = owner ? "The shared project is no longer in this device's project library."
                : "This device has no copy of the shared project. Use Download shared project once the owner sends it."
            return
        }
        let projectID = metadata.id
        busy = true; defer { busy = false }
        if await studio.openProject(metadata) {
            RoomSessionCoordinator.shared.handOffToStudio(room: room.id, roomTitle: room.title, projectID: projectID)
            studio.startRoomSynchronisation()
            notice = "Opened \(metadata.title) in Studio. Edits are saved on this device and synchronised with this room while it stays open; overlapping edits wait for your decision. Return to Rooms to come back to this room."
            NotificationCenter.default.post(name: .sdiCommunityOpenStudio, object: nil)
        } else {
            failure = studio.message ?? "Studio could not open the project."
        }
    }
}

extension RoomProjectLinkStore {
    /// Links live beside the app's own data in Application Support, never in a project.
    static var device: RoomProjectLinkStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return RoomProjectLinkStore(directory: base.appendingPathComponent("Rooms", isDirectory: true))
    }
}

/// Owner-approved project handoff (#234). The owner sends the shared project's
/// portable backup as a temporary, hash-verified copy for approved members; a
/// member imports it as a new device project. The server copy is deleted once
/// every current member has it, when the owner withdraws it, or after 72 hours.
private struct RoomProjectHandoffCard: View {
    let room: UUID
    let isOwner: Bool
    let projectRef: String?
    let projectTitle: String?
    @ObservedObject private var studio = StudioViewModel.shared
    @State private var snapshot: RoomSnapshotRecord?
    @State private var loaded = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var progress: String?
    @State private var busy = false
    @State private var confirmSend = false
    @State private var work: Task<Void, Never>?
    @State private var download: RoomProjectHandoff.Download?
    @State private var linkRevision = 0

    private var memberState: RoomProjectHandoffPolicy.MemberState {
        _ = linkRevision
        let library = DeviceStorageManager.shared.listAnimations()
        let ownerID = RoomProjectShare.projectID(from: projectRef)
        let link = RoomProjectLinkStore.device.link(room: room, projectRef: projectRef)
        return RoomProjectHandoffPolicy.memberState(isOwner: isOwner, snapshot: snapshot,
            ownerProjectOnDevice: ownerID.map { id in library.contains { $0.id == id } } ?? false,
            link: link, linkedProjectExists: link.map { value in library.contains { $0.id == value.localProjectID } } ?? false)
    }

    var body: some View {
        CommunityCard {
            Text("Project handoff").communitySubheading()
            if let problem { CommunityMessage(text: problem, kind: .error).accessibilityIdentifier("rooms.handoff.error") }
            if let notice { CommunityMessage(text: notice, kind: .success).accessibilityIdentifier("rooms.handoff.notice") }
            if let progress { Text(progress).communityCaption().accessibilityIdentifier("rooms.handoff.progress") }
            if isOwner { ownerControls } else { memberControls }
            Text("A sent project is a temporary copy of the saved project backup (up to \(RoomProjectHandoffPolicy.maximumBytes / 1_048_576) MB). Only approved members of this room can download it. The server deletes it once every current member has it, when the owner withdraws it, when the shared project changes or the room closes, and after \(Int(RoomProjectHandoffPolicy.retention / 3600)) hours at most. Copies members already imported stay on their devices.")
                .communityCaption()
            Button("Refresh handoff") { Task { await refresh() } }
                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy || work != nil)
                .accessibilityIdentifier("rooms.handoff.refresh")
        }
        .accessibilityIdentifier("rooms.handoff")
        .task(id: "\(room):\(projectRef ?? "")") { snapshot = nil; loaded = false; download = nil; await refresh() }
        .onDisappear { work?.cancel() }
        .confirmationDialog("Send this project to the room's members?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send project to members") { startSend() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A temporary copy of the saved project\(projectTitle.map { " \"\($0)\"" } ?? "") is uploaded for approved members to import as their own new project. It is deleted after every current member has it or within \(Int(RoomProjectHandoffPolicy.retention / 3600)) hours. Your device project is not changed.")
        }
    }

    @ViewBuilder private var ownerControls: some View {
        if let snapshot {
            Text(ownerStatus(snapshot)).communityCaption().accessibilityIdentifier("rooms.handoff.status")
        } else if loaded {
            Text("No project copy is waiting on the server.").communityCaption().accessibilityIdentifier("rooms.handoff.status")
        }
        HStack(spacing: 8) {
            Button(work == nil ? (snapshot == nil ? "Send project to members" : "Send current version again") : "Sending…") { confirmSend = true }
                .buttonStyle(CommunityPrimaryButtonStyle()).disabled(busy || work != nil || studio.isEditing)
                .accessibilityIdentifier("rooms.handoff.send")
            if work != nil {
                Button("Cancel") { work?.cancel() }
                    .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.handoff.cancel")
            } else if let snapshot {
                Button("Withdraw sent project") { Task { await withdraw(snapshot) } }
                    .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).disabled(busy)
                    .accessibilityIdentifier("rooms.handoff.withdraw")
            }
        }
        if studio.isEditing { Text("Finish and save the project that is open in Studio first.").communityCaption() }
    }

    private func ownerStatus(_ snapshot: RoomSnapshotRecord) -> String {
        guard snapshot.state == "available" else {
            return "Upload unfinished (\(snapshot.received?.count ?? 0)/\(snapshot.chunk_count) parts). Send again within an hour to resume."
        }
        let delivered = snapshot.delivered ?? 0, awaiting = snapshot.awaiting ?? 0
        return "Sent and verified by the server · \(delivered) member\(delivered == 1 ? "" : "s") imported it · \(awaiting) still waiting · deleted by \(snapshot.expires_at.formatted(date: .abbreviated, time: .shortened)) at the latest"
    }

    @ViewBuilder private var memberControls: some View {
        let state = memberState
        switch state {
        case .ownerProjectOnDevice:
            Text("The shared project is already on this device.").communityCaption().accessibilityIdentifier("rooms.handoff.status")
        case .imported(let id):
            Text("Imported on this device as \(DeviceStorageManager.shared.listAnimations().first { $0.id == id }?.title ?? "a project"). Open it with Open shared project in Studio.")
                .communityCaption().accessibilityIdentifier("rooms.handoff.status")
        case .download, .updateAvailable:
            if let snapshot {
                Text("\(snapshot.title) · \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byte_size), countStyle: .file)) · SHA-256 \(snapshot.sha256.prefix(12))… · available until \(snapshot.expires_at.formatted(date: .abbreviated, time: .shortened))")
                    .communityCaption().accessibilityIdentifier("rooms.handoff.status")
            }
            if case .updateAvailable = state {
                Text("A newer version was sent. Downloading creates another new project; your earlier import is kept unchanged.").communityCaption()
            }
            HStack(spacing: 8) {
                Button(work == nil ? "Download shared project" : "Downloading…") { startDownload() }
                    .buttonStyle(CommunityPrimaryButtonStyle()).disabled(busy || work != nil || studio.isEditing || snapshot == nil)
                    .accessibilityIdentifier("rooms.handoff.download")
                if work != nil {
                    Button("Cancel") { work?.cancel() }
                        .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.handoff.cancel")
                }
            }
            if studio.isEditing { Text("Finish and save the project that is open in Studio first.").communityCaption() }
        case .nothingToDo:
            if loaded { Text("The owner has not sent the project yet. This device has no copy.").communityCaption().accessibilityIdentifier("rooms.handoff.status") }
        }
    }

    @MainActor private func refresh() async {
        do { snapshot = try await CommunityServices.rooms.handoff.current(room: room); loaded = true; problem = nil }
        catch { loaded = true; snapshot = nil; problem = describe(error) }
        linkRevision += 1
    }
    @MainActor private func startSend() {
        guard work == nil, isOwner else { return }
        guard let projectID = RoomProjectShare.projectID(from: projectRef),
              let metadata = DeviceStorageManager.shared.listAnimations().first(where: { $0.id == projectID }) else {
            problem = "The shared project is no longer in this device's project library. Nothing was sent."; return
        }
        work = Task { @MainActor in
            defer { work = nil; progress = nil }
            problem = nil; notice = nil; progress = "Preparing the saved project backup…"
            do {
                // The same portable backup as Save Project Backup; the device project is only read.
                let bundle = try await studio.preparePortableBackup(metadata)
                let outcome = try await CommunityServices.rooms.handoff.send(room: room, bundle: bundle) { sent, total in
                    progress = "Sent \(sent) of \(total) parts…"
                }
                switch outcome {
                case .available(_, let awaiting):
                    notice = "Project sent and verified by the server. \(awaiting) member\(awaiting == 1 ? "" : "s") can download it now; members approved later can too until it expires."
                case .alreadyAvailable:
                    notice = "This exact version is already waiting for members."
                }
            } catch RoomProjectHandoff.HandoffError.cancelled {
                notice = "Sending paused. Send again within an hour to resume, or withdraw it."
            } catch { problem = describe(error) }
            await refresh()
        }
    }
    @MainActor private func startDownload() {
        guard work == nil, !isOwner, let snapshot else { return }
        work = Task { @MainActor in
            defer { work = nil; progress = nil }
            problem = nil; notice = nil; progress = "Receiving \(snapshot.title)…"
            var state = download.flatMap { $0.snapshot == snapshot ? $0 : nil } ?? RoomProjectHandoff.Download(snapshot: snapshot)
            let data: Data
            do {
                data = try await CommunityServices.rooms.handoff.receive(room: room, &state)
                download = nil
            } catch {
                download = state.chunks.isEmpty ? nil : state
                problem = describe(error) + (state.chunks.isEmpty ? "" : " Try again to resume from part \(state.chunks.count + 1).")
                return
            }
            progress = "SHA-256 verified. Importing as a new project…"
            let metadata: AnimationMetadata
            do {
                // Always a fresh identity: an existing device project is never overwritten.
                metadata = try await studio.importPortableProject(data)
            } catch {
                problem = "The download was verified but the project could not be imported: \((error as? LocalizedError)?.errorDescription ?? "unknown error"). No project was created or changed."
                return
            }
            do {
                try RoomProjectLinkStore.device.record(RoomProjectLink(room: room, projectRef: snapshot.project_ref, sha256: snapshot.sha256,
                                                                       localProjectID: metadata.id, importedAt: Date()))
            } catch {
                problem = "Imported as \(metadata.title), but this device could not remember its link to the room. Open it from the project library."
            }
            linkRevision += 1
            do {
                switch try await CommunityServices.rooms.handoff.confirmReceipt(room: room, snapshot: snapshot) {
                case .serverCopyDeleted(let verified):
                    notice = "Imported as a new project, \(metadata.title). Every current member has it, so the server copy was deleted\(verified ? " (deletion verified)" : "; deletion is still being verified")."
                case .serverCopyRetained:
                    notice = "Imported as a new project, \(metadata.title). The server keeps its copy until the other members have it or it expires."
                }
            } catch {
                notice = "Imported as a new project, \(metadata.title). Your receipt was not recorded, so the server copy stays until it expires."
            }
            await refresh()
        }
    }
    @MainActor private func withdraw(_ snapshot: RoomSnapshotRecord) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let verified = try await CommunityServices.rooms.handoff.revoke(room: room, snapshot: snapshot.snapshot_id)
            notice = verified ? "The server copy was deleted and the deletion verified. Copies members already imported stay on their devices."
                : "The server copy was withdrawn; deletion is still being verified."
        } catch { problem = describe(error) }
        await refresh()
    }
    private func describe(_ error: Error) -> String {
        if let handoff = error as? RoomProjectHandoff.HandoffError { return handoff.errorDescription ?? "Project handoff failed." }
        return CommunityGateway.normalize(error).errorDescription ?? "Project handoff failed."
    }
}

/// Files a creator explicitly chooses to send to this room (#233). Each is a
/// temporary, hash-verified copy with a licence; the chosen original is only
/// read, never moved or deleted. No camera, microphone, screen or background
/// collection exists here.
private struct RoomAssetsCard: View {
    let room: UUID
    let canSend: Bool
    let isOwner: Bool
    @State private var assets: [RoomAssetRecord] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var progress: String?
    @State private var showingImporter = false
    @State private var picked: URL?
    @State private var license: RoomAssetLicense = .ownWork
    @State private var attribution = ""
    @State private var consent = false
    @State private var sending: Task<Void, Never>?
    @State private var downloads: [UUID: RoomAssetTransfer.Download] = [:]

    var body: some View {
        CommunityCard {
            Text("Shared assets").communitySubheading()
            if let problem { CommunityMessage(text: problem, kind: .error).accessibilityIdentifier("rooms.assets.error") }
            if let notice { CommunityMessage(text: notice, kind: .success).accessibilityIdentifier("rooms.assets.notice") }
            if let progress { Text(progress).communityCaption().accessibilityIdentifier("rooms.assets.progress") }
            if loaded && assets.isEmpty { Text("No files have been shared in this room.").communityCaption() }
            ForEach(assets) { asset in
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.specialElite(15, relativeTo: .body))
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(asset.byte_size), countStyle: .file)) · \(asset.licenseTitle)\(asset.attribution.isEmpty ? "" : " · \(asset.attribution)")")
                        .communityCaption()
                    Text("SHA-256 \(asset.sha256.prefix(12))… · \(asset.state == "available" ? "verified by the server" : "still sending (\(asset.received ?? 0)/\(asset.chunk_count))") · expires \(asset.expires_at.formatted(date: .abbreviated, time: .shortened))")
                        .communityCaption()
                    HStack(spacing: 8) {
                        if asset.state == "available" && asset.mine != true {
                            Button("Save to this device") { Task { await download(asset) } }
                                .buttonStyle(CommunitySecondaryButtonStyle()).accessibilityIdentifier("rooms.assets.download")
                        }
                        if asset.mine == true || isOwner {
                            Button(asset.mine == true ? "Withdraw" : "Remove copy") { Task { await withdraw(asset) } }
                                .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.assets.withdraw")
                        }
                    }.disabled(busy)
                }.padding(.vertical, 4)
            }
            if canSend {
                Button("Choose a file to send") { showingImporter = true }
                    .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("rooms.assets.choose")
                if let picked {
                    Text(picked.lastPathComponent).font(.specialElite(14, relativeTo: .body))
                    Picker("Licence", selection: $license) {
                        ForEach(RoomAssetLicense.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).tint(StudioCraftTheme.accentText).accessibilityIdentifier("rooms.assets.license")
                    TextField(license == .ccBy ? "Attribution (required)" : "Attribution (optional)", text: $attribution).communityField()
                        .accessibilityIdentifier("rooms.assets.attribution")
                    Toggle("I have the rights to share this file with this room's approved members.", isOn: $consent)
                        .font(.specialElite(14, relativeTo: .body)).accessibilityIdentifier("rooms.assets.consent")
                    HStack(spacing: 8) {
                        Button(sending == nil ? "Send file" : "Sending…") { startSend(picked) }
                            .buttonStyle(CommunityPrimaryButtonStyle()).disabled(!consent || busy || sending != nil)
                            .accessibilityIdentifier("rooms.assets.send")
                        if sending != nil {
                            Button("Cancel") { sending?.cancel() }
                                .buttonStyle(CommunitySecondaryButtonStyle(destructive: true)).accessibilityIdentifier("rooms.assets.cancel")
                        }
                    }
                }
            } else {
                Text("Editors of a room with a shared project can send files here.").communityCaption()
            }
            Text("Only files you choose are sent, in verified 32 KB parts. Copies expire after \(Int(RoomAssetPolicy.retention / 3600)) hours and are deleted when the sender leaves or the room closes. Your original file is never changed or deleted.")
                .communityCaption()
            Button("Refresh assets") { Task { await refresh() } }
                .buttonStyle(CommunitySecondaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("rooms.assets.refresh")
        }
        .accessibilityIdentifier("rooms.assets")
        .task(id: room) { await refresh() }
        .onDisappear { sending?.cancel() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.png, .jpeg, .audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): picked = urls.first; consent = false; problem = nil; notice = nil
            case .failure: problem = "The file could not be opened."
            }
        }
    }

    @MainActor private func refresh() async {
        do { assets = try await CommunityServices.rooms.assets.list(room: room); loaded = true; problem = nil }
        catch { loaded = true; assets = []; problem = describe(error) }
    }
    @MainActor private func startSend(_ url: URL) {
        guard sending == nil, consent else { return }
        let chosenLicense = license, chosenAttribution = attribution
        sending = Task { @MainActor in
            defer { sending = nil; progress = nil }
            problem = nil; notice = nil
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= RoomAssetPolicy.maximumBytes else { problem = "Files up to 8 MB can be sent."; return }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { problem = "The file could not be read."; return }
            do {
                let outcome = try await CommunityServices.rooms.assets.send(room: room, file: data, name: url.lastPathComponent,
                    mime: RoomAssetPolicy.mime(forExtension: url.pathExtension), license: chosenLicense, attribution: chosenAttribution) { sent, total in
                    progress = "Sent \(sent) of \(total) parts…"
                }
                switch outcome {
                case .available: notice = "File sent and verified by the server. Members can save it for \(Int(RoomAssetPolicy.retention / 3600)) hours."
                case .alreadyShared: notice = "This exact file is already shared in the room."
                }
                picked = nil; consent = false; attribution = ""
            } catch RoomAssetTransfer.TransferError.cancelled {
                notice = "Sending paused. Send the same file again within an hour to resume, or withdraw it."
            } catch { problem = describe(error) }
            await refresh()
        }
    }
    @MainActor private func download(_ asset: RoomAssetRecord) async {
        guard !busy else { return }
        busy = true; defer { busy = false; progress = nil }
        var state = downloads[asset.asset_id] ?? RoomAssetTransfer.Download(asset: asset)
        progress = "Receiving \(asset.name)…"
        do {
            let data = try await CommunityServices.rooms.assets.receive(room: room, &state)
            downloads[asset.asset_id] = nil
            let base = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let saved = try RoomAssetInbox.save(data, asset: asset, room: room, base: base)
            notice = "Saved \(saved.lastPathComponent) to this device (Room Transfers). SHA-256 verified."
        } catch {
            downloads[asset.asset_id] = state.chunks.isEmpty ? nil : state
            problem = describe(error) + (state.chunks.isEmpty ? "" : " Try again to resume from part \(state.chunks.count + 1).")
        }
    }
    @MainActor private func withdraw(_ asset: RoomAssetRecord) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let verified = try await CommunityServices.rooms.assets.withdraw(room: room, asset: asset.asset_id)
            notice = verified ? "The room's copy was deleted and the deletion verified. Device files are unchanged." : "The room's copy was withdrawn; deletion is still being verified."
        } catch { problem = describe(error) }
        await refresh()
    }
    private func describe(_ error: Error) -> String {
        if let transfer = error as? RoomAssetTransfer.TransferError { return transfer.errorDescription ?? "Transfer failed." }
        return CommunityGateway.normalize(error).errorDescription ?? "Transfer failed."
    }
}

/// Server bounds from rooms-v2.sql shown honestly. Originals never leave the
/// device except as a temporary, hash-verified copy of a file the creator chose.
private struct RoomQuotaPanel: View {
    let head: Int
    var body: some View {
        CommunityCard {
            Text("Quotas and transfers").communitySubheading()
            Text("Edit payloads up to \(RoomQuotaPolicy.commandPayloadBytes / 1024) KB · \(RoomQuotaPolicy.commandsPerMinute) edits per minute · \(RoomQuotaPolicy.remainingRevisions(head: head)) of \(RoomQuotaPolicy.roomRevisionLimit) revisions remaining")
                .communityCaption()
            Text("Up to \(RoomQuotaPolicy.membersPerRoom) members per room and \(RoomQuotaPolicy.openRoomsPerOwner) open rooms per owner · \(RoomQuotaPolicy.dailyReports) reports per day")
                .communityCaption()
            Text("Asset transfers: files you choose, up to \(RoomAssetPolicy.maximumBytes / 1_048_576) MB each, \(RoomAssetPolicy.roomBytes / 1_048_576) MB and \(RoomAssetPolicy.roomFiles) files per room, \(RoomAssetPolicy.dailyFiles) per day · copies expire after \(Int(RoomAssetPolicy.retention / 3600)) hours and are deleted when you leave or the room closes. Originals stay on each device.")
                .communityCaption().accessibilityIdentifier("rooms.quotas.transfers")
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
