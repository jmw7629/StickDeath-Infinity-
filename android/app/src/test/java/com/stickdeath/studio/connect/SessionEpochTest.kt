package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** Deterministic races through the production SessionManager. Latches hold actual transport
 * replies; no timing sleep, mirror session model, live backend or socket is used. */
class SessionEpochTest {
    private class Transport(private val handler: (HttpRequest) -> HttpResponse) : HttpTransport {
        private val lock = Any()
        private val sent = mutableListOf<HttpRequest>()
        val requests get() = synchronized(lock) { sent.toList() }
        override fun send(request: HttpRequest, responseLimit: Int): HttpResponse {
            synchronized(lock) { sent += request }
            return handler(request).also { if (it.body.size > responseLimit) throw ResponseTooLargeException() }
        }
    }
    private class Task<T>(block: () -> T) {
        private val result = AtomicReference<Result<T>?>(null)
        private val thread = Thread { result.set(runCatching(block)) }.apply { isDaemon = true; start() }
        fun outcome(): Result<T> {
            thread.join(5000)
            assertFalse("Account worker did not finish after its controlled reply was released", thread.isAlive)
            return checkNotNull(result.get())
        }
    }
    private fun waitFor(latch: CountDownLatch) { assertTrue("Expected auth phase was not reached", latch.await(5, TimeUnit.SECONDS)) }
    private fun reply(body: String = Fixtures.tokenBody()) = ScriptedTransport.json(200, body)
    private fun secondAccount(access: String = "access-b") = Fixtures.tokenBody(access = access, refresh = "refresh-b").replace(Fixtures.USER, Fixtures.OTHER)
    private fun manager(transport: HttpTransport, vault: SessionVault, clock: AtomicLong) =
        SessionManager(Fixtures.config(), vault, transport, now = clock::get)
    private fun expectBusy(block: () -> Unit) {
        try { block(); fail("An obsolete operation must not unlock the current operation") }
        catch (_: AuthException.Busy) { }
    }

    @Test fun signOutClearsImmediatelyWhileRevocationAndRefreshAreBothHeld() {
        val clock = AtomicLong(1_000_000L)
        val refreshEntered = CountDownLatch(1); val releaseRefresh = CountDownLatch(1)
        val logoutEntered = CountDownLatch(1); val releaseLogout = CountDownLatch(1)
        val transport = Transport { request -> when {
            request.url.contains("grant_type=refresh_token") -> { refreshEntered.countDown(); waitFor(releaseRefresh); reply(Fixtures.tokenBody(access = "obsolete-refresh")) }
            request.url.contains("/auth/v1/logout") -> { logoutEntered.countDown(); waitFor(releaseLogout); reply("{}") }
            else -> reply()
        } }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        m.signIn("creator@example.test", "password1"); clock.addAndGet(4000)
        val before = m.generation
        val refresh = Task { m.accessToken() }
        var logout: Task<Unit>? = null
        try {
            waitFor(refreshEntered)
            logout = Task { m.signOut() }
            waitFor(logoutEntered)
            assertEquals(AccountState.SignedOut, m.state)
            assertNull(m.currentUserId()); assertNull(vault.read())
            assertTrue(m.generation > before)
            releaseRefresh.countDown()
            assertNull(refresh.outcome().getOrThrow())
            assertEquals(AccountState.SignedOut, m.state); assertNull(vault.read())
            assertTrue(transport.requests.none { it.url.contains("/rest/v1/") })
        } finally {
            releaseRefresh.countDown(); releaseLogout.countDown()
            refresh.outcome(); logout?.outcome()?.getOrThrow()
        }
    }

    @Test fun staleRefreshCannotReleaseANewerSignInBusySlotOrOverwriteItsVault() {
        val clock = AtomicLong(1_000_000L)
        val refreshEntered = CountDownLatch(1); val releaseRefresh = CountDownLatch(1)
        val secondEntered = CountDownLatch(1); val releaseSecond = CountDownLatch(1)
        val transport = Transport { request -> when {
            request.url.contains("grant_type=refresh_token") -> { refreshEntered.countDown(); waitFor(releaseRefresh); reply(Fixtures.tokenBody(access = "obsolete-refresh")) }
            request.url.contains("grant_type=password") && JSONObject(String(request.body!!)).getString("email") == "second@example.test" -> {
                secondEntered.countDown(); waitFor(releaseSecond); reply(secondAccount())
            }
            request.url.contains("/auth/v1/logout") -> reply("{}")
            else -> reply()
        } }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        m.signIn("creator@example.test", "password1"); clock.addAndGet(4000)
        val refresh = Task { m.accessToken() }
        var second: Task<AccountState>? = null
        try {
            waitFor(refreshEntered); m.signOut()
            second = Task { m.signIn("second@example.test", "password2") }
            waitFor(secondEntered)
            releaseRefresh.countDown(); assertNull(refresh.outcome().getOrThrow())
            expectBusy { m.signInAsGuest() }
            releaseSecond.countDown()
            assertEquals(Fixtures.OTHER, (second.outcome().getOrThrow() as AccountState.SignedIn).userId)
            assertEquals(Fixtures.OTHER, m.currentUserId())
            assertEquals("access-b", SessionCodec.decode(vault.read())!!.accessToken)
        } finally {
            releaseRefresh.countDown(); releaseSecond.countDown()
            refresh.outcome(); second?.outcome()
        }
    }

    @Test fun lateRevokedRefreshCannotEndTheNewAccount() {
        val clock = AtomicLong(1_000_000L)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val transport = Transport { request -> when {
            request.url.contains("grant_type=refresh_token") -> { entered.countDown(); waitFor(release); ScriptedTransport.json(400, """{"error_code":"refresh_token_not_found"}""") }
            request.url.contains("grant_type=password") && JSONObject(String(request.body!!)).getString("email") == "second@example.test" -> reply(secondAccount())
            request.url.contains("/auth/v1/logout") -> reply("{}")
            else -> reply()
        } }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        m.signIn("creator@example.test", "password1"); clock.addAndGet(4000)
        val refresh = Task { m.accessToken() }
        try {
            waitFor(entered); m.signOut(); m.signIn("second@example.test", "password2")
            release.countDown(); assertNull(refresh.outcome().getOrThrow())
            assertEquals(Fixtures.OTHER, m.currentUserId())
            assertEquals(Fixtures.OTHER, (m.state as AccountState.SignedIn).userId)
            assertEquals(Fixtures.OTHER, SessionCodec.decode(vault.read())!!.userId)
        } finally { release.countDown(); refresh.outcome() }
    }

    @Test fun cancelledRestoreCannotPromoteItsSavedAccountAfterNewSignIn() {
        val clock = AtomicLong(1_000_000L)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val saved = StoredSession("expired", "saved-refresh", clock.get() - 1, Fixtures.USER, "creator@example.test", false, "email")
        val transport = Transport { request -> when {
            request.url.contains("grant_type=refresh_token") -> { entered.countDown(); waitFor(release); reply() }
            else -> reply(secondAccount())
        } }
        val vault = InMemorySessionVault(SessionCodec.encode(saved)); val m = manager(transport, vault, clock)
        val restoring = Task { m.restore() }
        try {
            waitFor(entered); m.signOut(); m.signIn("second@example.test", "password2")
            release.countDown()
            assertEquals(Fixtures.OTHER, (restoring.outcome().getOrThrow() as AccountState.SignedIn).userId)
            assertEquals(Fixtures.OTHER, m.currentUserId())
            assertEquals("access-b", SessionCodec.decode(vault.read())!!.accessToken)
        } finally { release.countDown(); restoring.outcome() }
    }

    @Test fun logoutDiscardsAPasswordSignInThatHadNotAdoptedAnySessionYet() {
        val clock = AtomicLong(1_000_000L)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val transport = Transport { entered.countDown(); waitFor(release); reply() }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        val signingIn = Task { m.signIn("creator@example.test", "password1") }
        try {
            waitFor(entered); val before = m.generation; m.signOut()
            assertTrue(m.generation > before)
            release.countDown()
            assertTrue(signingIn.outcome().exceptionOrNull() is AuthException)
            assertEquals(AccountState.SignedOut, m.state); assertNull(vault.read())
        } finally { release.countDown(); signingIn.outcome() }
    }

    @Test fun cancelDiscardsAnOAuthExchangeAlreadySentAndKeepsTheNewAccount() {
        val clock = AtomicLong(1_000_000L)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val transport = Transport { request ->
            if (request.url.contains("grant_type=pkce")) { entered.countDown(); waitFor(release); reply() }
            else reply(secondAccount())
        }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        m.beginOAuth(OAuthProvider.Google)
        val exchange = Task { m.completeOAuth("stickdeath://auth/callback?code=old-code") }
        try {
            waitFor(entered); m.cancelOAuth(); m.signIn("second@example.test", "password2")
            release.countDown()
            assertTrue(exchange.outcome().exceptionOrNull() is AuthException)
            assertEquals(Fixtures.OTHER, m.currentUserId())
            assertEquals("access-b", SessionCodec.decode(vault.read())!!.accessToken)
        } finally { release.countDown(); exchange.outcome() }
    }

    @Test fun newerOAuthIntentDiscardsThePreviousExchangeWithoutConsumingNewVerifier() {
        val clock = AtomicLong(1_000_000L)
        val oldEntered = CountDownLatch(1); val releaseOld = CountDownLatch(1)
        val transport = Transport { request ->
            val code = JSONObject(String(request.body!!)).getString("auth_code")
            if (code == "old-code") { oldEntered.countDown(); waitFor(releaseOld); reply() }
            else reply(secondAccount())
        }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        m.beginOAuth(OAuthProvider.Google)
        val exchange = Task { m.completeOAuth("stickdeath://auth/callback?code=old-code") }
        try {
            waitFor(oldEntered); m.beginOAuth(OAuthProvider.GitHub)
            assertEquals(Fixtures.OTHER, (m.completeOAuth("stickdeath://auth/callback?code=new-code") as AccountState.SignedIn).userId)
            releaseOld.countDown()
            assertTrue(exchange.outcome().exceptionOrNull() is AuthException)
            assertEquals(Fixtures.OTHER, m.currentUserId())
            assertEquals("access-b", SessionCodec.decode(vault.read())!!.accessToken)
        } finally { releaseOld.countDown(); exchange.outcome() }
    }
    @Test fun delayedLogoutTargetsOnlyTheCapturedSessionAndCannotClearASameUserRelogin() {
        val clock = AtomicLong(1_000_000L)
        val logoutEntered = CountDownLatch(1); val releaseLogout = CountDownLatch(1)
        var login = 0
        val transport = Transport { request ->
            if (request.url.contains("/auth/v1/logout")) {
                assertEquals("scope=local", java.net.URI(request.url).rawQuery)
                assertEquals("Bearer access-a", request.headers["Authorization"])
                logoutEntered.countDown(); waitFor(releaseLogout); reply("{}")
            } else {
                login++
                reply(Fixtures.tokenBody(access = if (login == 1) "access-a" else "access-b"))
            }
        }
        val vault = InMemorySessionVault(); val m = manager(transport, vault, clock)
        m.signIn("creator@example.test", "password1")
        val logout = Task { m.signOut() }
        try {
            waitFor(logoutEntered)
            assertEquals(AccountState.SignedOut, m.state); assertNull(vault.read())
            m.signIn("creator@example.test", "password1")
            releaseLogout.countDown(); logout.outcome().getOrThrow()
            assertEquals("access-b", m.accessToken())
            assertEquals("access-b", SessionCodec.decode(vault.read())!!.accessToken)
            assertEquals(Fixtures.USER, m.currentUserId())
        } finally { releaseLogout.countDown(); logout.outcome() }
    }

}
