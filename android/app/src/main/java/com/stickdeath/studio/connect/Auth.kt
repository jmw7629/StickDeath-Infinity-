package com.stickdeath.studio.connect

import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** The persisted Supabase session. Tokens never appear in [toString]. */
data class StoredSession(
    val accessToken: String,
    val refreshToken: String,
    /** Epoch seconds at which the access token expires. */
    val expiresAt: Long,
    val userId: String,
    val email: String?,
    val isAnonymous: Boolean,
    val provider: String,
) {
    override fun toString() = "StoredSession(user=$userId, anonymous=$isAnonymous, provider=$provider, expiresAt=$expiresAt)"
}

/** Versioned JSON envelope for the encrypted vault. Unknown versions or damaged records read as null. */
object SessionCodec {
    private const val VERSION = 1
    fun encode(session: StoredSession): String = JSONObject()
        .put("v", VERSION).put("access_token", session.accessToken).put("refresh_token", session.refreshToken)
        .put("expires_at", session.expiresAt).put("user_id", session.userId).put("email", session.email ?: JSONObject.NULL)
        .put("is_anonymous", session.isAnonymous).put("provider", session.provider).toString()

    fun decode(raw: String?): StoredSession? = runCatching {
        val o = JSONObject(raw ?: return null)
        if (o.getInt("v") != VERSION) return null
        StoredSession(o.getString("access_token"), o.getString("refresh_token"), o.getLong("expires_at"),
            o.getString("user_id"), if (o.isNull("email")) null else o.getString("email"), o.getBoolean("is_anonymous"), o.getString("provider"))
            .takeIf { it.accessToken.isNotEmpty() && it.refreshToken.isNotEmpty() && it.userId.isNotEmpty() }
    }.getOrNull()
}

/** Where the session lives between launches. Android uses [KeystoreSessionVault]. */
interface SessionVault {
    fun read(): String?
    fun write(value: String)
    fun clear()
}
class InMemorySessionVault(private var value: String? = null) : SessionVault {
    override fun read() = value
    override fun write(value: String) { this.value = value }
    override fun clear() { value = null }
}

sealed class AuthException(message: String) : Exception(message) {
    class NotConfigured : AuthException("Account sign-in is not configured for this build. Nothing was sent.")
    class Busy : AuthException("Another sign-in step is still running.")
    class InvalidCredentials : AuthException("That email and password were not recognised, or the email is not confirmed yet.")
    class RateLimited : AuthException("Too many attempts. Wait a little and try again.")
    class Network : AuthException("The account service could not be reached. Check your connection and try again.")
    class Rejected(detail: String) : AuthException(detail)
    class ProviderUnavailable(provider: OAuthProvider) : AuthException("${provider.title} sign-in is not configured for this build.")
    class ProviderDenied(detail: String) : AuthException(detail)
    class InvalidCallback : AuthException("That sign-in link was not started here or has already been used. Start sign-in again.")
    class SessionEnded : AuthException("Your session ended. Sign in again.")
}

/** PKCE (RFC 7636, S256) helpers for the hosted OAuth flow. */
object Pkce {
    fun verifier(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(48).also(random::nextBytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }
    fun challenge(verifier: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
}

/** The app-owned redirect `stickdeath://auth/callback`, validated exactly like iOS AuthService. */
object OAuthCallback {
    const val REDIRECT = "stickdeath://auth/callback"
    private fun parts(raw: String): Pair<URI, List<Pair<String, String>>>? {
        val uri = runCatching { URI(raw) }.getOrNull() ?: return null
        if (uri.scheme != "stickdeath" || uri.host != "auth" || uri.path != "/callback") return null
        if (uri.rawUserInfo != null || uri.port != -1) return null
        val items = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.map {
            val name = it.substringBefore('=')
            val value = if (it.contains('=')) it.substringAfter('=') else ""
            URLDecoder.decode(name, "UTF-8") to URLDecoder.decode(value, "UTF-8")
        }
        return uri to items
    }

    /** A provider or server denial (`error=`) is reported and never exchanged, even beside a code. */
    fun denial(raw: String): String? {
        val (_, items) = parts(raw) ?: return null
        val code = items.firstOrNull { it.first == "error" }?.second?.takeIf { it.isNotEmpty() } ?: return null
        val description = items.firstOrNull { it.first == "error_description" }?.second.orEmpty()
            .filterNot { it.isISOControl() }.trim().take(240)
        return when {
            description.startsWith("AADSTS") -> "Microsoft declined this sign-in (${description.take(11)}). Check the tenant configuration and try again."
            description.isEmpty() && code == "access_denied" -> "The sign-in request was declined by the provider."
            description.isEmpty() -> "The provider declined this sign-in ($code)."
            else -> "The provider declined this sign-in: $description"
        }
    }

    /** Exactly one non-empty `code`; implicit-token fragments are never accepted. */
    fun code(raw: String): String? {
        val (uri, items) = parts(raw) ?: return null
        if (uri.rawFragment != null) return null
        val codes = items.filter { it.first == "code" }
        return codes.singleOrNull()?.second?.takeIf { it.isNotEmpty() && it.length <= 2048 }
    }
}

/** Supabase GoTrue over HTTPS with the publishable key only. Blocking; call from `Dispatchers.IO`. */
class GoTrueClient(private val config: BackendConfig, private val transport: HttpTransport, private val now: () -> Long) {
    private fun url(path: String, query: Map<String, String> = emptyMap()): String {
        val q = query.entries.joinToString("&") { "${enc(it.key)}=${enc(it.value)}" }
        return config.supabaseUrl + path + if (q.isEmpty()) "" else "?$q"
    }
    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")

    private fun post(path: String, query: Map<String, String>, body: JSONObject, bearer: String? = null): HttpResponse {
        val headers = mutableMapOf("apikey" to config.publishableKey, "Content-Type" to "application/json", "Accept" to "application/json")
        bearer?.let { headers["Authorization"] = "Bearer $it" }
        return try { transport.send(HttpRequest("POST", url(path, query), headers, body.toString().toByteArray(Charsets.UTF_8)), RESPONSE_LIMIT) }
        catch (e: IOException) { throw AuthException.Network() }
    }

    fun signInWithPassword(email: String, password: String): StoredSession =
        session(post("/auth/v1/token", mapOf("grant_type" to "password"), JSONObject().put("email", email.trim()).put("password", password)), "email")

    /** Returns null when the project requires email confirmation before a session exists. */
    fun signUp(email: String, password: String, username: String): StoredSession? {
        val response = post("/auth/v1/signup", emptyMap(), JSONObject().put("email", email.trim()).put("password", password)
            .put("data", JSONObject().put("username", username).put("source", "android")))
        check(response)
        val body = runCatching { JSONObject(response.text) }.getOrNull() ?: throw AuthException.Rejected("The account service returned an unreadable reply.")
        return if (body.has("access_token")) parse(body, "email") else null
    }

    /** Anonymous (guest) session; the server still refuses guests for creator-only actions. */
    fun signInAnonymously(): StoredSession = session(post("/auth/v1/signup", emptyMap(), JSONObject().put("data", JSONObject())), "anonymous")

    fun refresh(refreshToken: String, provider: String): StoredSession =
        session(post("/auth/v1/token", mapOf("grant_type" to "refresh_token"), JSONObject().put("refresh_token", refreshToken)), provider)

    fun authorizeUrl(provider: OAuthProvider, challenge: String): String = url("/auth/v1/authorize", linkedMapOf(
        "provider" to provider.wireName, "redirect_to" to OAuthCallback.REDIRECT, "scopes" to provider.scopes,
        "code_challenge" to challenge, "code_challenge_method" to "s256"))

    fun exchangeCode(code: String, verifier: String, provider: OAuthProvider): StoredSession =
        session(post("/auth/v1/token", mapOf("grant_type" to "pkce"), JSONObject().put("auth_code", code).put("code_verifier", verifier)), provider.wireName)

    /** Server-side revocation; local sign-out proceeds regardless of the outcome. */
    fun logout(accessToken: String) { runCatching { post("/auth/v1/logout", emptyMap(), JSONObject(), bearer = accessToken) } }

    private fun session(response: HttpResponse, provider: String): StoredSession {
        check(response)
        val body = runCatching { JSONObject(response.text) }.getOrNull() ?: throw AuthException.Rejected("The account service returned an unreadable reply.")
        return parse(body, provider)
    }

    private fun parse(body: JSONObject, provider: String): StoredSession {
        val access = body.optString("access_token"); val refresh = body.optString("refresh_token")
        val user = body.optJSONObject("user")
        val id = user?.optString("id").orEmpty()
        val expiresAt = if (body.has("expires_at")) body.optLong("expires_at") else now() + body.optLong("expires_in", 0)
        if (access.isEmpty() || refresh.isEmpty() || id.isEmpty() || expiresAt <= now()) {
            throw AuthException.Rejected("The account service returned an incomplete session.")
        }
        val anonymous = user?.optBoolean("is_anonymous", false) ?: false
        val email = user?.optString("email")?.takeIf { it.isNotEmpty() }
        return StoredSession(access, refresh, expiresAt, id, email, anonymous, if (anonymous) "anonymous" else provider)
    }

    private fun check(response: HttpResponse) {
        if (response.status in 200..299) return
        val body = runCatching { JSONObject(response.text) }.getOrNull()
        val code = body?.optString("error_code")?.takeIf { it.isNotEmpty() } ?: body?.optString("error").orEmpty()
        throw when {
            response.status == 429 -> AuthException.RateLimited()
            code in SESSION_ENDED_CODES -> AuthException.SessionEnded()
            code == "invalid_credentials" || code == "invalid_grant" || code == "email_not_confirmed" -> AuthException.InvalidCredentials()
            code == "anonymous_provider_disabled" -> AuthException.Rejected("Guest sign-in is not enabled for this project.")
            code == "signup_disabled" -> AuthException.Rejected("New accounts are not being accepted right now.")
            code == "weak_password" -> AuthException.Rejected("Choose a stronger password.")
            code == "user_already_exists" || code == "email_exists" -> AuthException.Rejected("An account already exists for that email. Sign in instead.")
            response.status >= 500 -> AuthException.Network()
            else -> AuthException.Rejected("The account service refused this request.")
        }
    }

    companion object {
        const val RESPONSE_LIMIT = 256 * 1024
        val SESSION_ENDED_CODES = setOf("refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired", "user_not_found")
    }
}

/** What the account surface can truthfully say. Only a server-issued session is ever [SignedIn]. */
sealed class AccountState {
    abstract val summary: String
    data class NotConfigured(val reason: String) : AccountState() { override val summary get() = "Not connected — $reason" }
    object Restoring : AccountState() { override val summary get() = "Restoring your session…" }
    object SignedOut : AccountState() { override val summary get() = "Signed out" }
    data class SignInRequired(val reason: String) : AccountState() { override val summary get() = reason }
    data class RetryableFailure(val reason: String) : AccountState() { override val summary get() = "$reason Your saved session was kept; retry when online." }
    data class SignedIn(val userId: String, val email: String?, val isAnonymous: Boolean, val provider: String) : AccountState() {
        override val summary get() = when {
            isAnonymous -> "Signed in as a guest. Guests can browse but cannot publish, vote or join rooms."
            email != null -> "Signed in as $email"
            else -> "Signed in"
        }
    }
}

/** Owns the one session: restore, sign-in, refresh, OAuth PKCE and sign-out. Thread-safe and blocking. */
class SessionManager(
    val config: BackendConfig?,
    private val vault: SessionVault,
    private val transport: HttpTransport,
    private val now: () -> Long = { System.currentTimeMillis() / 1000 },
    private val random: SecureRandom = SecureRandom(),
) {
    private val lock = Any()
    private var session: StoredSession? = null
    private var busy = false
    private var pending: Pair<OAuthProvider, String>? = null
    /** Increments on every identity change so replies for an earlier account can be discarded. */
    @Volatile var generation = 0L; private set
    @Volatile var state: AccountState = initialState(); private set

    private fun initialState(): AccountState = when {
        config == null -> AccountState.NotConfigured("this build has no validated account configuration, so sign-in, feed, Rooms, War Room and Spatter cloud assistance are unavailable.")
        !config.networkDeclared -> AccountState.NotConfigured("this build declares no network access.")
        else -> AccountState.SignedOut
    }
    private fun client(): GoTrueClient {
        val c = config ?: throw AuthException.NotConfigured()
        if (!c.networkDeclared) throw AuthException.NotConfigured()
        return GoTrueClient(c, transport, now)
    }

    val isConfigured get() = config != null && config.networkDeclared
    fun providers(): Set<OAuthProvider> = if (isConfigured) config!!.oauthProviders else emptySet()
    fun currentUserId(): String? = synchronized(lock) { session?.userId }

    private inline fun <T> exclusive(block: () -> T): T {
        synchronized(lock) { if (busy) throw AuthException.Busy(); busy = true }
        try { return block() } finally { synchronized(lock) { busy = false } }
    }
    private fun adopt(next: StoredSession?) = synchronized(lock) {
        if (next?.userId != session?.userId) generation++
        session = next
        if (next == null) vault.clear() else vault.write(SessionCodec.encode(next))
        state = next?.let { AccountState.SignedIn(it.userId, it.email, it.isAnonymous, it.provider) } ?: AccountState.SignedOut
    }

    /** Launch-time restoration. An expired session is refreshed, never promoted; transient failures keep it. */
    fun restore(): AccountState = exclusive {
        if (!isConfigured) return@exclusive state
        val stored = vault.read()
        val saved = SessionCodec.decode(stored)
        if (saved == null) {
            if (stored != null) vault.clear()
            synchronized(lock) { session = null; state = AccountState.SignedOut }
            return@exclusive state
        }
        if (saved.expiresAt > now() + REFRESH_MARGIN) { adopt(saved); return@exclusive state }
        state = AccountState.Restoring
        try { adopt(client().refresh(saved.refreshToken, saved.provider)) }
        catch (e: AuthException.SessionEnded) { endSession("Your session ended. Sign in again.") }
        catch (e: AuthException.InvalidCredentials) { endSession("Your session ended. Sign in again.") }
        catch (e: AuthException.Network) { synchronized(lock) { session = null; state = AccountState.RetryableFailure("Your session could not be refreshed.") } }
        catch (e: AuthException) { endSession("Your session could not be restored. Sign in again.") }
        state
    }

    private fun endSession(reason: String) = synchronized(lock) {
        if (session != null) generation++
        session = null; vault.clear(); state = AccountState.SignInRequired(reason)
    }

    fun signIn(email: String, password: String): AccountState = exclusive {
        require(email.isNotBlank() && password.isNotEmpty()) { "Enter an email and password." }
        adopt(client().signInWithPassword(email, password)); state
    }
    /** True when signed in immediately; false when the email must be confirmed first. */
    fun signUp(email: String, password: String, username: String): Boolean = exclusive {
        require(email.isNotBlank() && password.length >= 8) { "Use an email and a password of at least 8 characters." }
        val created = client().signUp(email, password, username.trim().take(40))
        if (created != null) adopt(created)
        created != null
    }
    fun signInAsGuest(): AccountState = exclusive { adopt(client().signInAnonymously()); state }

    /** Returns the hosted authorize URL to open in the browser; the verifier stays in memory only. */
    fun beginOAuth(provider: OAuthProvider): String {
        if (provider !in providers()) throw AuthException.ProviderUnavailable(provider)
        val verifier = Pkce.verifier(random)
        synchronized(lock) { pending = provider to verifier }
        return client().authorizeUrl(provider, Pkce.challenge(verifier))
    }
    /** One-shot: the pending verifier is consumed before any exchange, so a replay cannot sign in. */
    fun completeOAuth(callback: String): AccountState = exclusive {
        val started = synchronized(lock) { pending.also { pending = null } } ?: throw AuthException.InvalidCallback()
        OAuthCallback.denial(callback)?.let { throw AuthException.ProviderDenied(it) }
        val code = OAuthCallback.code(callback) ?: throw AuthException.InvalidCallback()
        adopt(client().exchangeCode(code, started.second, started.first)); state
    }
    fun cancelOAuth() = synchronized(lock) { pending = null }

    /** A usable access token, refreshed ahead of expiry; null when signed out. */
    fun accessToken(): String? {
        val current = synchronized(lock) { session } ?: return null
        if (current.expiresAt > now() + REFRESH_MARGIN) return current.accessToken
        return exclusive {
            val latest = synchronized(lock) { session } ?: return@exclusive null
            if (latest.expiresAt > now() + REFRESH_MARGIN) return@exclusive latest.accessToken
            try { client().refresh(latest.refreshToken, latest.provider).also { adopt(it) }.accessToken }
            catch (e: AuthException.SessionEnded) { endSession("Your session ended. Sign in again."); null }
            catch (e: AuthException.InvalidCredentials) { endSession("Your session ended. Sign in again."); null }
        }
    }

    /** Local sign-out always completes; server revocation is attempted once. */
    fun signOut() {
        val current = synchronized(lock) { session }
        if (current != null && isConfigured) client().logout(current.accessToken)
        adopt(null)
    }

    companion object { const val REFRESH_MARGIN = 60L }
}
