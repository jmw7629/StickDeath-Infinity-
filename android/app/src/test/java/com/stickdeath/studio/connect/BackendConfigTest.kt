package com.stickdeath.studio.connect

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class BackendConfigTest {
    private fun b64(s: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray())
    private fun jwt(role: String, alg: String = "HS256") = "${b64("""{"alg":"$alg","typ":"JWT"}""")}.${b64("""{"iss":"supabase","role":"$role"}""")}.c2lnbmF0dXJl"

    @Test fun acceptsOnlyHttpsOrigins() {
        assertEquals("https://abc.supabase.co", BackendConfig.origin("https://abc.supabase.co/"))
        assertEquals("https://abc.supabase.co", BackendConfig.origin("https://ABC.supabase.co:443"))
        listOf("http://abc.supabase.co", "https://abc.supabase.co/rest", "https://u:p@abc.supabase.co", "https://abc.supabase.co?x=1",
            "https://abc.supabase.co:8443", "https://abc.supabase.co#f", "", "   ", "\$(SUPABASE_URL)", "https://a b.co", null)
            .forEach { assertNull(it, BackendConfig.origin(it)) }
    }

    @Test fun acceptsOnlyPublishableKeys() {
        assertTrue(BackendConfig.isPublishableKey("sb_publishable_AbC-123_x"))
        assertTrue(BackendConfig.isPublishableKey(jwt("anon")))
        assertFalse(BackendConfig.isPublishableKey(jwt("service_role")))
        assertFalse(BackendConfig.isPublishableKey(jwt("anon", alg = "none")))
        assertFalse(BackendConfig.isPublishableKey("sb_secret_abc"))
        assertFalse(BackendConfig.isPublishableKey("sb_publishable_"))
        assertFalse(BackendConfig.isPublishableKey("sb_publishable_has space"))
        assertNull(BackendConfig.from("https://abc.supabase.co", jwt("service_role"), null, null, true))
    }

    @Test fun providersFailClosed() {
        assertEquals(setOf(OAuthProvider.Google, OAuthProvider.Microsoft), BackendConfig.parseProviders(" google, microsoft "))
        assertEquals(emptySet<OAuthProvider>(), BackendConfig.parseProviders("google,facebook"))
        assertEquals(emptySet<OAuthProvider>(), BackendConfig.parseProviders(""))
        assertEquals(setOf(OAuthProvider.Apple), BackendConfig.parseProviders("apple"))
    }

    @Test fun spatterEndpointRefusesProviderHosts() {
        assertNotNull(SpatterEndpoint.validate("https://api.stickdeath.example/spatter"))
        listOf("https://api.openai.com/v1/chat/completions", "https://api.anthropic.com/v1/messages", "http://spatter.example.test",
            "https://x.generativelanguage.googleapis.com/", "https://spatter.example.test?key=1", "https://user@spatter.example.test")
            .forEach { assertNull(it, SpatterEndpoint.validate(it)) }
        // An invalid Spatter value disables only Spatter cloud, not the account configuration.
        val config = BackendConfig.from(Fixtures.URL, Fixtures.KEY, "https://api.openai.com/v1", "", true)!!
        assertNull(config.spatterEndpoint)
    }

    @Test fun toStringRedactsTheKey() {
        assertFalse(Fixtures.config().toString().contains(Fixtures.KEY))
        assertFalse(HttpRequest("GET", Fixtures.URL, mapOf("Authorization" to "Bearer secret-token")).toString().contains("secret-token"))
    }

    @Test fun transportRefusesPlainHttpAndBoundsBodies() {
        try { UrlConnectionTransport().send(HttpRequest("GET", "http://project.example.test/", emptyMap()), 10); org.junit.Assert.fail() }
        catch (e: java.io.IOException) { assertEquals("Only HTTPS is permitted.", e.message) }
        assertEquals(4, UrlConnectionTransport.readBounded("abcd".byteInputStream(), 4).size)
        try { UrlConnectionTransport.readBounded("abcde".byteInputStream(), 4); org.junit.Assert.fail() } catch (e: ResponseTooLargeException) { }
    }
}
