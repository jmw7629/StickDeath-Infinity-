package com.stickdeath.studio.connect

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

/** Account section of the Account panel: honest connection state, sign-in, the video wall, the
 * member's own records and joining a room by invitation code. No messaging or calls exist here. */
@Composable fun ConnectedAccountSection(account: AccountViewModel = viewModel()) {
    val context = LocalContext.current
    val state = account.state
    Text(state.summary)
    if (account.notice.isNotEmpty()) Text(account.notice)
    if (!account.configured) {
        Text("The owner supplies the public project address and publishable key at build time (docs/ANDROID_DELIVERY.md). Until then nothing is sent and no account data leaves this device.")
        return
    }
    when (state) {
        is AccountState.RetryableFailure -> Button({ account.retryRestore() }, enabled = !account.working) { Text("Retry") }
        is AccountState.SignedIn -> {
            TextButton({ account.signOut() }, enabled = !account.working) { Text("Sign out") }
            if (account.needsNewPassword) NewPasswordForm(account) else CommunitySection(account)
        }
        is AccountState.Restoring -> Unit
        else -> SignInForm(account) { provider -> account.beginOAuth(provider)?.let { url ->
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
                .onFailure { account.browserUnavailable() }
        } }
    }
}

@Composable private fun NewPasswordForm(account: AccountViewModel) {
    var password by remember { mutableStateOf("") }
    OutlinedTextField(password, { password = it.take(128) }, label = { Text("New password") }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
    Button({ account.updatePassword(password); password = "" }, enabled = !account.working && password.length >= 8) { Text("Set new password") }
}

@Composable private fun SignInForm(account: AccountViewModel, startProvider: (OAuthProvider) -> Unit) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }
    OutlinedTextField(email, { email = it.take(254) }, label = { Text("Email") }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), modifier = Modifier.fillMaxWidth())
    OutlinedTextField(password, { password = it.take(128) }, label = { Text("Password") }, singleLine = true,
        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
    if (creating) OutlinedTextField(username, { username = it.take(40) }, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    Row {
        if (creating) Button({ account.signUp(email, password, username); password = "" }, enabled = !account.working) { Text("Create account") }
        else Button({ account.signIn(email, password); password = "" }, enabled = !account.working) { Text("Sign in") }
        TextButton({ creating = !creating }) { Text(if (creating) "I have an account" else "Create an account") }
    }
    if (!creating) TextButton({ account.requestPasswordReset(email) }, enabled = !account.working) { Text("Forgot password? Email a reset link") }
    TextButton({ account.signInAsGuest() }, enabled = !account.working) { Text("Continue as guest") }
    val providers = account.providers
    if (providers.isEmpty()) Text("Apple, Google, GitHub and Microsoft sign-in are not configured for this build.")
    else Row(Modifier.horizontalScroll(rememberScrollState())) {
        OAuthProvider.entries.filter { it in providers }.forEach { provider ->
            TextButton({ startProvider(provider) }, enabled = !account.working) { Text("Continue with ${provider.title}") }
        }
    }
}

@Composable private fun CommunitySection(account: AccountViewModel) {
    val context = LocalContext.current
    Text("Video wall", style = MaterialTheme.typography.titleMedium)
    Row(Modifier.horizontalScroll(rememberScrollState())) {
        FeedCategory.entries.forEach { category ->
            FilterChip(account.feedCategory == category && account.feed !is Load.Idle, { account.loadFeed(category) }, { Text(category.title) }, modifier = Modifier.padding(end = 4.dp))
        }
    }
    Text(account.feedCategory.explanation)
    when (val feed = account.feed) {
        Load.Idle -> Text("Choose a category to load approved videos.")
        Load.Loading -> Text("Loading…")
        is Load.Failed -> Text(feed.message)
        is Load.Loaded -> {
            if (feed.value.posts.isEmpty()) Text("No approved videos here yet.")
            feed.value.posts.forEach { post ->
                Text("${post.title.ifBlank { "Untitled" }} — ${post.creatorName}")
                if (post.caption.isNotBlank()) Text(post.caption, style = MaterialTheme.typography.bodySmall)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton({ account.toggleLike(post) }, enabled = account.signedInMember) { Text(if (post.liked) "Liked · ${post.likes}" else "Like · ${post.likes}") }
                    post.safeUrl?.let { url -> TextButton({ runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } }) { Text("Watch") } }
                    TextButton({ account.report(post, FeedReportReason.Abuse) }, enabled = account.signedInMember) { Text("Report") }
                }
            }
            if (feed.value.hasMore) TextButton({ account.loadMoreFeed() }) { Text("Load more") }
        }
    }
    Text("Records and badges", style = MaterialTheme.typography.titleMedium)
    when (val records = account.records) {
        Load.Idle -> TextButton({ account.loadRecords() }, enabled = account.signedInMember) { Text("Load my records") }
        Load.Loading -> Text("Loading…")
        is Load.Failed -> Text(records.message)
        is Load.Loaded -> {
            val r = records.value
            Text("Wins ${r.wins} · Losses ${r.losses} · Ties ${r.ties}. Public display: records ${if (r.showRecords == true) "shown" else "hidden"}, badges ${if (r.showBadges == true) "shown" else "hidden"}.")
            Text("Earned badges: ${r.badges?.size ?: 0}")
        }
    }
    Text("Join a room", style = MaterialTheme.typography.titleMedium)
    Text("Rooms share one explicitly chosen Studio project. Paste an invitation code; the owner approves every request. There is no chat or calling.")
    var code by remember { mutableStateOf("") }
    var consent by remember { mutableStateOf(false) }
    OutlinedTextField(code, { code = it.take(80) }, label = { Text("Invitation code") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    TextButton({ account.previewInvitation(code) }, enabled = account.signedInMember && RoomInvitationPolicy.isWellFormed(code)) { Text("Review invitation") }
    when (val preview = account.invitation) {
        is Load.Loaded -> {
            Text("Room: ${preview.value.title}")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(consent, { consent = it })
                Text("I accept this invitation and ask the owner to admit me.")
            }
            Button({ account.requestAdmission(code, consent) }, enabled = consent) { Text("Request to join") }
        }
        is Load.Failed -> Text(preview.message)
        Load.Loading -> Text("Checking…")
        Load.Idle -> Unit
    }
    if (!account.signedInMember) Text("Guests can browse the wall; likes, reports, records and rooms need a full account.")
    Text("Contests, rooms and account", style = MaterialTheme.typography.titleMedium)
    CommunityFeaturesSection(account)
}

/** Cloud guidance for the Spatter panel. Replies are text only and never edit the project. */
@Composable fun SpatterCloudSection(account: AccountViewModel = viewModel()) {
    Text("Spatter cloud", style = MaterialTheme.typography.titleMedium)
    if (!account.configured || !account.spatterConfigured) { Text(SpatterException.NotConfigured().message!!); return }
    if (account.state !is AccountState.SignedIn) { Text(SpatterException.NotAuthenticated().message!!); return }
    var question by remember { mutableStateOf("") }
    val usage = (account.spatterUsage as? Load.Loaded)?.value
    Text(com.stickdeath.studio.billing.PlanCopy.usage(usage), style = MaterialTheme.typography.bodySmall)
    if (account.spatterUsage is Load.Failed) TextButton({ account.refreshSpatterUsage() }) { Text("Check my Spatter plan again") }
    val gate = account.spatterGate
    if (gate is com.stickdeath.studio.billing.SpatterGate.Send && gate.payAsYouGo) Text("Pay as you go: the server spends 1 Spatter credit per prompt.", style = MaterialTheme.typography.bodySmall)
    OutlinedTextField(question, { question = it.take(4000) }, label = { Text("Ask Spatter for guidance") }, maxLines = 4, modifier = Modifier.fillMaxWidth())
    Button({ account.askSpatter(question) }, enabled = question.isNotBlank() && account.spatterReply !is Load.Loading) { Text("Ask") }
    Text("Suggested prompts", style = MaterialTheme.typography.bodySmall)
    SUGGESTED_PROMPTS.forEach { prompt -> TextButton({ question = prompt; account.askSpatter(prompt) }, enabled = account.spatterReply !is Load.Loading) { Text(prompt) } }
    when (val reply = account.spatterReply) {
        is Load.Loaded -> {
            Text(reply.value.reply)
            reply.value.budget?.let { Text("Remaining today: ${it.remaining}", style = MaterialTheme.typography.bodySmall) }
        }
        is Load.Failed -> Text(reply.message)
        Load.Loading -> Text("Waiting for Spatter…")
        Load.Idle -> Unit
    }
}

/** Suggested prompts stay visible on every plan; on Free without credits they answer with the upgrade note. */
private val SUGGESTED_PROMPTS = listOf(
    "How do I time a punch so it lands hard?",
    "Give me a 12-frame walk cycle plan for a stick figure.",
    "How should I use onion skin to smooth a jump?",
)
