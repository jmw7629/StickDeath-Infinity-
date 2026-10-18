package com.stickdeath.studio.connect

import android.content.Intent
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.stickdeath.studio.StudioViewModel
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/** Shared rooms: membership, owner tools and Studio synchronisation for one explicitly shared project.
 * There is no chat, calling, camera, microphone or screen sharing here. */
@Composable internal fun RoomSyncSection(community: CommunityViewModel) {
    val studio: StudioViewModel = viewModel()
    @Suppress("UNUSED_VARIABLE") val version = community.roomSessionVersion // re-read session counters
    Text("Shared rooms", style = MaterialTheme.typography.titleMedium)
    Text("Rooms share one explicitly chosen Studio project with members the owner approves. Edits travel as fenced commands; overlapping edits are held for your decision, never overwritten.")
    Row {
        TextButton({ community.loadRooms() }) { Text("Load my rooms") }
        TextButton({ community.loadPendingRequests() }) { Text("My pending requests") }
    }
    LoadState(community.pendingRequests, "") { requests ->
        if (requests.isEmpty()) Text("You have no requests waiting for an owner.")
        requests.forEach { Text("${it.title.ifBlank { "Untitled room" }} · waiting for the owner · expires ${shortTime(it.expiresAt)}", style = MaterialTheme.typography.bodySmall) }
    }
    var expanded by remember { mutableStateOf<String?>(null) }
    LoadState(community.myRooms, "Load your rooms to manage members or synchronise a shared project.") { rooms ->
        if (rooms.isEmpty()) Text("You are not in any open room.")
        rooms.forEach { room ->
            val owner = room.ownerId == community.viewer
            Text("${room.title.ifBlank { "Untitled room" }}${room.projectTitle?.let { " · $it" } ?: " · nothing shared"} · ${if (owner) "you own it" else "member"}",
                style = MaterialTheme.typography.titleSmall)
            TextButton({
                if (expanded == room.id) expanded = null else { expanded = room.id; community.openRoom(room) }
            }) { Text(if (expanded == room.id) "Hide room" else "Open room") }
            if (expanded == room.id) RoomDetailSection(community, studio, room, owner)
        }
    }
    if (community.roomStatus.isNotEmpty()) Text(community.roomStatus, style = MaterialTheme.typography.bodySmall)
}

@Composable private fun RoomDetailSection(community: CommunityViewModel, studio: StudioViewModel, room: RoomSummary, owner: Boolean) {
    val session = community.roomSession
    community.roomDetails[room.id]?.let { load ->
        LoadState(load, "") { detail ->
            Text("Shared project: ${detail.projectTitle ?: "none yet"}")
            Text("Permissions: ${(detail.permissions ?: listOf("view")).joinToString()} · your role: ${detail.myRole ?: "member"} · ${if (detail.canEdit == true) "you can edit" else "view only"}",
                style = MaterialTheme.typography.bodySmall)
            Text("Project revision ${detail.projectRevision ?: 0} · edit stream revision ${detail.commandRevision ?: 0} · ${detail.members ?: 0} accepted member(s)",
                style = MaterialTheme.typography.bodySmall)
            StudioSyncControls(community, studio, room, detail)
        }
    }
    if (session.session?.room == room.id) SessionState(community)
    if (owner) InvitationControls(community, room)
    community.roomMembers[room.id]?.let { load ->
        Text(if (owner) "Members and requests" else "Your membership", style = MaterialTheme.typography.titleSmall)
        LoadState(load, "") { members ->
            if (members.isEmpty()) Text("No membership rows are visible for this room.")
            members.forEach { member -> MemberRow(community, room, member, owner) }
        }
    }
    var confirm by remember(room.id) { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Checkbox(confirm, { confirm = it })
        Text(if (owner) "Close this room for everyone (members lose access; nobody's device project is deleted)" else "Leave this room (anything already on your device stays yours)")
    }
    Button({ community.closeOrLeave(room, owner); confirm = false }, enabled = confirm && !community.busy) { Text(if (owner) "Close room" else "Leave room") }
}

@Composable private fun StudioSyncControls(community: CommunityViewModel, studio: StudioViewModel, room: RoomSummary, detail: RoomDetail) {
    val project = detail.projectID
    val open = studio.document
    when {
        project == null -> Text("No device project is shared in this room, so there is nothing to synchronise.", style = MaterialTheme.typography.bodySmall)
        studio.roomSyncRoom == room.id -> {
            Text("Studio is synchronising ${open?.name ?: "the shared project"} with this room every few seconds while it stays open.", style = MaterialTheme.typography.bodySmall)
            TextButton({ studio.stopRoomSync(); community.noteSessionChanged() }) { Text("Stop synchronising Studio") }
        }
        open?.id == project -> Button({ if (studio.startRoomSync(community.roomSession, room.id, room.title)) community.noteSessionChanged() },
            enabled = community.roomSession.session?.room == room.id) { Text("Synchronise the open project with this room") }
        else -> Text("The shared project is not the project open in Studio. Shared edits replay only onto your device copy of the same project; open it in Studio and return here. Nothing is downloaded.",
            style = MaterialTheme.typography.bodySmall)
    }
}

@Composable private fun SessionState(community: CommunityViewModel) {
    val session = community.roomSession
    session.heldConflict?.let { held ->
        Text("Another creator changed the same ${held.target ?: "project"} at the same time. Review their edit, then keep yours on top or discard yours. Nothing was overwritten.")
        Row {
            Button({ community.resolveConflict(keepMine = true) }) { Text("Keep mine on top") }
            TextButton({ community.resolveConflict(keepMine = false) }) { Text("Discard mine") }
        }
    }
    session.blockedRemote?.let { blocked ->
        Text("Shared edit #${blocked.revision} is waiting: ${blocked.reason}")
        TextButton({ community.skipBlockedEdit() }) { Text("Skip this edit (my copy will differ)") }
    }
    session.endReason?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    if (session.handoff != null) Text("In Studio this session: ${session.appliedRemoteCount} shared edit(s) applied, ${session.publishedLocalCount} of yours queued for sending, " +
        "${session.pendingLocalCount} still unsent, ${session.skippedRemote.size} skipped, ${session.unsharedLocalCount} local change(s) not shared" +
        (session.lastUnsharedReason?.let { " (latest: $it)" } ?: "") + ".", style = MaterialTheme.typography.bodySmall)
    Text(community.describeRoom(), style = MaterialTheme.typography.bodySmall)
    Row {
        TextButton({ community.checkRoomEdits() }) { Text("Check for edits now") }
        TextButton({ community.leaveRoomSync() }) { Text("Stop synchronisation") }
    }
    Text("Typed Studio edits (layer settings, frame timing, deletions, track mix, project name) and drawings that replay exactly are shared. Undo, Redo, fills, images, audio clips, frame and layer structure, and moved or restyled drawings are listed as not shared. Drawings made with Android brushes, shapes or text use an Android form that iOS Studio reports as not replayable.",
        style = MaterialTheme.typography.bodySmall)
}

@Composable private fun InvitationControls(community: CommunityViewModel, room: RoomSummary) {
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    Text("Invitations", style = MaterialTheme.typography.titleSmall)
    Row {
        TextButton({ community.mintInvitation(room) }, enabled = !community.busy) { Text("Create 24-hour invite") }
        TextButton({ community.revokeInvitations(room) }, enabled = !community.busy) { Text("Revoke invites and pending requests") }
    }
    val code = community.invitation?.takeIf { it.first == room.id }?.second ?: return
    SelectionContainer { Text(code, style = MaterialTheme.typography.bodySmall) }
    Row {
        TextButton({ clipboard.setText(AnnotatedString(code)); community.noteSessionChanged() }) { Text("Copy code") }
        TextButton({
            runCatching { context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, RoomInvitationPolicy.shareText(code, room.title)), "Share room invitation")) }
        }) { Text("Share code") }
    }
    Text("Expires after 24 hours or 20 requests. A new code revokes the old code and pending requests. The code allows an admission request only; it is not an account credential.",
        style = MaterialTheme.typography.bodySmall)
}

@Composable private fun MemberRow(community: CommunityViewModel, room: RoomSummary, member: RoomMember, owner: Boolean) {
    val me = member.userId == community.viewer
    SelectionContainer { Text(if (me) "${member.userId} (you)" else member.userId, style = MaterialTheme.typography.bodySmall) }
    Text("${member.statusText}${member.role?.let { " · $it" } ?: ""}${member.requestExpiresAt?.takeIf { !member.ownerApproved && !member.revoked }?.let { " · request expires ${shortTime(it)}" } ?: ""}")
    if (!owner || member.revoked || me) return
    Row(Modifier.padding(bottom = 4.dp)) {
        if (member.awaitsApproval) {
            TextButton({ community.approveMember(room, member.userId) }, enabled = !community.busy) { Text("Approve") }
            TextButton({ community.declineMember(room, member.userId) }, enabled = !community.busy) { Text("Decline") }
        }
        if (member.isActive) {
            val editor = member.role == RoomRole.Editor.wire
            TextButton({ community.setRole(room, member.userId, if (editor) RoomRole.Viewer else RoomRole.Editor) },
                enabled = !community.busy && (editor || room.sharesEdit)) { Text(if (editor) "Make viewer" else "Make editor") }
            TextButton({ community.removeMember(room, member.userId) }, enabled = !community.busy) { Text("Remove") }
        }
        TextButton({ community.blockMember(room, member.userId) }, enabled = !community.busy) { Text("Block") }
    }
}

// MARK: Challenge moderation

/** Moderator lifecycle tools. The server requires current moderation permission with MFA and refuses
 * every other account; this screen assumes no role and shows only what the server confirms. */
@Composable internal fun ChallengeModeratorTools(community: CommunityViewModel, challenges: List<ChallengeSummary>) {
    var open by remember { mutableStateOf(false) }
    TextButton({ open = !open }) { Text(if (open) "Hide moderator tools" else "Moderator tools") }
    if (!open) return
    Text("Only accounts with current moderation permission and MFA can use these. The server refuses everyone else; nothing here is assumed on this device. Every action is audited server-side.",
        style = MaterialTheme.typography.bodySmall)
    if (community.moderation.isNotEmpty()) Text(community.moderation)
    var title by remember { mutableStateOf("") }
    var brief by remember { mutableStateOf("") }
    var reward by remember { mutableStateOf("") }
    Text("New draft challenge", style = MaterialTheme.typography.titleSmall)
    OutlinedTextField(title, { title = it.take(100) }, label = { Text("Title") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(brief, { brief = it.take(2000) }, label = { Text("Brief") }, maxLines = 4, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(reward, { reward = it.take(500) }, label = { Text("Reward text (descriptive only; no money or coins)") }, maxLines = 2, modifier = Modifier.fillMaxWidth())
    Button({ community.createChallenge(title, brief, reward); title = ""; brief = ""; reward = "" }, enabled = title.isNotBlank() && !community.busy) { Text("Create draft") }
    challenges.forEach { challenge -> ModerateChallenge(community, challenge) }
}

@Composable private fun ModerateChallenge(community: CommunityViewModel, challenge: ChallengeSummary) {
    Text("${challenge.title.ifBlank { "Untitled challenge" }} · revision ${challenge.revision}", style = MaterialTheme.typography.titleSmall)
    val format = "yyyy-MM-dd HH:mm"
    var starts by remember(challenge.id) { mutableStateOf("") }
    var closes by remember(challenge.id) { mutableStateOf("") }
    var ends by remember(challenge.id) { mutableStateOf("") }
    OutlinedTextField(starts, { starts = it.take(16) }, label = { Text("Submissions open ($format, this device's time)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(closes, { closes = it.take(16) }, label = { Text("Submissions close ($format)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(ends, { ends = it.take(16) }, label = { Text("Voting ends ($format)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    val draft = listOf(starts, closes, ends).map { localInstant(it) }.takeIf { it.all { value -> value != null } }?.let { ChallengeScheduleDraft(it[0]!!, it[1]!!, it[2]!!) }
    val problem = draft?.validation(Instant.now()) ?: if (listOf(starts, closes, ends).any { it.isNotBlank() } && draft == null) "Use $format for all three times." else null
    problem?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    Button({ draft?.let { community.scheduleChallenge(challenge, it) } }, enabled = draft != null && problem == null && !community.busy) { Text("Schedule") }
    var reason by remember(challenge.id) { mutableStateOf("") }
    OutlinedTextField(reason, { reason = it.take(2000) }, label = { Text("Reason (required to cancel or remove an entry)") }, maxLines = 3, modifier = Modifier.fillMaxWidth())
    TextButton({ community.cancelChallenge(challenge, reason) }, enabled = reason.isNotBlank() && !community.busy) { Text("Cancel challenge") }
    community.entries[challenge.id]?.let { load ->
        LoadState(load, "") { result ->
            result.entries.forEach { entry ->
                TextButton({ community.removeEntry(challenge, entry.id, reason) }, enabled = reason.isNotBlank() && !community.busy) {
                    Text("Remove entry \"${entry.title.ifBlank { "Untitled" }}\"")
                }
            }
        }
    } ?: TextButton({ community.loadEntries(challenge.id) }) { Text("Load entries to moderate") }
}

private fun localInstant(text: String): Instant? = runCatching {
    LocalDateTime.parse(text.trim().replace(' ', 'T')).atZone(ZoneId.systemDefault()).toInstant()
}.getOrNull()

// MARK: Calendar

/** Read-only month of challenge milestones and the member's own War Room voting deadlines. */
@Composable internal fun CalendarSection(community: CommunityViewModel) {
    val month = community.calendarMonth
    Text("Calendar", style = MaterialTheme.typography.titleMedium)
    Text("Challenge milestones and your own War Room voting deadlines, from the server, in this device's time zone. Read only; nothing is kept offline on Android, so without a connection the calendar says so.")
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton({ community.loadCalendar(month.minusMonths(1)) }) { Text("Previous") }
        Text(month.format(DateTimeFormatter.ofPattern("MMMM yyyy")))
        TextButton({ community.loadCalendar(month.plusMonths(1)) }) { Text("Next") }
        TextButton({ community.loadCalendar(month) }) { Text("Refresh") }
    }
    LoadState(community.calendar, "Load the month to see scheduled milestones.") { result ->
        if (result.truncated) Text("This month has more milestones than one reply carries; the earliest are shown.", style = MaterialTheme.typography.bodySmall)
        val days = result.days()
        if (days.isEmpty()) Text("Nothing is scheduled this month.")
        val dayFormat = DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL)
        val timeFormat = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        days.forEach { (day, items) ->
            Text(day.format(dayFormat), style = MaterialTheme.typography.titleSmall)
            items.forEach { item ->
                Text("${item.occursAt.atZone(result.start.zone).format(timeFormat)} · ${item.kindText}: ${item.title.ifBlank { "Untitled" }} — ${item.milestoneText}${item.status.takeIf { it.isNotBlank() }?.let { " ($it)" } ?: ""}")
            }
        }
    }
}

private fun shortTime(raw: String): String = serverInstant(raw)?.atZone(ZoneId.systemDefault())
    ?.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT)) ?: raw
