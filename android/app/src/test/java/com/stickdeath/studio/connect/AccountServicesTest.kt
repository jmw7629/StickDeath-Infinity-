package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AccountServicesTest {
    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try { block() } catch (e: Throwable) { if (e is T) return e; throw e }
        fail("Expected ${T::class.simpleName}"); error("unreachable")
    }
    private fun body(request: HttpRequest) = JSONObject(String(request.body!!))
    private fun lifecycle(reply: String) = ScriptedTransport { ScriptedTransport.json(200, reply) }

    @Test fun statusReportsNoRequestAndTheServerNote() {
        val transport = lifecycle("""{"deletion":null,"exports_remaining_today":2,"note":"Projects on your devices are untouched."}""")
        val status = AccountLifecycleClient(CommunityGateway(FixedSession(), transport)).status()
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_account_lifecycle", transport.requests.single().url)
        assertEquals("""{"action":"status"}""", String(transport.requests.single().body!!))
        assertNull(status.deletion); assertEquals(2, status.exportsRemainingToday)
        assertTrue(status.note.contains("untouched"))
    }

    @Test fun deletionRequestAndCancelUseTheSeenRevision() {
        val requested = lifecycle("""{"status":"pending","scheduled_for":"2026-10-25T00:00:00+00:00","revision":2}""")
        val status = AccountLifecycleClient(CommunityGateway(FixedSession(), requested)).requestDeletion()
        assertTrue(status.isOpen); assertTrue(status.canCancel); assertEquals(2, status.revision)
        // An already open request comes back without a revision: the status is re-read so it can be cancelled.
        val reopenedTransport = ScriptedTransport { request ->
            if (body(request).getString("action") == "request_deletion") ScriptedTransport.json(200, """{"status":"pending","scheduled_for":"2026-10-25T00:00:00+00:00"}""")
            else ScriptedTransport.json(200, """{"deletion":{"state":"pending","scheduled_for":"2026-10-25T00:00:00+00:00","revision":3},"exports_remaining_today":3,"note":""}""")
        }
        val reopened = AccountLifecycleClient(CommunityGateway(FixedSession(), reopenedTransport)).requestDeletion()
        assertTrue(reopened.canCancel); assertEquals(3, reopened.revision)
        assertEquals(listOf("request_deletion", "status"), reopenedTransport.requests.map { body(it).getString("action") })
        // Without a readable status the reply stands: not cancellable until refreshed.
        val unreadable = ScriptedTransport { request ->
            if (body(request).getString("action") == "request_deletion") ScriptedTransport.json(200, """{"status":"processing"}""")
            else ScriptedTransport.json(200, """{"deletion":null,"note":""}""")
        }
        assertFalse(AccountLifecycleClient(CommunityGateway(FixedSession(), unreadable)).requestDeletion().canCancel)
        val unknown = lifecycle("""{"status":"deleted"}""")
        expect<CommunityException.InvalidResponse> { AccountLifecycleClient(CommunityGateway(FixedSession(), unknown)).requestDeletion() }
        val cancel = lifecycle("""{"status":"cancelled"}""")
        AccountLifecycleClient(CommunityGateway(FixedSession(), cancel)).cancelDeletion(2)
        val sent = body(cancel.requests.single())
        assertEquals("cancel_deletion", sent.getString("action")); assertEquals(2, sent.getInt("revision"))
        val stale = lifecycle("""{"error":"Request changed. Refresh before cancelling."}""")
        expect<CommunityException.Server> { AccountLifecycleClient(CommunityGateway(FixedSession(), stale)).cancelDeletion(1) }
    }

    @Test fun exportMustBeCompleteAndRespectsTheServerLimit() {
        val complete = lifecycle("""{"generated_at":"2026-10-18T00:00:00+00:00","account":{"id":"${Fixtures.USER}"},"feed_posts":[]}""")
        val text = AccountLifecycleClient(CommunityGateway(FixedSession(), complete)).export()
        assertEquals(Fixtures.USER, JSONObject(text).getJSONObject("account").getString("id"))
        expect<CommunityException.InvalidResponse> { AccountLifecycleClient(CommunityGateway(FixedSession(), lifecycle("""{"generated_at":"x"}"""))).export() }
        val limited = lifecycle("""{"error":"Three exports per day. Try again later."}""")
        expect<CommunityException.Server> { AccountLifecycleClient(CommunityGateway(FixedSession(), limited)).export() }
        assertEquals("stickdeath-account-export-1970-01-01.json", AccountLifecycleClient.exportFileName(0))
    }

    @Test fun notificationPreferencesRoundTripThroughThePayload() {
        val transport = lifecycle("""{"push_product":false,"push_marketing":false,"email_product":true,"email_marketing":false,"daily_cap":2,"transactional":"always on","devices":[]}""")
        val client = NotificationsClient(CommunityGateway(FixedSession(), transport))
        val prefs = client.preferences()
        assertEquals("preferences", body(transport.requests.single()).getString("action"))
        assertTrue(prefs.emailProduct); assertEquals(2, prefs.dailyCap); assertEquals(0, prefs.registeredDevices)
        val save = lifecycle("""{"status":"confirmed"}""")
        NotificationsClient(CommunityGateway(FixedSession(), save)).save(prefs.copy(pushProduct = true, dailyCap = 4))
        val sent = body(save.requests.single())
        assertEquals("set_preferences", sent.getString("action"))
        assertTrue(sent.getJSONObject("payload").getBoolean("push_product")); assertEquals(4, sent.getJSONObject("payload").getInt("daily_cap"))
        expect<IllegalArgumentException> { NotificationsClient(CommunityGateway(FixedSession(), save)).save(prefs.copy(dailyCap = 11)) }
        val incomplete = lifecycle("""{"push_product":false}""")
        expect<CommunityException.InvalidResponse> { NotificationsClient(CommunityGateway(FixedSession(), incomplete)).preferences() }
    }

    @Test fun inboxCountsComeFromTheServer() {
        val delivery = "0ddddddd-1111-4222-8333-444444444444"
        val transport = lifecycle("""{"notices":[{"delivery":"$delivery","title":"T","body":"B","category":"product","state":"sent","delivered_at":"2026-10-18T00:00:00+00:00"}],"unread":1}""")
        val inbox = NotificationsClient(CommunityGateway(FixedSession(), transport)).inbox()
        assertEquals(1, inbox.unread); assertTrue(inbox.notices.single().unread)
        val unchanged = lifecycle("""{"status":"unchanged"}""")
        assertFalse(NotificationsClient(CommunityGateway(FixedSession(), unchanged)).markRead(delivery))
        assertEquals(delivery, body(unchanged.requests.single()).getJSONObject("payload").getString("delivery"))
        val guest = lifecycle("""{"error":"Sign in with a full account."}""")
        expect<CommunityException.Server> { NotificationsClient(CommunityGateway(FixedSession(), guest)).inbox() }
    }
}
