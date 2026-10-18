package com.stickdeath.studio.connect

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
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
    /** Bumped whenever the room session's counters may have changed, so the panel re-reads them. */
    var roomSessionVersion by mutableStateOf(0L); private set
    var calendarMonth by mutableStateOf(java.time.YearMonth.now()); private set
    var calendar by mutableStateOf<Load<CalendarMonth>>(Load.Idle); private set
    /** Moderator results, from the server only. */
    var moderation by mutableStateOf(""); private set
    private var lastAccount: String? = null

    val viewer: String? get() = (manager.state as? AccountState.SignedIn)?.takeIf { !it.isAnonymous }?.userId

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
        matches = Load.Idle; votes = emptyMap(); warNotices = Load.Idle; myMedia = Load.Idle; challenges = Load.Idle; entries = emptyMap()
        lifecycle = Load.Idle; pendingExport = null; notificationPreferences = Load.Idle; inbox = Load.Idle; myRooms = Load.Idle
        roomDetails = emptyMap(); roomMembers = emptyMap(); invitation = null; pendingRequests = Load.Idle; calendar = Load.Idle; moderation = ""
        roomStatus = ""; notice = ""
    }

    // MARK: War Room

    fun loadMatches() = fetch<List<WarMatch>>({ result ->
        matches = result
        if (result is Load.Loaded) votes = result.value.associate { it.id to (votes[it.id]?.takeIf { machine -> machine.isPending } ?: WarVoteMachine.fromServer(it.myVote)) }
    }) { war.matches() }
    fun loadMyMedia() { val me = viewer ?: return; fetch({ myMedia = it }) { profile.portfolio(me) } }
    fun loadWarNotices() = fetch({ warNotices = it }) { war.notices() }

    /** The tap is pending until the server confirms; on refusal the previous server vote stays and
     * the matchup list is re-read so tallies only ever come from the server. */
    fun vote(match: WarMatch, choice: WarVoteChoice) {
        val machine = votes[match.id] ?: WarVoteMachine.fromServer(match.myVote)
        val pending = machine.tap(choice) ?: return
        votes = votes + (match.id to pending)
        val generation = manager.generation
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { war.vote(match.id, choice) } }
            if (generation != manager.generation) return@launch
            val current = votes[match.id] ?: pending
            votes = votes + (match.id to result.fold({ current.confirm() }, { current.fail(it.message ?: "The vote was not recorded.") }))
            notice = result.fold({ "Vote recorded. You can change it until voting closes." }, { it.message ?: "The vote was not recorded." })
            if (result.isSuccess) loadMatches()
        }
    }
    fun propose(media: String, opponent: String, agreed: Boolean) = act("Sending the matchup proposal…", "Proposal sent. The other creator must accept with their own approved video.",
        { war.propose(media, opponent.trim().lowercase(), agreed) }) { loadMatches() }
    fun accept(match: String, media: String, agreed: Boolean) = act("Accepting the matchup…", "Matchup accepted. Voting is open for 24 hours.",
        { war.accept(match, media, agreed) }) { loadMatches() }
    fun withdraw(match: String) = act("Withdrawing…", "Matchup withdrawn.", { war.withdraw(match) }) { loadMatches() }
    fun blockCreator(creator: String) = act("Blocking…", "Creator blocked in War Room. Shared matchups were withdrawn.", { war.blockCreator(creator) }) { loadMatches() }
    fun reportMatch(match: String, reason: String) = act("Sending report…", "Report recorded for moderator review.", { war.report(match, reason) })
    fun appeal(decision: String, explanation: String) = act("Sending appeal…", "Appeal recorded for review.", { war.appeal(decision, explanation) }) { loadWarNotices() }

    // MARK: Challenges

    fun loadChallenges() = fetch({ challenges = it }) { challengesClient.list() }
    fun loadEntries(challenge: String) = fetch<ChallengeEntries>({ entries = entries + (challenge to it) }) { challengesClient.entries(challenge) }
    fun submitEntry(challenge: String, media: String) = act("Submitting entry…", "Entry submitted.", { challengesClient.submit(challenge, media) }) { loadChallenges(); loadEntries(challenge) }
    fun withdrawEntry(challenge: String, entry: String) = act("Withdrawing entry…", "Entry withdrawn.", { challengesClient.withdraw(entry) }) { loadChallenges(); loadEntries(challenge) }
    fun voteEntry(challenge: String, entry: String) = act("Recording your favourite…", "Favourite recorded. You can change it until voting ends.", { challengesClient.vote(challenge, entry) }) { loadEntries(challenge) }

    // MARK: Account lifecycle (#262)

    fun loadLifecycle() = fetch({ lifecycle = it }) { lifecycleClient.status() }
    fun requestDeletion(confirmed: Boolean) {
        if (!confirmed) { notice = "Confirm that you understand what deletion removes. Nothing was sent."; return }
        act("Filing the deletion request…", "Deletion requested. It completes after the seven-day cooling-off period unless you cancel.", { lifecycleClient.requestDeletion() }) { loadLifecycle() }
    }
    fun cancelDeletion(revision: Int) = act("Cancelling the deletion request…", "Deletion cancelled. Nothing was removed.", { lifecycleClient.cancelDeletion(revision) }) { loadLifecycle() }
    fun prepareExport() {
        if (busy) return
        val generation = manager.generation
        busy = true; notice = "Preparing your data export…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { lifecycleClient.export() } }
            busy = false
            if (generation != manager.generation) { notice = CommunityException.Stale().message!!; return@launch }
            result.onSuccess { pendingExport = it; notice = "Export ready. Choose where to save it." }
                .onFailure { notice = it.message ?: "The export could not be prepared." }
        }
    }
    /** Writes the held export to the document the member picked; a cancelled picker discards it. */
    fun saveExport(uri: Uri?) {
        val text = pendingExport ?: return
        pendingExport = null
        if (uri == null) { notice = "Export discarded. Nothing was saved."; return }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                getApplication<Application>().contentResolver.openOutputStream(uri, "wt")?.use { it.write(text.toByteArray(Charsets.UTF_8)) }
                    ?: throw IllegalStateException("The chosen location could not be opened.")
            } }
            notice = result.fold({ "Export saved. It contains your server records only; projects stay on this device." }, { it.message ?: "The export could not be saved." })
            loadLifecycle()
        }
    }

    // MARK: Notifications (#290)

    fun loadNotificationPreferences() = fetch({ notificationPreferences = it }) { notifications.preferences() }
    fun saveNotificationPreferences(value: ServerNotificationPreferences) =
        act("Saving notification preferences…", "Notification preferences saved on the server.", { notifications.save(value) }) { loadNotificationPreferences() }
    fun loadInbox() = fetch({ inbox = it }) { notifications.inbox() }
    fun markRead(delivery: String) = act("Marking as read…", "Marked as read.", { notifications.markRead(delivery) }) { loadInbox() }

    // MARK: Shared rooms (#288)

    fun loadRooms() = fetch({ myRooms = it }) { rooms.myRooms() }
    fun loadPendingRequests() = fetch({ pendingRequests = it }) { rooms.pendingRequests() }
    /** Summary and members of one room; the session begins with the server's edit right and project. */
    fun openRoom(room: RoomSummary) {
        val me = viewer ?: run { notice = "Sign in with a full account to open a shared room."; return }
        fetch<RoomDetail>({ load ->
            roomDetails = roomDetails + (room.id to load)
            if (load is Load.Loaded) {
                val detail = load.value
                roomSession.begin(room.id, detail.commandRevision ?: room.commandRevision, detail.canEdit == true, me, detail.projectID)
                roomSessionVersion++
            }
        }) { rooms.summary(room.id) }
        fetch<List<RoomMember>>({ roomMembers = roomMembers + (room.id to it) }) { rooms.members(room.id) }
    }
    fun mintInvitation(room: RoomSummary) {
        if (busy) return
        val generation = manager.generation
        busy = true; notice = "Creating an invitation…"
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { rooms.mintInvitation(room.id) } }
            busy = false
            if (generation != manager.generation) { notice = CommunityException.Stale().message!!; return@launch }
            result.onSuccess { invitation = room.id to it; notice = "Invitation created. Pending requests from older codes were revoked."; openRoom(room) }
                .onFailure { notice = it.message ?: "The invitation was not created." }
        }
    }
    fun revokeInvitations(room: RoomSummary) = act("Revoking invitations…", "Invitations and pending requests revoked.", { rooms.revokeInvitations(room.id) }) {
        if (invitation?.first == room.id) invitation = null
        openRoom(room)
    }
    fun approveMember(room: RoomSummary, member: String) = act("Approving…", "Request approved. The member can now open the shared project.", { rooms.approve(room.id, member) }) { openRoom(room) }
    fun declineMember(room: RoomSummary, member: String) = act("Declining…", "Request declined. The code they used cannot admit them again.", { rooms.decline(room.id, member) }) { openRoom(room) }
    fun removeMember(room: RoomSummary, member: String) = act("Removing…", "Member removed. Their device copy is theirs; they no longer receive shared edits.", { rooms.remove(room.id, member) }) { openRoom(room) }
    fun blockMember(room: RoomSummary, member: String) = act("Blocking…", "Member removed and blocked from requesting this room again.", { rooms.block(room.id, member) }) { openRoom(room) }
    fun setRole(room: RoomSummary, member: String, role: RoomRole) = act("Changing role…", "Role changed to ${role.wire}.", { rooms.setRole(room.id, member, role) }) { openRoom(room) }
    fun closeOrLeave(room: RoomSummary, owner: Boolean) = act(if (owner) "Closing room…" else "Leaving room…",
        if (owner) "Room closed. Members lost access; no project was deleted." else "You left the room. Synchronisation stopped.",
        { if (owner) rooms.close(room.id) else rooms.leave(room.id) }) {
        if (roomSession.session?.room == room.id) roomSession.end(if (owner) "Room closed. Your device copy of the project is unchanged." else "You left the room. Your device copy of the project is unchanged.")
        roomDetails = roomDetails - room.id; roomMembers = roomMembers - room.id; roomSessionVersion++
        loadRooms()
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

    private fun moderate(progress: String, success: String, block: () -> Unit) = act(progress, success, block) { moderation = success; loadChallenges() }
    fun createChallenge(title: String, brief: String, reward: String) =
        moderate("Creating the draft challenge…", "Draft challenge created. Schedule it to make it visible.") { challengesClient.create(title, brief, reward) }
    fun scheduleChallenge(challenge: ChallengeSummary, draft: ChallengeScheduleDraft) =
        moderate("Scheduling…", "Challenge scheduled.") { challengesClient.schedule(challenge.id, challenge.revision, draft) }
    fun cancelChallenge(challenge: ChallengeSummary, reason: String) =
        moderate("Cancelling…", "Challenge cancelled.") { challengesClient.cancel(challenge.id, challenge.revision, reason) }
    fun removeEntry(challenge: ChallengeSummary, entry: String, reason: String) = act("Removing the entry…", "Entry removed and its votes cleared.",
        { challengesClient.removeEntry(challenge.id, challenge.revision, entry, reason) }) { moderation = "Entry removed."; loadChallenges(); loadEntries(challenge.id) }

    // MARK: Calendar (read-only)

    fun loadCalendar(month: java.time.YearMonth = calendarMonth) {
        calendarMonth = month
        fetch({ calendar = it }) { calendarClient.month(month) }
    }
}
