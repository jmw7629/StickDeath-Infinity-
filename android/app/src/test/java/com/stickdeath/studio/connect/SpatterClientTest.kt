package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SpatterClientTest {
    private val endpoint = "https://spatter.example.test/v1/chat"
    private val question = listOf(SpatterMessage(SpatterMessage.Role.User, "How do I time a punch?"))
    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try { block() } catch (e: Throwable) { if (e is T) return e; throw e }
        fail("Expected ${T::class.simpleName}"); error("unreachable")
    }

    @Test fun sendsTheVersionedPayloadWithTheMemberSession() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"schemaVersion":1,"reply":"Anticipate, then snap.","usage":{"units":3},"budget":{"remaining":17,"resetsAt":"2026-10-15T00:00:00Z"}}""") }
        val reply = SpatterClient(endpoint, FixedSession(), transport).complete(question)
        assertEquals(SpatterReply(1, "Anticipate, then snap.", 3, SpatterBudget(17, "2026-10-15T00:00:00Z")), reply)
        val request = transport.requests.single()
        assertEquals(endpoint, request.url)
        assertEquals("Bearer member-token", request.headers["Authorization"])
        assertNull(request.headers["apikey"]) // the app backend, not PostgREST
        val payload = JSONObject(String(request.body!!))
        assertEquals(1, payload.getInt("schemaVersion")); assertEquals(500, payload.getInt("max_tokens"))
        assertEquals("user", payload.getJSONArray("messages").getJSONObject(0).getString("role"))
    }

    @Test fun refusesWithoutEndpointSessionOrValidRequest() {
        val transport = ScriptedTransport { fail("must not send"); error("unreachable") }
        expect<SpatterException.NotConfigured> { SpatterClient(null, FixedSession(), transport).complete(question) }
        expect<SpatterException.NotConfigured> { SpatterClient("https://api.openai.com/v1/chat/completions", FixedSession(), transport).complete(question) }
        expect<SpatterException.NotConfigured> { SpatterClient(endpoint, FixedSession(configured = null), transport).complete(question) }
        expect<SpatterException.NotAuthenticated> { SpatterClient(endpoint, FixedSession(token = null), transport).complete(question) }
        expect<SpatterException.InvalidRequest> { SpatterClient(endpoint, FixedSession(), transport).complete(emptyList()) }
        expect<SpatterException.InvalidRequest> { SpatterClient(endpoint, FixedSession(), transport).complete(listOf(SpatterMessage(SpatterMessage.Role.User, "  "))) }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun mapsStatusesAndRefusesNonJsonReplies() {
        assertEquals(429, expect<SpatterException.HttpStatus> {
            SpatterClient(endpoint, FixedSession(), ScriptedTransport { ScriptedTransport.json(429, "{}") }).complete(question) }.status)
        expect<SpatterException.InvalidResponse> {
            SpatterClient(endpoint, FixedSession(), ScriptedTransport { HttpResponse(200, "<html>".toByteArray(), "text/html") }).complete(question) }
        expect<SpatterException.NetworkUnavailable> { SpatterClient(endpoint, FixedSession(), ScriptedTransport.offline()).complete(question) }
        expect<SpatterException.ResponseTooLarge> {
            SpatterClient(endpoint, FixedSession(), ScriptedTransport { ScriptedTransport.json(200, "x".repeat(SpatterClient.RESPONSE_LIMIT + 1)) }).complete(question) }
    }

    @Test fun decodesLegacyAndRefusesFutureSchemas() {
        assertEquals(SpatterReply(0, "Legacy", null, null), SpatterClient.decode("""{"choices":[{"message":{"content":"Legacy"}}]}"""))
        expect<SpatterException.InvalidResponse> { SpatterClient.decode("""{"schemaVersion":2,"reply":"x"}""") }
        expect<SpatterException.EmptyResponse> { SpatterClient.decode("""{"schemaVersion":1,"reply":"  "}""") }
        // A budget without a sane remaining count is dropped, not invented.
        assertNull(SpatterClient.decode("""{"schemaVersion":1,"reply":"ok","budget":{"remaining":-1}}""").budget)
    }
}
