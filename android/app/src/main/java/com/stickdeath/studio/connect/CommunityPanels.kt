package com.stickdeath.studio.connect

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import java.time.Instant

private enum class CommunityTab(val title: String) { War("War Room"), Challenges("Challenges"), Rooms("Shared rooms"), Calendar("Calendar"), Inbox("Notifications"), Data("Account data") }

/** War Room, challenges, shared-room sync, notifications and account data for a signed-in member.
 * There is no chat, calling, camera or microphone anywhere in these screens. */
@Composable fun CommunityFeaturesSection(account: AccountViewModel, community: CommunityViewModel = viewModel()) {
    val signedIn = account.state as? AccountState.SignedIn
    LaunchedEffect(signedIn?.userId) { community.accountChanged(signedIn?.userId) }
    var tab by remember { mutableStateOf<CommunityTab?>(null) }
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        CommunityTab.entries.forEach { entry ->
            FilterChip(tab == entry, { tab = if (tab == entry) null else entry }, { Text(entry.title) }, modifier = Modifier.padding(end = 4.dp))
        }
    }
    if (community.notice.isNotEmpty()) Text(community.notice)
    if (tab != null && !account.signedInMember) { Text("War Room, challenges, rooms, notifications and account data need a full account. Guests can browse the wall only."); return }
    when (tab) {
        CommunityTab.War -> WarRoomSection(community)
        CommunityTab.Challenges -> ChallengesSection(community)
        CommunityTab.Rooms -> RoomSyncSection(community)
        CommunityTab.Calendar -> CalendarSection(community)
        CommunityTab.Inbox -> NotificationsSection(community)
        CommunityTab.Data -> AccountDataSection(community)
        null -> Unit
    }
}

@Composable internal fun <T> LoadState(load: Load<T>, idle: String, content: @Composable (T) -> Unit) {
    when (load) {
        Load.Idle -> Text(idle)
        Load.Loading -> Text("Loading…")
        is Load.Failed -> Text(load.message)
        is Load.Loaded -> content(load.value)
    }
}

@Composable private fun Watch(label: String, url: String?) {
    val context = LocalContext.current
    if (url != null) TextButton({ runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } }) { Text(label) }
}

@Composable private fun WarRoomSection(community: CommunityViewModel) {
    Text("War Room", style = MaterialTheme.typography.titleMedium)
    Text("Two creators each submit an approved rendered video and viewers pick their favourite. Votes are tied to your signed-in account, one per matchup, and can be changed until voting closes. The server alone records results.")
    Row {
        TextButton({ community.loadMatches() }) { Text("Load matchups") }
        TextButton({ community.loadWarNotices() }) { Text("Moderation notices") }
    }
    val now = Instant.now()
    LoadState(community.matches, "Load matchups to see active contests.") { matches ->
        if (matches.isEmpty()) Text("No matchups are open right now.")
        matches.forEach { match ->
            val view = WarMatchPresentation.of(match, community.viewer, now)
            val machine = community.votes[match.id] ?: WarVoteMachine.fromServer(match.myVote)
            Text(view.heading, style = MaterialTheme.typography.titleSmall)
            Text("${match.leftTitle.ifBlank { "First video" }} vs ${match.rightTitle ?: "awaiting the second video"}")
            Row {
                Watch("Watch first", match.leftSafeUrl)
                Watch("Watch second", match.rightSafeUrl)
            }
            if (view.showsTallies) Text("Server tally: ${match.leftVotes} – ${match.rightVotes}", style = MaterialTheme.typography.bodySmall)
            view.resultText?.let { Text(it) }
            if (view.canVote) Row(verticalAlignment = Alignment.CenterVertically) {
                WarVoteChoice.entries.forEach { choice ->
                    val label = if (choice == WarVoteChoice.Left) "First" else "Second"
                    val pending = (machine.state as? WarVoteMachine.State.Pending)?.choice == choice
                    FilterChip(machine.serverChoice == choice, { community.vote(match, choice) },
                        { Text(if (pending) "$label (sending…)" else "Favourite: $label") }, enabled = !machine.isPending, modifier = Modifier.padding(end = 4.dp))
                }
            }
            (machine.state as? WarVoteMachine.State.Failed)?.let { Text(it.message, style = MaterialTheme.typography.bodySmall) }
            if (view.canAccept) AcceptMatch(community, match.id)
            Row {
                if (view.canWithdraw) TextButton({ community.withdraw(match.id) }, enabled = !community.busy) { Text("Withdraw") }
                if (!view.isParticipant) ReportMatch(community, match.id)
            }
        }
    }
    LoadState(community.warNotices, "") { notices ->
        if (notices.isEmpty()) Text("No moderation notices.")
        notices.forEach { notice ->
            Text(notice.message)
            Text("Appeal: ${notice.appealState ?: "available until ${notice.appealDeadline}"}", style = MaterialTheme.typography.bodySmall)
            if (notice.appealState == null) AppealNotice(community, notice.id)
        }
    }
    ProposeMatch(community)
}

@Composable private fun MediaPicker(community: CommunityViewModel, selected: String?, onSelect: (String) -> Unit) {
    when (val media = community.myMedia) {
        Load.Idle -> TextButton({ community.loadMyMedia() }) { Text("Choose from my approved videos") }
        Load.Loading -> Text("Loading your approved videos…")
        is Load.Failed -> Text(media.message)
        is Load.Loaded -> if (media.value.isEmpty()) Text("You have no approved rendered videos yet. Submit a render for review first.")
            else Row(Modifier.horizontalScroll(rememberScrollState())) {
                media.value.forEach { item -> FilterChip(selected == item.id, { onSelect(item.id) }, { Text(item.title.ifBlank { "Untitled" }) }, modifier = Modifier.padding(end = 4.dp)) }
            }
    }
}

@Composable private fun AcceptMatch(community: CommunityViewModel, match: String) {
    var media by remember { mutableStateOf<String?>(null) }
    var agreed by remember { mutableStateOf(false) }
    MediaPicker(community, media) { media = it }
    Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(agreed, { agreed = it }); Text("I agree to the matchup rules: my approved video is shown beside theirs for 24 hours of public voting.") }
    Button({ media?.let { community.accept(match, it, agreed) } }, enabled = media != null && agreed && !community.busy) { Text("Accept matchup") }
}

@Composable private fun ProposeMatch(community: CommunityViewModel) {
    var open by remember { mutableStateOf(false) }
    TextButton({ open = !open }) { Text(if (open) "Close proposal" else "Propose a matchup") }
    if (!open) return
    var media by remember { mutableStateOf<String?>(null) }
    var opponent by remember { mutableStateOf("") }
    var agreed by remember { mutableStateOf(false) }
    MediaPicker(community, media) { media = it }
    OutlinedTextField(opponent, { opponent = it.take(36) }, label = { Text("Opponent creator ID") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    Text("The other creator must accept with their own approved video before anything is shown publicly.", style = MaterialTheme.typography.bodySmall)
    Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(agreed, { agreed = it }); Text("I agree to the matchup rules.") }
    val valid = media != null && agreed && UUID_PATTERN.matches(opponent.trim())
    Button({ community.propose(media!!, opponent, agreed) }, enabled = valid && !community.busy) { Text("Send proposal") }
}

@Composable private fun ReportMatch(community: CommunityViewModel, match: String) {
    var open by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf("") }
    TextButton({ open = !open }) { Text("Report") }
    if (!open) return
    OutlinedTextField(reason, { reason = it.take(2000) }, label = { Text("What is wrong?") }, maxLines = 4, modifier = Modifier.fillMaxWidth())
    Button({ community.reportMatch(match, reason); open = false; reason = "" }, enabled = reason.isNotBlank() && !community.busy) { Text("Send report") }
}

@Composable private fun AppealNotice(community: CommunityViewModel, decision: String) {
    var text by remember { mutableStateOf("") }
    OutlinedTextField(text, { text = it.take(2000) }, label = { Text("Explain your appeal") }, maxLines = 4, modifier = Modifier.fillMaxWidth())
    Button({ community.appeal(decision, text); text = "" }, enabled = text.isNotBlank() && !community.busy) { Text("Send appeal") }
}

@Composable private fun ChallengesSection(community: CommunityViewModel) {
    Text("Challenges", style = MaterialTheme.typography.titleMedium)
    Text("Scheduled community challenges. Submit one approved rendered video while submissions are open; non-participants pick one favourite during voting. Reward text is descriptive only.")
    TextButton({ community.loadChallenges() }) { Text("Load challenges") }
    LoadState(community.challenges, "Load challenges to see what is open.") { listing ->
        ChallengeModeratorTools(community, listing.challenges)
        if (listing.challenges.isEmpty()) Text("No challenges are scheduled right now.")
        val serverNow = listing.clock.now(System.currentTimeMillis())
        listing.challenges.forEach { challenge ->
            val phase = challenge.phaseAt(serverNow)
            Text("${challenge.title.ifBlank { "Untitled challenge" }} · ${phase.title}", style = MaterialTheme.typography.titleSmall)
            if (challenge.brief.isNotBlank()) Text(challenge.brief, style = MaterialTheme.typography.bodySmall)
            if (challenge.hasReward) Text("Reward: ${challenge.rewardText}", style = MaterialTheme.typography.bodySmall)
            Text("Entries: ${challenge.entryCount}${if (challenge.myEntry) " · you entered" else ""}", style = MaterialTheme.typography.bodySmall)
            challenge.outcomeText?.let { Text(it) }
            TextButton({ community.loadEntries(challenge.id) }) { Text("Show entries") }
            if (phase == ChallengePhase.Active && !challenge.myEntry) {
                var media by remember(challenge.id) { mutableStateOf<String?>(null) }
                MediaPicker(community, media) { media = it }
                Button({ media?.let { community.submitEntry(challenge.id, it) } }, enabled = media != null && !community.busy) { Text("Submit entry") }
            }
            community.entries[challenge.id]?.let { load ->
                LoadState(load, "") { result ->
                    if (result.entries.isEmpty()) Text("No eligible entries yet.")
                    result.entries.forEach { entry ->
                        val mine = entry.creator == community.viewer
                        Text("${entry.title.ifBlank { "Untitled" }}${if (mine) " (yours)" else ""}${entry.votes?.let { " · $it vote(s)" } ?: ""}")
                        Row {
                            Watch("Watch", entry.safeUrl)
                            if (result.phase == ChallengePhase.Voting && !mine && !challenge.myEntry)
                                TextButton({ community.voteEntry(challenge.id, entry.id) }, enabled = !community.busy) { Text(if (entry.myVote) "Your favourite" else "Pick as favourite") }
                            if (mine && result.phase != ChallengePhase.Completed)
                                TextButton({ community.withdrawEntry(challenge.id, entry.id) }, enabled = !community.busy) { Text("Withdraw my entry") }
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun NotificationsSection(community: CommunityViewModel) {
    Text("Notifications", style = MaterialTheme.typography.titleMedium)
    Text("Account and service notices are always on. Push delivery to Android is not configured, so nothing is pushed to this device; these server choices apply to in-app announcements and to delivery once the owner enables it.")
    TextButton({ community.loadNotificationPreferences() }) { Text("Load server preferences") }
    LoadState(community.notificationPreferences, "") { prefs ->
        var draft by remember(prefs) { mutableStateOf(prefs) }
        ToggleRow("Push: Studio and community", draft.pushProduct) { draft = draft.copy(pushProduct = it) }
        ToggleRow("Push: announcements and offers", draft.pushMarketing) { draft = draft.copy(pushMarketing = it) }
        ToggleRow("Email: Studio and community", draft.emailProduct) { draft = draft.copy(emailProduct = it) }
        ToggleRow("Email: announcements and offers", draft.emailMarketing) { draft = draft.copy(emailMarketing = it) }
        Text("Daily cap: ${draft.dailyCap} non-essential notice(s) per day")
        Slider(draft.dailyCap.toFloat(), { draft = draft.copy(dailyCap = it.toInt().coerceIn(0, 10)) }, valueRange = 0f..10f, steps = 9)
        Text("Registered push devices: ${prefs.registeredDevices}", style = MaterialTheme.typography.bodySmall)
        Button({ community.saveNotificationPreferences(draft) }, enabled = draft != prefs && !community.busy) { Text("Save preferences") }
    }
    Text("Announcements", style = MaterialTheme.typography.titleSmall)
    TextButton({ community.loadInbox() }) { Text("Load announcements") }
    LoadState(community.inbox, "") { inbox ->
        Text("${inbox.unread} unread")
        if (inbox.notices.isEmpty()) Text("No announcements.")
        inbox.notices.forEach { item ->
            Text(item.title, style = MaterialTheme.typography.titleSmall)
            Text(item.body)
            Text("${item.category} · ${item.deliveredAt}", style = MaterialTheme.typography.bodySmall)
            if (item.unread) TextButton({ community.markRead(item.delivery) }, enabled = !community.busy) { Text("Mark as read") }
        }
    }
}

@Composable private fun ToggleRow(label: String, value: Boolean, set: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) { Switch(value, set); Text(label, Modifier.padding(start = 8.dp)) }
}

@Composable private fun AccountDataSection(community: CommunityViewModel) {
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { community.saveExport(it) }
    LaunchedEffect(community.pendingExport) {
        if (community.pendingExport != null) runCatching { saver.launch(AccountLifecycleClient.exportFileName()) }.onFailure { community.saveExport(null) }
    }
    Text("Your account data", style = MaterialTheme.typography.titleMedium)
    Text("Projects and originals stay on this device and are never part of the export or deletion. The export contains the server records about your account (three per day).")
    Row {
        TextButton({ community.loadLifecycle() }) { Text("Check status") }
        TextButton({ community.prepareExport() }, enabled = !community.busy) { Text("Export my data") }
    }
    var understood by remember { mutableStateOf(false) }
    LoadState(community.lifecycle, "") { status ->
        if (status.note.isNotBlank()) Text(status.note, style = MaterialTheme.typography.bodySmall)
        status.exportsRemainingToday?.let { Text("Exports remaining today: $it", style = MaterialTheme.typography.bodySmall) }
        val deletion = status.deletion
        when {
            deletion == null || !deletion.isOpen -> {
                if (deletion?.state == AccountDeletionStatus.State.Cancelled) Text("Your last deletion request was cancelled.")
                Text("Delete account", style = MaterialTheme.typography.titleSmall)
                Text("Deletion is scheduled seven days after the request; sign in and cancel before then to keep the account. It does not cancel a store subscription: cancel that in Google Play or the billing portal.")
                Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(understood, { understood = it }); Text("I understand my server records will be removed after the cooling-off period.") }
                Button({ community.requestDeletion(understood) }, enabled = understood && !community.busy) { Text("Request deletion") }
            }
            else -> {
                Text("Deletion ${deletion.state.wire}${deletion.scheduledFor?.let { ", scheduled for $it" } ?: ""}.")
                if (deletion.state == AccountDeletionStatus.State.Blocked) Text("The request is on hold; support will contact you.")
                val revision = deletion.revision
                if (deletion.canCancel && revision != null) Button({ community.cancelDeletion(revision) }, enabled = !community.busy) { Text("Cancel deletion") }
                else if (deletion.state == AccountDeletionStatus.State.Pending) Text("Refresh the status to cancel this request.")
            }
        }
    }
}
