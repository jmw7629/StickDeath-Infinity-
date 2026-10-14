package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.URI
import java.net.URLDecoder

class SessionManagerTest {
    private var clock = 1_000_000L
    private fun manager(transport: HttpTransport, vault: SessionVault = InMemorySessionVault(), config: BackendConfig? = Fixtures.config()) =
        SessionManager(config, vault, transport, now = { clock })
    private fun stored(expiresAt: Long, refresh: String = "refresh-0") =
        SessionCodec.encode(StoredSession("access-0", refresh, expiresAt, Fixtures.USER, "creator@example.test", false, "email"))
    private inline fun <reified T : Throwable> expect(block: () -> Unit) {
        try { block(); fail("Expected ${T::class.simpleName}") } catch (e: Throwable) { if (e !is T) throw e }
    }

    @Test fun unconfiguredBuildNeverSends() {
        val transport = ScriptedTransport.offline()
        val noConfig = manager(transport, config = null)
        assertTrue(noConfig.state is AccountState.NotConfigured)
        assertTrue(noConfig.restore() is AccountState.NotConfigured)
        expect<AuthException.NotConfigured> { noConfig.signIn("a@example.test", "password1") }
        val noNetwork = manager(transport, config = Fixtures.config(network = false))
        assertTrue(noNetwork.state is AccountState.NotConfigured)
        expect<AuthException.NotConfigured> { noNetwork.signInAsGuest() }
        assertEquals(emptySet<OAuthProvider>(), noNetwork.providers())
        assertEquals(0, transport.requests.size)
    }

    @Test fun passwordSignInPersistsAndSendsOnlyThePublishableKey() {
        val vault = InMemorySessionVault()
        val transport = ScriptedTransport { ScriptedTransport.json(200, Fixtures.tokenBody()) }
        val m = manager(transport, vault)
        val state = m.signIn(" creator@example.test ", "password1")
        assertEquals(AccountState.SignedIn(Fixtures.USER, "creator@example.test", false, "email"), state)
        val request = transport.requests.single()
        assertEquals("POST", request.method)
        assertEquals("${Fixtures.URL}/auth/v1/token?grant_type=password", request.url)
        assertEquals(Fixtures.KEY, request.headers["apikey"])
        assertNull(request.headers["Authorization"])
        assertEquals("creator@example.test", JSONObject(String(request.body!!)).getString("email"))
        assertEquals("access-1", SessionCodec.decode(vault.read())!!.accessToken)
        assertFalse(request.toString().contains("password1"))
    }

    @Test fun wrongPasswordIsReportedWithoutStoringAnything() {
        val vault = InMemorySessionVault()
        val m = manager(ScriptedTransport { ScriptedTransport.json(400, """{"error_code":"invalid_credentials","msg":"Invalid login credentials"}""") }, vault)
        expect<AuthException.InvalidCredentials> { m.signIn("creator@example.test", "nope") }
        assertNull(vault.read())
        assertEquals(AccountState.SignedOut, m.state)
    }

    @Test fun guestSessionIsMarkedAnonymous() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, Fixtures.tokenBody(anonymous = true, email = null)) }
        val state = manager(transport).signInAsGuest() as AccountState.SignedIn
        assertTrue(state.isAnonymous)
        assertTrue(state.summary.contains("guest"))
        assertEquals("${Fixtures.URL}/auth/v1/signup", transport.requests.single().url)
    }

    @Test fun signUpWithPendingConfirmationDoesNotSignIn() {
        val m = manager(ScriptedTransport { ScriptedTransport.json(200, """{"id":"${Fixtures.USER}","email":"creator@example.test"}""") })
        assertFalse(m.signUp("creator@example.test", "long-password", "creator"))
        assertEquals(AccountState.SignedOut, m.state)
    }

    @Test fun restoreUsesAnUnexpiredSessionWithoutNetwork() {
        val transport = ScriptedTransport.offline()
        val m = manager(transport, InMemorySessionVault(stored(clock + 3600)))
        assertTrue(m.restore() is AccountState.SignedIn)
        assertEquals("access-0", m.accessToken())
        assertEquals(0, transport.requests.size)
    }

    @Test fun restoreRefreshesAnExpiredSessionAndNeverPromotesIt() {
        val vault = InMemorySessionVault(stored(clock - 10))
        val transport = ScriptedTransport { ScriptedTransport.json(200, Fixtures.tokenBody(access = "access-2", refresh = "refresh-2")) }
        val m = manager(transport, vault)
        assertTrue(m.restore() is AccountState.SignedIn)
        assertEquals("${Fixtures.URL}/auth/v1/token?grant_type=refresh_token", transport.requests.single().url)
        assertEquals("refresh-0", JSONObject(String(transport.requests.single().body!!)).getString("refresh_token"))
        assertEquals("access-2", m.accessToken())
        assertEquals("refresh-2", SessionCodec.decode(vault.read())!!.refreshToken)
    }

    @Test fun offlineRestoreKeepsTheStoredSessionForRetry() {
        val vault = InMemorySessionVault(stored(clock - 10))
        val m = manager(ScriptedTransport.offline(), vault)
        assertTrue(m.restore() is AccountState.RetryableFailure)
        assertNull(m.accessToken())
        assertNotNull(SessionCodec.decode(vault.read()))
    }

    @Test fun revokedRefreshTokenRequiresSignInAndClearsTheVault() {
        val vault = InMemorySessionVault(stored(clock - 10))
        val m = manager(ScriptedTransport { ScriptedTransport.json(400, """{"error_code":"refresh_token_already_used"}""") }, vault)
        assertTrue(m.restore() is AccountState.SignInRequired)
        assertNull(vault.read())
    }

    @Test fun damagedVaultRecordIsDiscarded() {
        val vault = InMemorySessionVault("{not json")
        assertEquals(AccountState.SignedOut, manager(ScriptedTransport.offline(), vault).restore())
        assertNull(vault.read())
    }

    @Test fun accessTokenRefreshesAheadOfExpiry() {
        var calls = 0
        val m = manager(ScriptedTransport { calls++; ScriptedTransport.json(200, Fixtures.tokenBody(access = "access-$calls", expiresIn = 3600)) })
        m.signIn("creator@example.test", "password1")
        val before = m.generation
        clock += 3600 - 30
        assertEquals("access-2", m.accessToken())
        assertEquals(before, m.generation) // same account: replies in flight are not stale
    }

    @Test fun oauthUsesPkceAndTheCallbackIsSingleUse() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, Fixtures.tokenBody()) }
        val m = manager(transport)
        val url = URI(m.beginOAuth(OAuthProvider.Google))
        assertEquals("/auth/v1/authorize", url.path)
        val query = url.rawQuery.split('&').associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
        assertEquals("google", query["provider"]); assertEquals("s256", query["code_challenge_method"])
        assertEquals(OAuthCallback.REDIRECT, query["redirect_to"])
        assertEquals(43, query["code_challenge"]!!.length)
        assertTrue(m.completeOAuth("stickdeath://auth/callback?code=abc123") is AccountState.SignedIn)
        val exchange = JSONObject(String(transport.requests.single().body!!))
        assertEquals("abc123", exchange.getString("auth_code"))
        assertEquals(query["code_challenge"], Pkce.challenge(exchange.getString("code_verifier")))
        expect<AuthException.InvalidCallback> { m.completeOAuth("stickdeath://auth/callback?code=abc123") }
        assertEquals(1, transport.requests.size)
    }

    @Test fun oauthRefusesUnconfiguredProvidersDenialsAndForgedCallbacks() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, Fixtures.tokenBody()) }
        val m = manager(transport)
        expect<AuthException.ProviderUnavailable> { m.beginOAuth(OAuthProvider.Microsoft) }
        expect<AuthException.InvalidCallback> { m.completeOAuth("stickdeath://auth/callback?code=unsolicited") }
        m.beginOAuth(OAuthProvider.GitHub)
        expect<AuthException.ProviderDenied> { m.completeOAuth("stickdeath://auth/callback?code=x&error=access_denied") }
        m.beginOAuth(OAuthProvider.GitHub)
        expect<AuthException.InvalidCallback> { m.completeOAuth("https://evil.example/auth/callback?code=x") }
        m.beginOAuth(OAuthProvider.GitHub)
        expect<AuthException.InvalidCallback> { m.completeOAuth("stickdeath://auth/callback?code=a&code=b") }
        assertEquals(0, transport.requests.size)
        assertEquals("Microsoft declined this sign-in (AADSTS50020). Check the tenant configuration and try again.",
            OAuthCallback.denial("stickdeath://auth/callback?error=access_denied&error_description=AADSTS50020%3A+User+account"))
    }

    @Test fun signOutClearsLocallyEvenWhenRevocationFails() {
        val vault = InMemorySessionVault(stored(clock + 3600))
        val m = manager(ScriptedTransport.offline(), vault)
        m.restore()
        val before = m.generation
        m.signOut()
        assertEquals(AccountState.SignedOut, m.state)
        assertNull(vault.read())
        assertTrue(m.generation > before)
    }

    @Test fun storedSessionNeverPrintsTokens() {
        val text = SessionCodec.decode(stored(clock + 5)).toString()
        assertFalse(text.contains("access-0")); assertFalse(text.contains("refresh-0"))
    }
}
