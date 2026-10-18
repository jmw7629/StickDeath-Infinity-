package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

class ContestClientsTest {
    private val match = "0aaaaaaa-1111-4222-8333-444444444444"
    private val media = "0bbbbbbb-1111-4222-8333-444444444444"
    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try { block() } catch (e: Throwable) { if (e is T) return e; throw e }
        fail("Expected ${T::class.simpleName}"); error("unreachable")
    }
    private fun body(request: HttpRequest) = JSONObject(String(request.body!!))
    private fun matchJson(status: String = "active", ends: String = "2026-10-20T00:00:00.123456+00:00", left: Int = 2, right: Int = 1, outcome: String? = null, myVote: String? = null) =
        """{"id":"$match","creator":"${Fixtures.USER}","opponent":"${Fixtures.OTHER}","status":"$status","ends_at":"$ends","left_title":"A","left_url":"https://m.example.test/a.mp4",
           "right_title":"B","right_url":"https://m.example.test/b.mp4","left_votes":$left,"right_votes":$right,"my_vote":${myVote?.let { "\"$it\"" } ?: "null"},"outcome":${outcome?.let { "\"$it\"" } ?: "null"}}"""

    @Test fun warListParsesServerTalliesAndRejectsNegativeOnes() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"matches":[${matchJson(myVote = "left")}]}""") }
        val matches = WarRoomClient(CommunityGateway(FixedSession(), transport)).matches()
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_war_action", transport.requests.single().url)
        assertEquals("""{"action":"list"}""", String(transport.requests.single().body!!))
        assertEquals(2, matches.single().leftVotes); assertEquals(WarVoteChoice.Left, matches.single().myVote)
        val negative = ScriptedTransport { ScriptedTransport.json(200, """{"matches":[${matchJson(left = -1)}]}""") }
        expect<CommunityException.InvalidResponse> { WarRoomClient(CommunityGateway(FixedSession(), negative)).matches() }
        val missing = ScriptedTransport { ScriptedTransport.json(200, """{"status":"confirmed"}""") }
        expect<CommunityException.InvalidResponse> { WarRoomClient(CommunityGateway(FixedSession(), missing)).matches() }
    }

    @Test fun voteSendsOnlyMatchAndChoiceAndNeedsConfirmation() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"status":"confirmed"}""") }
        WarRoomClient(CommunityGateway(FixedSession(), transport)).vote(match, WarVoteChoice.Right)
        val sent = body(transport.requests.single())
        assertEquals("vote", sent.getString("action")); assertEquals(match, sent.getString("match")); assertEquals("right", sent.getString("choice"))
        assertFalse(sent.has("voter")); assertEquals("Bearer member-token", transport.requests.single().headers["Authorization"])
        val refused = ScriptedTransport { ScriptedTransport.json(200, """{"error":"Voting is not available to this account."}""") }
        expect<CommunityException.Server> { WarRoomClient(CommunityGateway(FixedSession(), refused)).vote(match, WarVoteChoice.Left) }
        val signedOut = ScriptedTransport { fail("must not send"); error("unreachable") }
        expect<CommunityException.SignedOut> { WarRoomClient(CommunityGateway(FixedSession(token = null), signedOut)).vote(match, WarVoteChoice.Left) }
    }

    @Test fun proposalAndAcceptanceNeedExplicitAgreement() {
        val transport = ScriptedTransport { fail("must not send"); error("unreachable") }
        val client = WarRoomClient(CommunityGateway(FixedSession(), transport))
        expect<CommunityException.Server> { client.propose(media, Fixtures.OTHER, agreed = false) }
        expect<CommunityException.Server> { client.accept(match, media, agreed = false) }
        expect<CommunityException.Server> { client.report(match, "   ") }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun presentationNeverComputesAWinner() {
        val now = Instant.parse("2026-10-18T00:00:00Z")
        val active = WarMatch.parse(JSONObject(matchJson()))
        val viewer = WarMatchPresentation.of(active, "99999999-7777-4888-8999-aaaaaaaaaaaa", now)
        assertTrue(viewer.canVote); assertEquals(WarMatchPresentation.Phase.Voting, viewer.phase)
        val participant = WarMatchPresentation.of(active, Fixtures.USER, now)
        assertFalse(participant.canVote); assertTrue(participant.canWithdraw)
        assertFalse(WarMatchPresentation.of(active, null, now).canVote)
        val ended = WarMatchPresentation.of(active, Fixtures.USER, Instant.parse("2026-10-21T00:00:00Z"))
        assertEquals(WarMatchPresentation.Phase.AwaitingFinalisation, ended.phase); assertNull(ended.resultText)
        val completed = WarMatch.parse(JSONObject(matchJson(status = "completed")))
        assertEquals("Result not yet recorded by the server", WarMatchPresentation.of(completed, null, now).resultText)
        assertEquals("Winner: B", WarMatchPresentation.of(WarMatch.parse(JSONObject(matchJson(status = "completed", outcome = "right"))), null, now).resultText)
    }

    @Test fun voteMachineKeepsTheServerVoteOnFailure() {
        val start = WarVoteMachine.fromServer(WarVoteChoice.Left)
        val pending = start.tap(WarVoteChoice.Right)!!
        assertTrue(pending.isPending); assertEquals(WarVoteChoice.Left, pending.serverChoice)
        assertNull(pending.tap(WarVoteChoice.Left))
        assertEquals(WarVoteChoice.Left, pending.fail("no").serverChoice)
        assertEquals(WarVoteChoice.Right, pending.confirm().serverChoice)
    }

    @Test fun challengesUseTheServerClockAndHideVotesUntilVoting() {
        val challenge = "0ccccccc-1111-4222-8333-444444444444"
        val list = """{"challenges":[{"id":"$challenge","title":"Jump","brief":"b","reward_text":"","starts_at":"2026-10-01T00:00:00+00:00",
            "submissions_close_at":"2026-10-10T00:00:00+00:00","voting_ends_at":"2026-10-20T00:00:00+00:00","revision":3,"phase":"scheduled",
            "entry_count":4,"my_entry":false,"outcome":null,"winner_entry":null}],"server_time":"2026-10-12T00:00:00.5+00:00"}"""
        val transport = ScriptedTransport { ScriptedTransport.json(200, list) }
        val listing = ChallengeClient(CommunityGateway(FixedSession(), transport)).list(nowMillis = 1_000)
        // Device clock is irrelevant: server time plus elapsed device time decides the phase.
        assertEquals(ChallengePhase.Voting, listing.challenges.single().phaseAt(listing.clock.now(2_000)))
        assertEquals(ChallengePhase.Completed, listing.challenges.single().phaseAt(listing.clock.now(1_000 + 9L * 24 * 3600 * 1000)))
        val negative = ScriptedTransport { ScriptedTransport.json(200, list.replace("\"entry_count\":4", "\"entry_count\":-1")) }
        expect<CommunityException.InvalidResponse> { ChallengeClient(CommunityGateway(FixedSession(), negative)).list() }
        val noClock = ScriptedTransport { ScriptedTransport.json(200, """{"challenges":[]}""") }
        expect<CommunityException.InvalidResponse> { ChallengeClient(CommunityGateway(FixedSession(), noClock)).list() }
        val entries = ScriptedTransport { ScriptedTransport.json(200, """{"phase":"active","entries":[{"id":"$media","creator":"${Fixtures.OTHER}","title":"E","url":"https://m.example.test/e.mp4","created_at":"2026-10-02T00:00:00+00:00","votes":null,"my_vote":false}]}""") }
        val result = ChallengeClient(CommunityGateway(FixedSession(), entries)).entries(challenge)
        assertEquals(ChallengePhase.Active, result.phase); assertNull(result.entries.single().votes)
    }

    @Test fun challengeMutationsNeedTheExpectedStatus() {
        val challenge = "0ccccccc-1111-4222-8333-444444444444"
        val ok = ScriptedTransport { ScriptedTransport.json(200, """{"status":"entered"}""") }
        ChallengeClient(CommunityGateway(FixedSession(), ok)).submit(challenge, media)
        val sent = body(ok.requests.single())
        assertEquals("submit", sent.getString("action")); assertEquals(media, sent.getString("media")); assertFalse(sent.has("entry"))
        val wrong = ScriptedTransport { ScriptedTransport.json(200, """{"status":"confirmed"}""") }
        expect<CommunityException.InvalidResponse> { ChallengeClient(CommunityGateway(FixedSession(), wrong)).submit(challenge, media) }
        expect<IllegalArgumentException> { ChallengeClient(CommunityGateway(FixedSession(), ok)).vote("not-a-uuid", media) }
    }

    @Test fun everyNewClientRpcIsInTheBackendContract() {
        val names = mutableSetOf<String>()
        val transport = ScriptedTransport { request -> names += request.url.substringAfterLast("/"); ScriptedTransport.json(200, "{}") }
        val gateway = CommunityGateway(FixedSession(), transport)
        runCatching { WarRoomClient(gateway).matches() }
        runCatching { WarRoomClient(gateway).report(match, "spam") }
        runCatching { WarRoomClient(gateway).notices() }
        runCatching { ChallengeClient(gateway).list() }
        runCatching { AccountLifecycleClient(gateway).status() }
        runCatching { NotificationsClient(gateway).inbox() }
        runCatching { RoomCommandClient(gateway).commands(RoomCommandRequest("since", match)) }
        assertEquals(setOf("sdi_war_action", "sdi_war_report", "sdi_war_notices", "sdi_challenge_action", "sdi_account_lifecycle", "sdi_notify_action", "sdi_room_command"), names)
        assertTrue(com.stickdeath.studio.BackendContract.rpcs.map { it.name }.toSet().containsAll(names))
    }
}
