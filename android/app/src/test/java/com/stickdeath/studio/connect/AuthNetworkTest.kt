package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.net.URI
import java.net.URLDecoder

/** Password reset, cancellation and the authenticated HTTP path (session refresh feeding the
 * community gateway). Every reply is scripted; no socket is opened. */
class AuthNetworkTest {
    private var clock = 2_000_000L
    private fun manager(transport: HttpTransport, vault: SessionVault = InMemorySessionVault()) =
        SessionManager(Fixtures.config(), vault, transport, now = { clock })
    private inline fun <reified T : Throwable> expect(block: () -> Unit) {
        try { block(); fail("Expected ${T::class.simpleName}") } catch (e: Throwable) { if (e !is T) throw e }
    }
    private fun query(url: String) = URI(url).rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }
        .associate { it.substringBefore('=') to URLDecoder.decode(it.substringAfter('='), "UTF-8") }
    private fun body(request: HttpRequest) = JSONObject(String(request.body!!))

    @Test fun passwordResetUsesPkceAndTheLinkLeadsToANewPassword() {
        val transport = ScriptedTransport { request ->
            when {
                request.url.contains("/auth/v1/recover") -> ScriptedTransport.json(200, "{}")
                request.url.contains("grant_type=pkce") -> ScriptedTransport.json(200, Fixtures.tokenBody(access = "recovery-access"))
                request.url.endsWith("/auth/v1/user") -> ScriptedTransport.json(200, """{"id":"${Fixtures.USER}"}""")
                else -> ScriptedTransport.json(500, "{}")
            }
        }
        val vault = InMemorySessionVault()
        val m = manager(transport, vault)
        m.requestPasswordReset(" creator@example.test ")
        val recover = transport.requests.single()
        assertEquals("POST", recover.method)
        assertEquals("/auth/v1/recover", URI(recover.url).path)
        assertEquals(OAuthCallback.REDIRECT, query(recover.url)["redirect_to"])
        assertEquals("creator@example.test", body(recover).getString("email"))
        assertEquals("s256", body(recover).getString("code_challenge_method"))
        assertNull(recover.headers["Authorization"])
        assertEquals(AccountState.SignedOut, m.state)

        val state = m.completeOAuth("stickdeath://auth/callback?code=reset-code") as AccountState.SignedIn
        assertEquals(RECOVERY_PROVIDER, state.provider)
        assertTrue(m.needsNewPassword)
        assertTrue(state.summary.contains("new password"))
        val exchange = body(transport.requests[1])
        assertEquals("reset-code", exchange.getString("auth_code"))
        assertEquals(body(recover).getString("code_challenge"), Pkce.challenge(exchange.getString("code_verifier")))

        m.updatePassword("a-new-long-password")
        val update = transport.requests[2]
        assertEquals("PUT", update.method)
        assertEquals("Bearer recovery-access", update.headers["Authorization"])
        assertEquals("a-new-long-password", body(update).getString("password"))
        assertFalse(m.needsNewPassword)
        assertEquals("email", SessionCodec.decode(vault.read())!!.provider)
        assertFalse(update.toString().contains("a-new-long-password"))
    }

    @Test fun failedResetForgetsTheVerifierAndShortPasswordsAreRefusedLocally() {
        val transport = ScriptedTransport { ScriptedTransport.json(429, """{"error_code":"over_email_send_rate_limit"}""") }
        val m = manager(transport)
        expect<AuthException.RateLimited> { m.requestPasswordReset("creator@example.test") }
        expect<AuthException.InvalidCallback> { m.completeOAuth("stickdeath://auth/callback?code=late") }
        expect<IllegalArgumentException> { m.requestPasswordReset("not-an-email") }
        expect<IllegalArgumentException> { m.updatePassword("short") }
        assertEquals(1, transport.requests.size)
    }

    @Test fun cancelledProviderSignInRefusesTheLateCallback() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, Fixtures.tokenBody()) }
        val m = manager(transport)
        m.beginOAuth(OAuthProvider.Google)
        m.cancelOAuth()
        expect<AuthException.InvalidCallback> { m.completeOAuth("stickdeath://auth/callback?code=after-cancel") }
        assertEquals(AccountState.SignedOut, m.state)
        assertEquals(0, transport.requests.size)
    }

    @Test fun interruptedSignInStoresNothingAndReleasesTheLock() {
        var interrupt = true
        val transport = ScriptedTransport {
            if (interrupt) throw InterruptedIOException("cancelled") else ScriptedTransport.json(200, Fixtures.tokenBody())
        }
        val vault = InMemorySessionVault()
        val m = manager(transport, vault)
        expect<AuthException.Network> { m.signIn("creator@example.test", "password1") }
        assertNull(vault.read())
        assertEquals(AccountState.SignedOut, m.state)
        interrupt = false
        assertTrue(m.signIn("creator@example.test", "password1") is AccountState.SignedIn) // not left Busy
    }

    @Test fun expiredTokenIsRefreshedBeforeTheAuthenticatedCall() {
        val transport = ScriptedTransport { request ->
            when {
                request.url.contains("grant_type=password") -> ScriptedTransport.json(200, Fixtures.tokenBody(access = "access-1", expiresIn = 3600))
                request.url.contains("grant_type=refresh_token") -> ScriptedTransport.json(200, Fixtures.tokenBody(access = "access-2", refresh = "refresh-2"))
                else -> ScriptedTransport.json(200, """{"ok":true}""")
            }
        }
        val m = manager(transport)
        m.signIn("creator@example.test", "password1")
        clock += 3600 // the access token has now expired
        val reply = CommunityGateway(m.asSessionSource(), transport).call("sdi_notify_action", JSONObject().put("action", "inbox"))
        assertTrue(reply.getBoolean("ok"))
        assertEquals(listOf("grant_type=password", "grant_type=refresh_token", "/rest/v1/rpc/sdi_notify_action"),
            transport.requests.map { r -> listOf("grant_type=password", "grant_type=refresh_token", "/rest/v1/rpc/sdi_notify_action").first { r.url.contains(it) } })
        val rpc = transport.requests.last()
        assertEquals("Bearer access-2", rpc.headers["Authorization"])
        assertEquals(Fixtures.KEY, rpc.headers["apikey"])
    }

    @Test fun revokedRefreshDuringACallEndsTheSessionWithoutSending() {
        val vault = InMemorySessionVault()
        val transport = ScriptedTransport { request ->
            if (request.url.contains("grant_type=password")) ScriptedTransport.json(200, Fixtures.tokenBody(expiresIn = 3600))
            else ScriptedTransport.json(400, """{"error_code":"refresh_token_not_found"}""")
        }
        val m = manager(transport, vault)
        m.signIn("creator@example.test", "password1")
        clock += 4000
        expect<CommunityException.SignedOut> { CommunityGateway(m.asSessionSource(), transport).call("sdi_notify_action") }
        assertTrue(m.state is AccountState.SignInRequired)
        assertNull(vault.read())
        assertTrue(transport.requests.none { it.url.contains("/rest/v1/") })
    }

    @Test fun offlineRefreshDuringACallKeepsTheSession() {
        var online = true
        val vault = InMemorySessionVault()
        val transport = ScriptedTransport {
            if (!online) throw IOException("offline") else ScriptedTransport.json(200, Fixtures.tokenBody(expiresIn = 3600))
        }
        val m = manager(transport, vault)
        m.signIn("creator@example.test", "password1")
        online = false
        clock += 4000
        expect<CommunityException.Transport> { CommunityGateway(m.asSessionSource(), transport).call("sdi_notify_action") }
        assertNotNull(SessionCodec.decode(vault.read()))
        assertTrue(m.state is AccountState.SignedIn)
    }

    @Test fun serverRejectionOfTheJwtSignsTheCallOut() {
        val transport = ScriptedTransport { request ->
            if (request.url.contains("/auth/v1/")) ScriptedTransport.json(200, Fixtures.tokenBody()) else ScriptedTransport.json(401, """{"message":"JWT expired"}""")
        }
        val m = manager(transport)
        m.signIn("creator@example.test", "password1")
        val error = try { CommunityGateway(m.asSessionSource(), transport).call("sdi_notify_action"); null } catch (e: CommunityException) { e }
        assertTrue(error is CommunityException.SignedOut)
        assertFalse(error!!.message!!.contains("JWT"))
    }

    @Test fun productionTransportRefusesPlainHttpAndBoundsBodies() {
        try {
            UrlConnectionTransport().send(HttpRequest("GET", "http://project.example.test/rest/v1/x", emptyMap()), 10)
            fail("plain HTTP must be refused")
        } catch (e: IOException) { assertEquals("Only HTTPS is permitted.", e.message) }
        assertEquals(4, UrlConnectionTransport.readBounded(ByteArrayInputStream(ByteArray(4)), 4).size)
        try { UrlConnectionTransport.readBounded(ByteArrayInputStream(ByteArray(5)), 4); fail("over the limit") } catch (e: ResponseTooLargeException) { }
    }
}
