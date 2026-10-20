package com.stickdeath.studio.connect

import android.app.Application
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.stickdeath.studio.BuildConfig
import com.stickdeath.studio.billing.PlanCopy
import com.stickdeath.studio.billing.PlanRuntime
import com.stickdeath.studio.billing.SpatterGate
import com.stickdeath.studio.billing.SpatterUsage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One SessionManager per process, so an OAuth callback that recreates the activity still finds
 * the in-memory PKCE verifier. Configuration comes only from Gradle-supplied public values. */
object AccountRuntime {
    @Volatile private var manager: SessionManager? = null
    fun config(): BackendConfig? = BackendConfig.from(BuildConfig.SDI_SUPABASE_URL, BuildConfig.SDI_SUPABASE_PUBLISHABLE_KEY,
        BuildConfig.SDI_SPATTER_BACKEND_URL, BuildConfig.SDI_OAUTH_PROVIDERS, BuildConfig.SDI_NETWORK_DECLARED)
    fun manager(context: Context): SessionManager = manager ?: synchronized(this) {
        manager ?: SessionManager(config(), KeystoreSessionVault(context.applicationContext), UrlConnectionTransport()).also { manager = it }
    }
}

sealed class Load<out T> {
    object Idle : Load<Nothing>()
    object Loading : Load<Nothing>()
    data class Loaded<T>(val value: T) : Load<T>()
    data class Failed(val message: String) : Load<Nothing>()
}

/** Account, feed, profile, Rooms-join and Spatter cloud state for the Account and Spatter panels.
 * Every reply is checked against the account generation it was requested for. */
class AccountViewModel(application: Application) : AndroidViewModel(application) {
    private val manager = AccountRuntime.manager(application)
    private val gateway = CommunityGateway(manager.asSessionSource(), UrlConnectionTransport())
    private val feedClient = FeedClient(gateway)
    private val profileClient = ProfileClient(gateway)
    private val roomsClient = RoomsClient(gateway)
    private val usageClient = SpatterUsageClient(gateway)
    private val spatter = SpatterClient(manager.config?.spatterEndpoint, manager.asSessionSource(), UrlConnectionTransport())

    var state by mutableStateOf(manager.state); private set
    var working by mutableStateOf(false); private set
    var notice by mutableStateOf(""); private set
    var feed by mutableStateOf<Load<FeedPage>>(Load.Idle); private set
    var feedCategory by mutableStateOf(FeedCategory.Recent); private set
    var records by mutableStateOf<Load<ProfileRecords>>(Load.Idle); private set
    var invitation by mutableStateOf<Load<InvitationPreview>>(Load.Idle); private set
    var spatterReply by mutableStateOf<Load<SpatterReply>>(Load.Idle); private set
    /** Server-reported plan, allowance and credits; the device never counts prompts itself. */
    var spatterUsage by mutableStateOf<Load<SpatterUsage>>(Load.Idle); private set

    val configured get() = manager.isConfigured
    val providers get() = manager.providers()
    val spatterConfigured get() = manager.config?.spatterEndpoint != null
    val signedInMember get() = (state as? AccountState.SignedIn)?.isAnonymous == false

    init { if (manager.isConfigured && state is AccountState.SignedOut) perform("Restoring your session…") { manager.restore() } }

    private fun perform(progress: String, block: () -> Any?) {
        if (working) return
        working = true; notice = progress
        viewModelScope.launch {
            val failure = withContext(Dispatchers.IO) { runCatching { block() }.exceptionOrNull() }
            working = false
            state = manager.state
            notice = when (failure) { null -> ""; is CancellationException -> ""; else -> failure.message ?: "That did not complete." }
            if (state !is AccountState.SignedIn) { feed = Load.Idle; records = Load.Idle; invitation = Load.Idle; spatterReply = Load.Idle; spatterUsage = Load.Idle; PlanRuntime.reportServerPlan(null) }
            else if (spatterUsage is Load.Idle) refreshSpatterUsage()
        }
    }
    /** Runs a member request; a reply for an earlier account is dropped as stale. */
    private fun <T> fetch(set: (Load<T>) -> Unit, block: () -> T) {
        val generation = manager.generation
        set(Load.Loading)
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching(block) }
            if (generation != manager.generation) { set(Load.Failed(CommunityException.Stale().message!!)); return@launch }
            set(result.fold({ Load.Loaded(it) }, { Load.Failed(it.message ?: "That did not complete.") }))
            state = manager.state
        }
    }

    fun retryRestore() = perform("Restoring your session…") { manager.restore() }
    fun signIn(email: String, password: String) = perform("Signing in…") { manager.signIn(email, password) }
    fun signUp(email: String, password: String, username: String) = perform("Creating your account…") {
        if (!manager.signUp(email, password, username)) throw IllegalStateException("Check your email to confirm the account, then sign in.")
    }
    fun signInAsGuest() = perform("Starting a guest session…") { manager.signInAsGuest() }
    fun signOut() = perform("Signing out…") { manager.signOut() }
    /** The hosted authorize URL for the browser, or null with a notice when unavailable. */
    fun beginOAuth(provider: OAuthProvider): String? = runCatching { manager.beginOAuth(provider) }
        .onFailure { notice = it.message ?: "Sign-in could not start." }.getOrNull()
    fun completeOAuth(callback: String) = perform("Finishing sign-in…") { manager.completeOAuth(callback) }
    fun browserUnavailable() { manager.cancelOAuth(); notice = "No browser is available to complete sign-in. Nothing was sent." }

    fun loadFeed(category: FeedCategory = feedCategory) { feedCategory = category; fetch({ feed = it }) { feedClient.page(category) } }
    /** Next keyset page under page 0's snapshot; stops at the client memory bound (refresh restarts). */
    fun loadMoreFeed() {
        val current = (feed as? Load.Loaded)?.value ?: return
        val cursor = current.cursor
        if (!current.hasMore || cursor == null) return
        fetch<FeedPage>({ next ->
            feed = if (next is Load.Loaded) {
                val merged = (current.posts + next.value.posts).distinctBy { it.id }
                Load.Loaded(FeedPage(merged, next.value.hasMore && merged.size < FeedClient.MAXIMUM_RETAINED_POSTS, current.asOf, next.value.cursor))
            } else next
        }) { feedClient.page(feedCategory, cursor, current.asOf) }
    }
    /** Optimistic ±1 on the tapped card only, rolled back unless the server confirms. */
    fun toggleLike(post: FeedPost) {
        val page = (feed as? Load.Loaded)?.value ?: return
        val optimistic = post.copy(liked = !post.liked, likes = (post.likes + if (post.liked) -1 else 1).coerceAtLeast(0))
        feed = Load.Loaded(page.copy(posts = page.posts.map { if (it.id == post.id) optimistic else it }))
        val generation = manager.generation
        viewModelScope.launch {
            val confirmed = withContext(Dispatchers.IO) { runCatching { feedClient.like(post.id, optimistic.liked) } }
            if (generation != manager.generation) return@launch
            if (confirmed.getOrDefault(false) != true) {
                val latest = (feed as? Load.Loaded)?.value ?: return@launch
                feed = Load.Loaded(latest.copy(posts = latest.posts.map { if (it.id == post.id) post else it }))
                notice = confirmed.exceptionOrNull()?.message ?: "The like was not confirmed and was undone."
            }
        }
    }
    fun report(post: FeedPost, reason: FeedReportReason) {
        viewModelScope.launch {
            val ok = withContext(Dispatchers.IO) { runCatching { feedClient.report(post.id, reason) } }
            notice = ok.fold({ if (it) "Report recorded for moderator review." else "The report was not confirmed." }, { it.message ?: "The report could not be sent." })
        }
    }
    fun loadRecords() = fetch({ records = it }) { profileClient.readRecords() }
    fun previewInvitation(code: String) = fetch({ invitation = it }) { roomsClient.previewInvitation(code) }
    fun requestAdmission(code: String, consent: Boolean) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { roomsClient.requestAdmission(code, consent) } }
            notice = result.fold({ when (it) {
                is AdmissionOutcome.PendingOwnerApproval -> "Request sent. The room owner must approve it before you can open the shared project."
                is AdmissionOutcome.AlreadyRequested -> "You already asked to join this room; the owner has not decided yet."
            } }, { it.message ?: "The request could not be sent." })
        }
    }
    /** Reads `sdi_spatter_my_usage` and feeds the server plan to the Studio limits. */
    fun refreshSpatterUsage() {
        if (state !is AccountState.SignedIn || spatterUsage is Load.Loading) return
        fetch<SpatterUsage>({ result ->
            spatterUsage = result
            if (result is Load.Loaded) PlanRuntime.reportServerPlan(result.value.plan)
        }) { usageClient.myUsage() }
    }
    /** What a Spatter send does now (Free without credits gets the upgrade note on the device). */
    val spatterGate: SpatterGate get() = SpatterGate.decide(PlanRuntime.limits, (spatterUsage as? Load.Loaded)?.value, spatterUsage is Load.Loading)

    fun askSpatter(question: String) {
        when (spatterGate) {
            SpatterGate.UpgradeNote -> { spatterReply = Load.Failed(PlanCopy.SPATTER_UPGRADE_NOTE); return }
            SpatterGate.AllowanceUsed -> { spatterReply = Load.Failed(PlanCopy.SPATTER_ALLOWANCE_USED); return }
            SpatterGate.Checking -> { spatterReply = Load.Failed(PlanCopy.SPATTER_CHECKING); refreshSpatterUsage(); return }
            is SpatterGate.Send -> Unit
        }
        val generation = manager.generation
        spatterReply = Load.Loading
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                spatter.complete(listOf(
                    SpatterMessage(SpatterMessage.Role.System, SPATTER_SYSTEM),
                    SpatterMessage(SpatterMessage.Role.User, question.trim().take(4000))))
            } }
            if (generation != manager.generation) { spatterReply = Load.Failed(CommunityException.Stale().message!!); return@launch }
            spatterReply = result.fold({ Load.Loaded(it) }, { Load.Failed(it.message ?: "That did not complete.") })
            state = manager.state
            // The server counted (or refused) the prompt; show its new allowance and credit balance.
            if (state is AccountState.SignedIn) { spatterUsage = Load.Idle; refreshSpatterUsage() }
        }
    }

    private companion object {
        /** Guidance only: Android never applies a cloud reply to the project without the local grammar. */
        const val SPATTER_SYSTEM = "You are Spatter, the StickDeath Infinity Studio assistant on Android. Give concise, practical stick-animation guidance. " +
            "You cannot edit the project directly; suggest instructions the user can run with the local Spatter grammar. There is no messaging or calling in this app."
    }
}
