package com.stickdeath.studio.connect

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** War Room, challenges, account lifecycle, notifications and shared-room sync state for the Account
 * panel. Shares the process-wide [SessionManager]; every reply is checked against the account
 * generation it was requested for, and nothing is shown that a server reply did not supply. */
class CommunityViewModel(application: Application) : AndroidViewModel(application) {
    private val manager = AccountRuntime.manager(application)
    private val gateway = CommunityGateway(manager.asSessionSource(), UrlConnectionTransport())
    private val war = WarRoomClient(gateway)
    private val challengesClient = ChallengeClient(gateway)
    private val profile = ProfileClient(gateway)
    private val lifecycleClient = AccountLifecycleClient(gateway)
    private val notifications = NotificationsClient(gateway)
    private val rooms = RoomsClient(gateway)
    private val calendarClient = CalendarClient(gateway)
    /** Process-wide, so the Studio editor and this panel see the same shared-room session. */
    val roomSession = RoomRuntime.coordinator(application)

    var notice by mutableStateOf(""); private set
    var busy by mutableStateOf(false); private set
    var matches by mutableStateOf<Load<List<WarMatch>>>(Load.Idle); private set
    var votes by mutableStateOf<Map<String, WarVoteMachine>>(emptyMap()); private set
    var warNotices by mutableStateOf<Load<List<WarNotice>>>(Load.Idle); private set
    var myMedia by mutableStateOf<Load<List<ApprovedMedia>>>(Load.Idle); private set
    var challenges by mutableStateOf<Load<ChallengeListing>>(Load.Idle); private set
    var entries by mutableStateOf<Map<String, Load<ChallengeEntries>>>(emptyMap()); private set
    var lifecycle by mutableStateOf<Load<AccountLifecycleStatus>>(Load.Idle); private set
    /** The export held in memory only until the member saves it or cancels; never cached on disk. */
    var pendingExport by mutableStateOf<String?>(null); private set
    var notificationPreferences by mutableStateOf<Load<ServerNotificationPreferences>>(Load.Idle); private set
    var inbox by mutableStateOf<Load<NotificationInbox>>(Load.Idle); private set
    var myRooms by mutableStateOf<Load<List<RoomSummary>>>(Load.Idle); private set
    var roomStatus by mutableStateOf(""); private set
    var roomDetails by mutableStateOf<Map<String, Load<RoomDetail>>>(emptyMap()); private set
    var roomMembers by mutableStateOf<Map<String, Load<List<RoomMember>>>>(emptyMap()); private set
    /** The newest invitation code, shown only to the owner who minted it; never stored. */
    var invitation by mutableStateOf<Pair<String, String>?>(null); private set
    var pendingRequests by mutableStateOf<Load<List<PendingRequest>>>(Load.Idle); private set
    /** Creation is two confirmed RPCs; retain a known partial room instead of creating it twice. */
    var roomCreation by mutableStateOf<RoomCreationOutcome?>(null); private set
    var pendingRoomShare by mutableStateOf<PendingRoomProjectShare?>(null); private set
    var roomPreview by mutableStateOf<Load<InvitationPreview>>(Load.Idle); private set
    var roomCreating by mutableStateOf(false); private set
    var roomInvitationWorking by mutableStateOf(false); private set
    val roomsBusy get() = busy || roomCreating || roomInvitationWorking
    private var roomsWindowRequested = false
    private var roomsAppForeground = false
    @Volatile private var roomsWindowVisible = false
    @Volatile private var roomReadEpoch = 0L
    private var roomCreateOperation = 0L
    @Volatile private var roomInviteOperation = 0L
    private var reviewedRoomCode: String? = null
    /** Bumped whenever the shared session counters may have changed. */
    var roomSessionVersion by mutableStateOf(0L); private set
    var calendarMonth by mutableStateOf(java.time.YearMonth.now()); private set
    var calendar by mutableStateOf<Load<CalendarMonth>>(Load.Idle); private set
    /** Moderator results, from the server only. */
    var moderation by mutableStateOf(""); private set
    @Volatile private var lastAccount: String? = null

    // Foreground window scopes fence new reads and follow-up loads. They do not
    // end the independently owned Studio room-sync session or a started mutation.
    private var mediaReadSubject: String? = null
    private var mediaReadRequest = 0L
    private var desktopRequested = emptySet<String>()
    private var desktopForeground = false
    @Volatile private var desktopVisible = emptySet<String>()
    private var desktopVisibleState by mutableStateOf(emptySet<String>())
    @Volatile private var desktopEpochs = emptyMap<String, Long>()
    val sessionGeneration: Long get() = manager.generation
    val accountDataVisible: Boolean get() = "account" in desktopVisibleState && desktopReadable("account")
    fun setDesktopWindowVisible(subject: String, visible: Boolean) {
        if (subject !in setOf("war-room", "challenges", "calendar", "notifications", "account")) return
        desktopRequested = if (visible) desktopRequested + subject else desktopRequested - subject
        updateDesktopVisibility()
    }
    fun setDesktopAppForeground(foreground: Boolean) { desktopForeground = foreground; updateDesktopVisibility() }
    private fun updateDesktopVisibility() {
        val next = if (desktopForeground) desktopRequested else emptySet()
        val mediaOwner = mediaReadSubject
        if (myMedia is Load.Loading && mediaOwner != null && mediaOwner in (desktopVisible - next)) {
            mediaReadRequest++; mediaReadSubject = null; myMedia = Load.Idle
        }
        (desktopVisible - next).forEach { subject ->
            desktopEpochs = desktopEpochs + (subject to ((desktopEpochs[subject] ?: 0L) + 1))
            when (subject) {
                "war-room" -> { if (matches is Load.Loading) matches = Load.Idle; if (warNotices is Load.Loading) warNotices = Load.Idle }
                "challenges" -> {
                    if (challenges is Load.Loading) challenges = Load.Idle
                    entries = entries.mapValues { if (it.value is Load.Loading) Load.Idle else it.value }
                }
                "calendar" -> if (calendar is Load.Loading) calendar = Load.Idle
                "notifications" -> {
                    if (notificationPreferences is Load.Loading) notificationPreferences = Load.Idle
                    if (inbox is Load.Loading) inbox = Load.Idle
                }
                "account" -> if (lifecycle is Load.Loading) lifecycle = Load.Idle
            }
        }
        if ("war-room" !in next && "challenges" !in next && myMedia is Load.Loading) myMedia = Load.Idle
        desktopVisible = next
        desktopVisibleState = next
    }
    private fun desktopReadable(subject: String): Boolean {
        val member = manager.state as? AccountState.SignedIn
        return subject in desktopVisible && manager.isConfigured && member != null && member.userId == lastAccount &&
            !member.isAnonymous && member.provider != RECOVERY_PROVIDER
    }

    val viewer: String? get() = (manager.state as? AccountState.SignedIn)?.takeIf { !it.isAnonymous }?.userId

    // Original overloads remain the Rooms adapter implementation; desktop reads
    // use the explicit subject overloads below.
    private fun <T> fetch(set: (Load<T>) -> Unit, block: () -> T) {
        val generation = manager.generation
        set(Load.Loading)
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching(block) }
            if (generation != manager.generation) { set(Load.Failed(CommunityException.Stale().message!!)); return@launch }
            set(result.fold({ Load.Loaded(it) }, { Load.Failed(it.message ?: "That did not complete.") }))
        }
    }
    /** A member action; [done] runs only after the server confirmed it. */
    private fun act(progress: String, success: String, block: () -> Unit, done: () -> Unit = {}) {
        if (busy) return
        val generation = manager.generation
        busy = true; notice = progress
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching(block) }
            busy = false
            if (generation != manager.generation) { notice = CommunityException.Stale().message!!; return@launch }
            notice = result.fold({ success }, { it.message ?: "That did not complete." })
            if (result.isSuccess) done()
        }
    }
    private fun <T> fetch(set: (Load<T>) -> Unit, subject: String, block: () -> T) {
        if (!desktopReadable(subject)) return
        val generation = manager.generation
        val epoch = desktopEpochs[subject] ?: 0L
        set(Load.Loading)
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (generation != manager.generation || !desktopReadable(subject) || epoch != (desktopEpochs[subject] ?: 0L))
                    throw CancellationException("The account or window changed before the request started.")
                block()
            } }
            if (generation != manager.generation || !desktopReadable(subject) || epoch != (desktopEpochs[subject] ?: 0L)) return@launch
            set(result.fold({ Load.Loaded(it) }, { Load.Failed(it.message ?: "That did not complete.") }))
        }
    }
    /** A started mutation may finish; a hidden/replaced window never starts
     * queued transport or an automatic follow-up read. */
    private fun act(subject: String, progress: String, success: String, block: () -> Unit, done: () -> Unit = {}) {
        if (busy || !desktopReadable(subject)) return
        val generation = manager.generation
        val epoch = desktopEpochs[subject] ?: 0L
        busy = true; notice = progress
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (generation != manager.generation || !desktopReadable(subject) || epoch != (desktopEpochs[subject] ?: 0L))
                    throw CancellationException("The account or window changed before the request started.")
                block()
            } }
            busy = false
            if (generation != manager.generation) return@launch
            notice = result.fold({ success }, { it.message ?: "That did not complete." })
            if (result.isSuccess && desktopReadable(subject) && epoch == (desktopEpochs[subject] ?: 0L)) done()
        }
    }
    /** Clears every member view when the account actually changes or signs out (not when the panel
     * merely reopens, so a Studio room session keeps running). */
    fun accountChanged(account: String?) {
        if (account == lastAccount) return
        lastAccount = account
        reset()
        val session = roomSession.session
        if (session != null && session.account != account) roomSession.end("The account changed. Synchronisation stopped; your device copy of the project is unchanged.")
    }
    fun reset() {
        mediaReadRequest++; mediaReadSubject = null
        matches = Load.Idle; votes = emptyMap(); warNotices = Load.Idle; myMedia = Load.Idle; challenges = Load.Idle; entries = emptyMap()
        lifecycle = Load.Idle; pendingExport = null; notificationPreferences = Load.Idle; inbox = Load.Idle; myRooms = Load.Idle
        roomDetails = emptyMap(); roomMembers = emptyMap(); invitation = null; pendingRequests = Load.Idle; calendar = Load.Idle; moderation = ""
        roomStatus = ""; notice = ""
        roomReadEpoch++; roomCreateOperation++; roomInviteOperation++
        roomCreation = null; pendingRoomShare = null; roomPreview = Load.Idle; reviewedRoomCode = null
        roomCreating = false; roomInvitationWorking = false
    }

    // MARK: War Room

    fun loadMatches() = fetch<List<WarMatch>>({ result ->
        matches = result
        if (result is Load.Loaded) votes = result.value.associate { it.id to (votes[it.id]?.takeIf { machine -> machine.isPending } ?: WarVoteMachine.fromServer(it.myVote)) }
    }, subject = "war-room") { war.matches() }
    fun loadMyMedia() {
        val me = viewer ?: return
        val subject = when {
            desktopReadable("war-room") -> "war-room"
            desktopReadable("challenges") -> "challenges"
            else -> return
        }
        mediaReadSubject = subject
        val request = ++mediaReadRequest
        fetch({ if (request == mediaReadRequest) myMedia = it }, subject) { profile.portfolio(me) }
    }
    fun loadWarNotices() = fetch({ warNotices = it }, subject = "war-room") { war.notices() }

    /** The tap is pending until the server confirms; on refusal the previous server vote stays and
     * the matchup list is re-read so tallies only ever come from the server. */
    fun vote(match: WarMatch, choice: WarVoteChoice) {
        if (!desktopReadable("war-room")) return
        val epoch = desktopEpochs["war-room"] ?: 0L
        val machine = votes[match.id] ?: WarVoteMachine.fromServer(match.myVote)
        val pending = machine.tap(choice) ?: return
        votes = votes + (match.id to pending)
        val generation = manager.generation
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (generation != manager.generation || !desktopReadable("war-room") || epoch != (desktopEpochs["war-room"] ?: 0L))
                    throw CancellationException("The account or War Room window changed.")
                war.vote(match.id, choice)
            } }
            if (generation != manager.generation) return@launch
            val current = votes[match.id] ?: pending
            votes = votes + (match.id to result.fold({ current.confirm() }, { current.fail(it.message ?: "The vote was not recorded.") }))
            notice = result.fold({ "Vote recorded. You can change it until voting closes." }, { it.message ?: "The vote was not recorded." })
            if (result.isSuccess && desktopReadable("war-room") && epoch == (desktopEpochs["war-room"] ?: 0L)) loadMatches()
        }
    }
    fun propose(media: String, opponent: String, agreed: Boolean) = act("war-room", "Sending the matchup proposal…", "Proposal sent. The other creator must accept with their own approved video.",
        { war.propose(media, opponent.trim().lowercase(), agreed) }) { loadMatches() }
    fun accept(match: String, media: String, agreed: Boolean) = act("war-room", "Accepting the matchup…", "Matchup accepted. Voting is open for 24 hours.",
        { war.accept(match, media, agreed) }) { loadMatches() }
    fun withdraw(match: String) = act("war-room", "Withdrawing…", "Matchup withdrawn.", { war.withdraw(match) }) { loadMatches() }
    fun blockCreator(creator: String) = act("war-room", "Blocking…", "Creator blocked in War Room. Shared matchups were withdrawn.", { war.blockCreator(creator) }) { loadMatches() }
    fun reportMatch(match: String, reason: String) = act("war-room", "Sending report…", "Report recorded for moderator review.", { war.report(match, reason) })
    fun appeal(decision: String, explanation: String) = act("war-room", "Sending appeal…", "Appeal recorded for review.", { war.appeal(decision, explanation) }) { loadWarNotices() }

    // MARK: Challenges

    fun loadChallenges() = fetch({ challenges = it }, subject = "challenges") { challengesClient.list() }
    fun loadEntries(challenge: String) = fetch<ChallengeEntries>({ entries = entries + (challenge to it) }, subject = "challenges") { challengesClient.entries(challenge) }
    fun submitEntry(challenge: String, media: String) = act("challenges", "Submitting entry…", "Entry submitted.", { challengesClient.submit(challenge, media) }) { loadChallenges(); loadEntries(challenge) }
    fun withdrawEntry(challenge: String, entry: String) = act("challenges", "Withdrawing entry…", "Entry withdrawn.", { challengesClient.withdraw(entry) }) { loadChallenges(); loadEntries(challenge) }
    fun voteEntry(challenge: String, entry: String) = act("challenges", "Recording your favourite…", "Favourite recorded. You can change it until voting ends.", { challengesClient.vote(challenge, entry) }) { loadEntries(challenge) }

    // MARK: Account lifecycle (#262)

    fun loadLifecycle() = fetch({ lifecycle = it }, subject = "account") { lifecycleClient.status() }
    fun requestDeletion(confirmed: Boolean) {
        if (!confirmed) { notice = "Confirm that you understand what deletion removes. Nothing was sent."; return }
        act("account", "Filing the deletion request…", "Deletion requested. It completes after the seven-day cooling-off period unless you cancel.", { lifecycleClient.requestDeletion() }) { loadLifecycle() }
    }
    fun cancelDeletion(revision: Int) = act("account", "Cancelling the deletion request…", "Deletion cancelled. Nothing was removed.", { lifecycleClient.cancelDeletion(revision) }) { loadLifecycle() }
    fun prepareExport() {
        if (busy || !desktopReadable("account")) return
        val epoch = desktopEpochs["account"] ?: 0L
        val generation = manager.generation
        busy = true; notice = "Preparing your data export…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (generation != manager.generation || !desktopReadable("account") || epoch != (desktopEpochs["account"] ?: 0L))
                    throw CancellationException("The account or Account window changed.")
                lifecycleClient.export()
            } }
            busy = false
            if (generation != manager.generation) { notice = CommunityException.Stale().message!!; return@launch }
            result.onSuccess { pendingExport = it; notice = "Export ready. Choose where to save it." }
                .onFailure { notice = it.message ?: "The export could not be prepared." }
        }
    }
    /** Writes the held export to the document the member picked; a cancelled picker discards it. */
    fun saveExport(uri: Uri?, expectedGeneration: Long = manager.generation, expectedText: String? = pendingExport) {
        if (expectedGeneration != manager.generation || expectedText == null || pendingExport != expectedText) return
        val text = expectedText
        pendingExport = null
        if (uri == null) { notice = "Export discarded. Nothing was saved."; return }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (expectedGeneration != manager.generation) throw CancellationException("The account changed before the export save started.")
                getApplication<Application>().contentResolver.openOutputStream(uri, "wt")?.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                    ?: throw IllegalStateException("The chosen location could not be opened.")
            } }
            if (expectedGeneration != manager.generation) return@launch
            notice = result.fold({ "Export saved. It contains your server records only; projects stay on this device." }, { it.message ?: "The export could not be saved." })
            loadLifecycle()
        }
    }

    // MARK: Notifications (#290)

    fun loadNotificationPreferences() = fetch({ notificationPreferences = it }, subject = "notifications") { notifications.preferences() }
    fun saveNotificationPreferences(value: ServerNotificationPreferences) =
        act("notifications", "Saving notification preferences…", "Notification preferences saved on the server.", { notifications.save(value) }) { loadNotificationPreferences() }
    fun loadInbox() = fetch({ inbox = it }, subject = "notifications") { notifications.inbox() }
    fun markRead(delivery: String) = act("notifications", "Marking as read…", "Marked as read.", { notifications.markRead(delivery) }) { loadInbox() }

    // MARK: Shared rooms (#288)

    // Called by the fixed desktop host, including while its content is unplaced.
    fun setRoomsWindowVisible(visible: Boolean) {
        roomsWindowRequested = visible
        updateRoomsVisibility()
    }
    fun setRoomsAppForeground(foreground: Boolean) {
        roomsAppForeground = foreground
        updateRoomsVisibility()
    }
    private fun updateRoomsVisibility() {
        val visible = roomsWindowRequested && roomsAppForeground
        if (roomsWindowVisible == visible) return
        roomsWindowVisible = visible
        if (!visible) {
            roomReadEpoch++
            if (myRooms is Load.Loading) myRooms = Load.Idle
            if (pendingRequests is Load.Loading) pendingRequests = Load.Idle
            roomDetails = roomDetails.mapValues { if (it.value is Load.Loading) Load.Idle else it.value }
            roomMembers = roomMembers.mapValues { if (it.value is Load.Loading) Load.Idle else it.value }
            clearRoomInvitationPreview()
        }
    }
    private fun requireRoomMember(): Boolean {
        if (!roomsWindowVisible) return false
        if (!manager.isConfigured) { roomStatus = CommunityException.NotConfigured().message!!; return false }
        if (viewer == null) { roomStatus = CommunityException.SignedOut().message!!; return false }
        return true
    }
    private fun <T> roomFetch(set: (Load<T>) -> Unit, block: () -> T) {
        if (!requireRoomMember()) return
        val epoch = roomReadEpoch; val member = viewer
        fetch({ if (roomsWindowVisible && roomReadEpoch == epoch && viewer == member) set(it) }) {
            if (!roomsWindowVisible || roomReadEpoch != epoch || viewer != member) throw CommunityException.Stale()
            block()
        }
    }
    private fun roomAct(progress: String, success: String, block: () -> Unit, done: (Boolean) -> Unit = {}) {
        if (!requireRoomMember() || roomCreating || roomInvitationWorking) return
        val epoch = roomReadEpoch; val member = viewer
        act(progress, success, {
            if (!roomsWindowVisible || roomReadEpoch != epoch || viewer != member) throw CommunityException.Stale()
            block()
        }) { done(roomsWindowVisible && roomReadEpoch == epoch && viewer == member) }
    }

    fun createRoom(title: String, share: RoomProjectShareDraft, consent: Boolean) {
        if (!requireRoomMember() || roomsBusy || pendingRoomShare != null) return
        val member = viewer; val generation = manager.generation; val operation = ++roomCreateOperation; val epoch = roomReadEpoch
        roomCreating = true; roomCreation = null; notice = "Creating the room and recording the chosen project share…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                rooms.createRoom(title, share, consent) { roomsWindowVisible && roomReadEpoch == epoch && manager.generation == generation && viewer == member }
            } }
            if (operation != roomCreateOperation || generation != manager.generation || viewer != member) return@launch
            roomCreating = false
            result.onSuccess { outcome ->
                roomCreation = outcome
                when (outcome) {
                    is RoomCreationOutcome.Created -> { pendingRoomShare = null; notice = "Room and project reference confirmed. No project files were uploaded." }
                    is RoomCreationOutcome.CreatedWithoutProject -> {
                        pendingRoomShare = PendingRoomProjectShare(outcome.room, share)
                        notice = "The room exists, but its project share was not confirmed. Check this room before creating another."
                    }
                }
                if (roomsWindowVisible && roomReadEpoch == epoch) loadRooms()
            }.onFailure { notice = "Room creation was not confirmed. Load your rooms before trying again. " + (it.message ?: "") }
        }
    }
    /** Reconcile a known partial room; never issue another create or overwrite a different share. */
    fun finishPendingRoomShare() {
        val pending = pendingRoomShare ?: return
        if (!requireRoomMember() || roomsBusy) return
        val member = viewer; val generation = manager.generation; val operation = ++roomCreateOperation; val epoch = roomReadEpoch
        roomCreating = true; notice = "Checking the existing room's project share…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (!roomsWindowVisible || roomReadEpoch != epoch || manager.generation != generation || viewer != member) throw CommunityException.Stale()
                val current = rooms.summary(pending.room)
                if (manager.generation != generation || viewer != member || !roomsWindowVisible || roomReadEpoch != epoch) throw CommunityException.Stale()
                if (current.ownerId != member) throw CommunityException.InvalidResponse("This room is not owned by the current account.")
                val revision = current.projectRevision ?: throw CommunityException.InvalidResponse("Current room revision unavailable.")
                if (current.projectRef == RoomProjectShare.PREFIX + pending.share.projectId.lowercase()
                    && current.projectTitle == pending.share.title.trim() && current.permissions?.toSet() == pending.share.permissions.toSet()) revision
                else {
                    if (current.projectRef != null) throw CommunityException.Server("The room already shares a different project or permission set. Nothing was overwritten.", null)
                    rooms.setProject(pending.room, pending.share, revision) { roomsWindowVisible && roomReadEpoch == epoch && manager.generation == generation && viewer == member }
                }
            } }
            if (operation != roomCreateOperation || generation != manager.generation || viewer != member) return@launch
            roomCreating = false
            result.onSuccess { revision ->
                pendingRoomShare = null; roomCreation = RoomCreationOutcome.Created(pending.room, revision)
                notice = "The existing room's project share is confirmed. No project files were uploaded."
                if (roomsWindowVisible && roomReadEpoch == epoch) loadRooms()
            }.onFailure { notice = "The room still exists; its intended share was not confirmed. " + (it.message ?: "") }
        }
    }
    fun dismissPendingRoomShare() {
        if (roomCreating) return
        pendingRoomShare = null; roomCreation = null
        notice = "Pending share draft dismissed. No room was deleted; use the room list to manage it."
    }
    fun clearRoomInvitationPreview() {
        roomInviteOperation++; reviewedRoomCode = null; roomPreview = Load.Idle; roomInvitationWorking = false
    }
    fun previewRoomInvitation(raw: String) {
        if (!requireRoomMember() || roomsBusy) return
        val code = RoomInvitationPolicy.normalize(raw); val generation = manager.generation; val member = viewer
        val operation = ++roomInviteOperation
        reviewedRoomCode = null; roomPreview = Load.Loading; roomInvitationWorking = true
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (!roomsWindowVisible || operation != roomInviteOperation || manager.generation != generation || viewer != member) throw CommunityException.Stale()
                rooms.previewInvitation(code)
            } }
            if (operation != roomInviteOperation || generation != manager.generation || viewer != member || !roomsWindowVisible) return@launch
            roomInvitationWorking = false
            roomPreview = result.fold({ reviewedRoomCode = code; Load.Loaded(it) }, { Load.Failed(it.message ?: "Invitation unavailable.") })
        }
    }
    fun requestRoomAdmission(raw: String, consent: Boolean) {
        if (!requireRoomMember() || roomsBusy) return
        val code = RoomInvitationPolicy.normalize(raw)
        if (!consent || reviewedRoomCode != code || roomPreview !is Load.Loaded) {
            notice = "Review this exact invitation and explicitly accept it before requesting admission. Nothing was sent."; return
        }
        val generation = manager.generation; val member = viewer; val operation = ++roomInviteOperation
        roomInvitationWorking = true
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (!roomsWindowVisible || operation != roomInviteOperation || manager.generation != generation || viewer != member) throw CommunityException.Stale()
                rooms.requestAdmission(code, true)
            } }
            if (operation != roomInviteOperation || generation != manager.generation || viewer != member || !roomsWindowVisible) return@launch
            roomInvitationWorking = false; reviewedRoomCode = null; roomPreview = Load.Idle
            notice = result.fold({ when (it) {
                is AdmissionOutcome.PendingOwnerApproval -> "Request recorded. The owner must approve it before you become a member."
                is AdmissionOutcome.AlreadyRequested -> "You already requested this room. Check pending requests; membership is not assumed."
            } }, { "The request was not confirmed. Check pending requests before trying again. " + (it.message ?: "") })
        }
    }

    fun loadRooms() = roomFetch({ myRooms = it }) { rooms.myRooms() }
    fun loadPendingRequests() = roomFetch({ pendingRequests = it }) { rooms.pendingRequests() }
    /** Summary and members of one room; the session begins with the server's edit right and project. */
    fun openRoom(room: RoomSummary) {
        if (!requireRoomMember()) return
        val me = viewer ?: return
        roomFetch<RoomDetail>({ load ->
            roomDetails = roomDetails + (room.id to load)
            if (load is Load.Loaded) {
                val detail = load.value
                roomSession.begin(room.id, detail.commandRevision ?: room.commandRevision, detail.canEdit == true, me, detail.projectID)
                roomSessionVersion++
            }
        }) { rooms.summary(room.id) }
        roomFetch<List<RoomMember>>({ roomMembers = roomMembers + (room.id to it) }) { rooms.members(room.id) }
    }
    fun mintInvitation(room: RoomSummary) {
        if (!requireRoomMember() || roomsBusy) return
        val generation = manager.generation; val epoch = roomReadEpoch
        busy = true; notice = "Creating an invitation…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                if (!roomsWindowVisible || roomReadEpoch != epoch) throw CommunityException.Stale()
                rooms.mintInvitation(room.id)
            } }
            busy = false
            if (generation != manager.generation) { notice = CommunityException.Stale().message!!; return@launch }
            result.onSuccess { invitation = room.id to it; notice = "Invitation created. Pending requests from older codes were revoked."; if (roomsWindowVisible && roomReadEpoch == epoch) openRoom(room) }
                .onFailure { notice = it.message ?: "The invitation was not created." }
        }
    }
    fun revokeInvitations(room: RoomSummary) = roomAct("Revoking invitations…", "Invitations and pending requests revoked.", { rooms.revokeInvitations(room.id) }) { refresh ->
        if (invitation?.first == room.id) invitation = null
        if (refresh) openRoom(room)
    }
    fun approveMember(room: RoomSummary, member: String) = roomAct("Approving…", "Request approved. The member can now open the shared project.", { rooms.approve(room.id, member) }) { refresh -> if (refresh) openRoom(room) }
    fun declineMember(room: RoomSummary, member: String) = roomAct("Declining…", "Request declined. The code they used cannot admit them again.", { rooms.decline(room.id, member) }) { refresh -> if (refresh) openRoom(room) }
    fun removeMember(room: RoomSummary, member: String) = roomAct("Removing…", "Member removed. Their device copy is theirs; they no longer receive shared edits.", { rooms.remove(room.id, member) }) { refresh -> if (refresh) openRoom(room) }
    fun blockMember(room: RoomSummary, member: String) = roomAct("Blocking…", "Member removed and blocked from requesting this room again.", { rooms.block(room.id, member) }) { refresh -> if (refresh) openRoom(room) }
    fun setRole(room: RoomSummary, member: String, role: RoomRole) = roomAct("Changing role…", "Role changed to ${role.wire}.", { rooms.setRole(room.id, member, role) }) { refresh -> if (refresh) openRoom(room) }
    fun closeOrLeave(room: RoomSummary, owner: Boolean) = roomAct(if (owner) "Closing room…" else "Leaving room…",
        if (owner) "Room closed. Members lost access; no project was deleted." else "You left the room. Synchronisation stopped.",
        { if (owner) rooms.close(room.id) else rooms.leave(room.id) }) { refresh ->
        if (roomSession.session?.room == room.id) roomSession.end(if (owner) "Room closed. Your device copy of the project is unchanged." else "You left the room. Your device copy of the project is unchanged.")
        roomDetails = roomDetails - room.id; roomMembers = roomMembers - room.id; roomSessionVersion++
        if (refresh) loadRooms()
    }

    /** Pull and push once from the panel; Studio does the same every few seconds while it shares. */
    fun checkRoomEdits() {
        if (roomSession.session == null) return
        val generation = manager.generation
        viewModelScope.launch {
            val fetched = withContext(Dispatchers.IO) { runCatching { roomSession.fetchRemote() } }
            if (generation != manager.generation) return@launch
            roomSession.applyQueued()
            val drained = withContext(Dispatchers.IO) { runCatching { roomSession.drain() } }
            roomSession.applyQueued()
            roomSessionVersion++
            roomStatus = fetched.fold({ catchUp ->
                val received = when (catchUp) {
                    RoomCommandSync.CatchUpOutcome.UpToDate -> "No new shared edits."
                    is RoomCommandSync.CatchUpOutcome.Received -> "${catchUp.count} new shared edit(s) received."
                    is RoomCommandSync.CatchUpOutcome.Gap -> "Some edits are on an older page; check again."
                    RoomCommandSync.CatchUpOutcome.AccessEnded -> roomSession.endReason ?: "Room access ended."
                }
                val sent = when (val drain = drained.getOrNull()) {
                    is RoomSessionCoordinator.DrainOutcome.Sent -> " ${drain.count} local edit(s) sent."
                    is RoomSessionCoordinator.DrainOutcome.Conflict -> " Apply ${drain.missing} remote edit(s) before yours are sent."
                    is RoomSessionCoordinator.DrainOutcome.Held -> " A conflicting edit needs your decision."
                    is RoomSessionCoordinator.DrainOutcome.Stopped -> " ${drain.reason}"
                    RoomSessionCoordinator.DrainOutcome.Idle, null -> drained.exceptionOrNull()?.let { " ${it.message ?: "Sending failed."}" } ?: ""
                }
                describeRoom(received + sent)
            }, { it.message ?: "Synchronisation failed." })
        }
    }
    fun resolveConflict(keepMine: Boolean) { roomSession.resolveHeldConflict(keepMine); roomSessionVersion++; checkRoomEdits() }
    fun skipBlockedEdit() { roomSession.skipBlockedRemote(); roomSessionVersion++; checkRoomEdits() }
    fun leaveRoomSync() { roomSession.end("You stopped synchronising. Your device copy of the project is unchanged."); roomStatus = roomSession.endReason.orEmpty(); roomSessionVersion++ }
    fun noteSessionChanged() { roomSessionVersion++ }
    fun describeRoom(prefix: String = ""): String {
        val remote = roomSession.pendingRemoteCount
        val waiting = when {
            remote == 0 -> ""
            roomSession.handoff != null -> " $remote remote edit(s) waiting to apply in Studio."
            else -> " $remote remote edit(s) waiting until you synchronise the shared project open in Studio."
        }
        return "$prefix Head revision ${roomSession.head}.$waiting".trim()
    }

    // MARK: Challenge moderation (server-gated: moderation permission with MFA)

    private fun moderate(progress: String, success: String, block: () -> Unit) = act("challenges", progress, success, block) { moderation = success; loadChallenges() }
    fun createChallenge(title: String, brief: String, reward: String) =
        moderate("Creating the draft challenge…", "Draft challenge created. Schedule it to make it visible.") { challengesClient.create(title, brief, reward) }
    fun scheduleChallenge(challenge: ChallengeSummary, draft: ChallengeScheduleDraft) =
        moderate("Scheduling…", "Challenge scheduled.") { challengesClient.schedule(challenge.id, challenge.revision, draft) }
    fun cancelChallenge(challenge: ChallengeSummary, reason: String) =
        moderate("Cancelling…", "Challenge cancelled.") { challengesClient.cancel(challenge.id, challenge.revision, reason) }
    fun removeEntry(challenge: ChallengeSummary, entry: String, reason: String) = act("challenges", "Removing the entry…", "Entry removed and its votes cleared.",
        { challengesClient.removeEntry(challenge.id, challenge.revision, entry, reason) }) { moderation = "Entry removed."; loadChallenges(); loadEntries(challenge.id) }

    // MARK: Calendar (read-only)

    fun loadCalendar(month: java.time.YearMonth = calendarMonth) {
        if (!desktopReadable("calendar")) return
        calendarMonth = month
        fetch({ calendar = it }, subject = "calendar") { calendarClient.month(month) }
    }
}
