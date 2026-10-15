package com.stickdeath.studio.connect

import com.stickdeath.studio.billing.PlanCopy
import com.stickdeath.studio.billing.PlanTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SpatterUsageTest {
    private val endpoint = "https://spatter.example.test/v1/chat"
    private val question = listOf(SpatterMessage(SpatterMessage.Role.User, "Help me time a fall."))
    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try { block() } catch (e: Throwable) { if (e is T) return e; throw e }
        fail("Expected ${T::class.simpleName}"); error("unreachable")
    }

    @Test fun decodesTheServerUsageShapes() {
        val free = SpatterUsageDecoder.decode("""{"plan":"free","unlimited":false,"limit":0,"used":0,"remaining":0,"period":"none","resets_at":null,"available":false,"upgrade":"creator_or_pro","service":"metered"}""")
        assertEquals(PlanTier.Free, free.plan); assertEquals(false, free.available); assertNull(free.credits); assertFalse(free.paused)
        val payg = SpatterUsageDecoder.decode("""{"plan":"free","credits":12,"available":true}""")
        assertEquals(12, payg.credits); assertEquals(true, payg.available)
        val creator = SpatterUsageDecoder.decode("""{"plan":"creator","unlimited":false,"limit":174,"used":10,"remaining":164,"resets_at":"2026-11-01T00:00:00Z","service":"paused"}""")
        assertEquals(174, creator.limit); assertEquals(164, creator.remaining); assertEquals("2026-11-01T00:00:00Z", creator.resetsAt); assertTrue(creator.paused)
        val pro = SpatterUsageDecoder.decode("""{"plan":"pro","unlimited":true,"limit":null,"remaining":null}""")
        assertTrue(pro.unlimited); assertNull(pro.remaining)
    }

    @Test fun neverInventsCountsAndRefusesUnknownPlans() {
        val odd = SpatterUsageDecoder.decode("""{"plan":"creator","limit":"many","remaining":-3,"credits":1.5}""")
        assertNull(odd.limit); assertNull(odd.remaining); assertNull(odd.credits)
        expect<SpatterException.InvalidResponse> { SpatterUsageDecoder.decode("""{"plan":"enterprise"}""") }
        expect<SpatterException.InvalidResponse> { SpatterUsageDecoder.decode("""{"error":"Sign in to view your Spatter allowance."}""") }
        expect<SpatterException.InvalidResponse> { SpatterUsageDecoder.decode("not json") }
    }

    @Test fun readsUsageThroughTheMemberRpc() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"plan":"free","credits":3}""") }
        val usage = SpatterUsageClient(CommunityGateway(FixedSession(), transport)).myUsage()
        assertEquals(3, usage.credits)
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_spatter_my_usage", transport.requests.single().url)
    }

    @Test fun mapsHttp402ToTheUpgradeNoteOrPaymentRequired() {
        val upgrade = expect<SpatterException.UpgradeRequired> {
            SpatterClient(endpoint, FixedSession(), ScriptedTransport { ScriptedTransport.json(402, """{"schemaVersion":1,"error":"x","code":"upgrade_required","plan":"free"}""") }).complete(question) }
        assertEquals(PlanCopy.SPATTER_UPGRADE_NOTE, upgrade.message)
        val other = expect<SpatterException.PaymentRequired> {
            SpatterClient(endpoint, FixedSession(), ScriptedTransport { ScriptedTransport.json(402, """{"code":"credits_exhausted","error":"<server text>"}""") }).complete(question) }
        assertEquals("credits_exhausted", other.code)
        assertFalse(other.message!!.contains("<server text>"))
        expect<SpatterException.PaymentRequired> {
            SpatterClient(endpoint, FixedSession(), ScriptedTransport { HttpResponse(402, "oops".toByteArray(), "text/plain") }).complete(question) }
    }
}
