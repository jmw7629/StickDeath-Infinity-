package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.time.YearMonth
import java.time.ZoneId

/** Room owner screens, challenge moderation and the read-only calendar over the iOS RPCs (#288). */
class RoomOwnerAndScheduleTest {
    private val room = "0eeeeeee-1111-4222-8333-444444444444"
    private val project = "0aaaaaaa-1111-4222-8333-444444444444"
    private fun body(request: HttpRequest) = JSONObject(String(request.body!!))

    @Test fun createRoomSharesOnlyTheExplicitMetadataWithTheMemberSession() {
        val transport = ScriptedTransport { request ->
            if (request.url.endsWith("/sdi_room_action")) ScriptedTransport.json(200, """{"status":"created","room_id":"$room"}""")
            else ScriptedTransport.json(200, """{"status":"updated","project_revision":2}""")
        }
        val client = RoomsClient(CommunityGateway(FixedSession(), transport))
        val outcome = client.createRoom("  Animation team  ", RoomProjectShareDraft(project, "  Scene 1  ", true), true)
        assertEquals(RoomCreationOutcome.Created(room, 2), outcome)
        assertEquals(2, transport.requests.size)
        val create = transport.requests[0]; val share = transport.requests[1]
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_room_action", create.url)
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_room_manage", share.url)
        assertEquals("Bearer member-token", share.headers["Authorization"])
        assertEquals(setOf("action", "title", "consent"), body(create).keys().asSequence().toSet())
        assertEquals("create", body(create).getString("action")); assertEquals("Animation team", body(create).getString("title"))
        assertTrue(body(create).getBoolean("consent"))
        val sent = body(share)
        assertEquals(setOf("action", "room", "project_ref", "project_title", "permissions", "revision"), sent.keys().asSequence().toSet())
        assertEquals("set_project", sent.getString("action")); assertEquals(room, sent.getString("room"))
        assertEquals("device-project:$project", sent.getString("project_ref")); assertEquals("Scene 1", sent.getString("project_title"))
        assertEquals("[\"view\",\"edit\"]", sent.getJSONArray("permissions").toString()); assertEquals(1, sent.getInt("revision"))
        assertEquals(listOf("view"), RoomProjectShareDraft(project, "P").permissions)
    }

    @Test fun createRoomValidatesConsentAndMetadataBeforeAnyRequest() {
        val transport = ScriptedTransport { fail("Invalid drafts must not send"); error("unreachable") }
        val client = RoomsClient(CommunityGateway(FixedSession(), transport))
        val valid = RoomProjectShareDraft(project, "P")
        val invalid = listOf<() -> Unit>(
            { client.createRoom("R", valid, false) },
            { client.createRoom(" ", valid, true) },
            { client.createRoom("R".repeat(101), valid, true) },
            { client.createRoom("R", valid.copy(projectId = "account-token"), true) },
            { client.createRoom("R", valid.copy(title = " "), true) },
            { client.createRoom("R", valid.copy(title = "P".repeat(101)), true) }
        )
        invalid.forEach { call -> try { call(); fail("Expected invalid input") } catch (_: IllegalArgumentException) { } }
        try { client.createRoom("R", valid, true) { false }; fail() } catch (_: CommunityException.Stale) { }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun failedSecondStageRetainsTheCreatedRoomAndNeverRepeatsCreate() {
        val transport = ScriptedTransport { request ->
            if (request.url.endsWith("/sdi_room_action")) ScriptedTransport.json(200, """{"status":"created","room_id":"$room"}""")
            else ScriptedTransport.json(200, """{"error":"Revision changed."}""")
        }
        val outcome = RoomsClient(CommunityGateway(FixedSession(), transport)).createRoom("R", RoomProjectShareDraft(project, "P"), true)
        assertTrue(outcome is RoomCreationOutcome.CreatedWithoutProject)
        assertEquals(room, outcome.room); assertEquals(2, transport.requests.size)
        assertEquals(1, transport.requests.count { it.url.endsWith("/sdi_room_action") })
    }

    @Test fun hideBetweenCreateAndShareKeepsPartialRoomWithoutStartingTheShare() {
        var visible = true
        val transport = ScriptedTransport {
            visible = false
            ScriptedTransport.json(200, """{"status":"created","room_id":"$room"}""")
        }
        val outcome = RoomsClient(CommunityGateway(FixedSession(), transport)).createRoom("R", RoomProjectShareDraft(project, "P"), true) { visible }
        assertTrue(outcome is RoomCreationOutcome.CreatedWithoutProject); assertEquals(room, outcome.room)
        assertEquals(1, transport.requests.size)
    }

    @Test fun changedAccountCannotUseTheNewSessionForTheSecondStage() {
        val session = FixedSession()
        val original = session.generation
        val transport = ScriptedTransport {
            session.generation++; session.token = "different-member-token"
            ScriptedTransport.json(200, """{"status":"created","room_id":"$room"}""")
        }
        try {
            RoomsClient(CommunityGateway(session, transport)).createRoom("R", RoomProjectShareDraft(project, "P"), true) { session.generation == original }
            fail("The old account's response must be discarded")
        } catch (_: CommunityException.Stale) { }
        assertEquals(1, transport.requests.size)
        assertEquals("Bearer member-token", transport.requests.single().headers["Authorization"])
    }

    @Test fun creationNeedsConfigurationSessionAndAConfirmedProjectRevision() {
        val noNetwork = ScriptedTransport { fail("Must not send"); error("unreachable") }
        val draft = RoomProjectShareDraft(project, "P")
        try { RoomsClient(CommunityGateway(FixedSession(configured = null), noNetwork)).createRoom("R", draft, true); fail() } catch (_: CommunityException.NotConfigured) { }
        try { RoomsClient(CommunityGateway(FixedSession(token = null), noNetwork)).createRoom("R", draft, true); fail() } catch (_: CommunityException.SignedOut) { }
        assertTrue(noNetwork.requests.isEmpty())
        val wrongRevision = ScriptedTransport { request ->
            if (request.url.endsWith("/sdi_room_action")) ScriptedTransport.json(200, """{"status":"created","room_id":"$room"}""")
            else ScriptedTransport.json(200, """{"status":"updated","project_revision":1}""")
        }
        assertTrue(RoomsClient(CommunityGateway(FixedSession(), wrongRevision)).createRoom("R", draft, true) is RoomCreationOutcome.CreatedWithoutProject)
        val malformed = ScriptedTransport { ScriptedTransport.json(200, """{"status":"created","room_id":"not-a-uuid"}""") }
        try { RoomsClient(CommunityGateway(FixedSession(), malformed)).createRoom("R", draft, true); fail() } catch (_: CommunityException.InvalidResponse) { }
        assertEquals(1, malformed.requests.size)
    }

    @Test fun summaryMembersAndOwnerActionsUseTheIosContracts() {
        val transport = ScriptedTransport { request ->
            when {
                request.url.contains("/rpc/sdi_room_manage") && body(request).getString("action") == "summary" -> ScriptedTransport.json(200,
                    """{"room_id":"$room","title":"R","owner_id":"${Fixtures.USER}","project_ref":"device-project:$project","project_title":"P","permissions":["view","edit"],"project_revision":2,"command_revision":5,"my_role":"owner","can_edit":true,"members":1}""")
                request.url.contains("/rpc/sdi_room_manage") -> ScriptedTransport.json(200, """{"status":"updated"}""")
                request.url.contains("sdi_room_members") -> ScriptedTransport.json(200,
                    """[{"user_id":"${Fixtures.OTHER}","owner_approved":false,"member_accepted":true,"revoked":false,"role":null,"request_expires_at":"2026-10-19T00:00:00+00:00"}]""")
                else -> ScriptedTransport.json(200, """{"status":"updated"}""")
            }
        }
        val client = RoomsClient(CommunityGateway(FixedSession(), transport))
        val detail = client.summary(room)
        assertEquals(project, detail.projectID); assertEquals(5, detail.commandRevision); assertEquals(true, detail.canEdit)
        val member = client.members(room).single()
        assertTrue(member.awaitsApproval); assertFalse(member.isActive)
        assertTrue(transport.requests.last().url.contains("room_id=eq.$room"))
        client.approve(room, member.userId)
        assertEquals("approve", body(transport.requests.last()).getString("action"))
        client.decline(room, member.userId)
        assertEquals("remove", body(transport.requests.last()).getString("action"))
        client.revokeInvitations(room)
        assertEquals("revoke_invites", body(transport.requests.last()).getString("action"))
        client.setRole(room, member.userId, RoomRole.Editor)
        val role = body(transport.requests.last())
        assertEquals("set_role", role.getString("action")); assertEquals("editor", role.getString("role")); assertEquals(Fixtures.OTHER, role.getString("subject"))
        assertNull(RoomProjectShare.projectID("https://elsewhere")); assertNull(RoomProjectShare.projectID("device-project:not-a-uuid"))
    }

    @Test fun summaryForAnotherRoomIsRejected() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"room_id":"${Fixtures.OTHER}"}""") }
        try { RoomsClient(CommunityGateway(FixedSession(), transport)).summary(room); fail() } catch (_: CommunityException.InvalidResponse) { }
    }

    @Test fun moderatorActionsAreServerGatedAndValidated() {
        val transport = ScriptedTransport { request ->
            when (body(request).getString("action")) {
                "create" -> ScriptedTransport.json(200, """{"status":"created","challenge_id":"$room","revision":1}""")
                "cancel" -> ScriptedTransport.json(200, """{"error":"Challenge administration requires current moderation permission and MFA."}""")
                else -> ScriptedTransport.json(200, """{"status":"confirmed","revision":2}""")
            }
        }
        val client = ChallengeClient(CommunityGateway(FixedSession(), transport))
        assertEquals(room to 1, client.create(" Weekly ", "Brief", ""))
        val now = Instant.parse("2026-10-18T00:00:00Z")
        val draft = ChallengeScheduleDraft(now.plusSeconds(3600), now.plusSeconds(3 * 3600), now.plusSeconds(5 * 3600))
        assertEquals(2, client.schedule(room, 1, draft, now))
        val sent = body(transport.requests.last())
        assertEquals("2026-10-18T01:00:00Z", sent.getString("starts_at")); assertEquals(1, sent.getInt("revision"))
        try { client.cancel(room, 2, "Duplicate"); fail() } catch (e: CommunityException.Server) { assertTrue(e.message!!.contains("moderation")) }
        val sentCount = transport.requests.size
        try { client.cancel(room, 2, "  "); fail() } catch (_: CommunityException.Server) { }
        try { client.schedule(room, 2, draft.copy(endsAt = draft.closesAt), now); fail() } catch (_: CommunityException.Server) { }
        assertEquals(sentCount, transport.requests.size) // invalid input never reaches the server
        assertEquals("A challenge may last at most sixty days.", draft.copy(endsAt = now.plusSeconds(61L * 86400)).validation(now))
    }

    @Test fun calendarMonthIsBoundedDedupedAndPlacedInTheViewerZone() {
        val zone = ZoneId.of("America/New_York")
        val (start, end) = CalendarMonth.bounds(YearMonth.of(2026, 11), zone)
        assertEquals("2026-11-01T04:00:00Z", start.toInstant().toString()); assertEquals("2026-12-01T05:00:00Z", end.toInstant().toString())
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"items":[
            {"kind":"challenge","id":"$room","title":"C","occurs_at":"2026-11-02T03:30:00+00:00","milestone":"opens","status":"upcoming"},
            {"kind":"challenge","id":"$room","title":"C","occurs_at":"2026-11-02T03:30:00+00:00","milestone":"opens","status":"upcoming"},
            {"kind":"war_match","id":"${Fixtures.OTHER}","title":"M","occurs_at":"2026-12-05T00:00:00+00:00","milestone":"voting_ends","status":"active"}],"truncated":false}""") }
        val month = CalendarClient(CommunityGateway(FixedSession(), transport)).month(YearMonth.of(2026, 11), zone)
        val sent = body(transport.requests.single())
        assertEquals(start.toInstant().toString(), sent.getString("range_start"))
        assertEquals(1, month.items.size) // duplicate and out-of-range items dropped
        val (day, items) = month.days().single()
        assertEquals("2026-11-01", day.toString()) // 03:30 UTC is still 1 November in New York
        assertEquals("Submissions open", items.single().milestoneText)
    }

    @Test fun coordinatorBlocksSkipsAndCountsTruthfully() {
        val command = """{"revision":1,"op_id":"00000000-0000-4000-8000-000000000009","author":"${Fixtures.OTHER}","base_revision":0,"kind":"studio.apply","payload":{},"created_at":"t"}"""
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"commands":[$command],"head":1}""") }
        val coordinator = RoomSessionCoordinator(RoomCommandClient(CommunityGateway(FixedSession(), transport)))
        coordinator.begin(room, 0, canEdit = true, account = Fixtures.USER, projectID = project)
        coordinator.applyRemote = { record -> coordinator.noteRemoteBlocked(record, "not yet"); false }
        coordinator.catchUp()
        assertEquals("not yet", coordinator.blockedRemote!!.reason); assertEquals(1, coordinator.pendingRemoteCount)
        assertTrue(coordinator.skipBlockedRemote())
        assertEquals(0, coordinator.pendingRemoteCount); assertEquals(1, coordinator.skippedRemote.size); assertEquals(1, coordinator.head)
        coordinator.noteUnsharedLocalEdit("Undo")
        assertEquals(1, coordinator.unsharedLocalCount)
        assertFalse(coordinator.isSharing(project))
        assertTrue(coordinator.handOffToStudio(room, "R", project)); assertTrue(coordinator.isSharing(project))
        coordinator.end("done"); assertFalse(coordinator.isSharing(project)); assertEquals("done", coordinator.endReason)
    }
}
