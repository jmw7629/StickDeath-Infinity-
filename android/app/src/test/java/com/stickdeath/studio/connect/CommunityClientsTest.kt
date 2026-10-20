package com.stickdeath.studio.connect

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CommunityClientsTest {
    private val code = "a".repeat(64)
    private val cursor = "0|2026-10-01T00:00:00.000000Z|${Fixtures.OTHER}"
    private inline fun <reified T : Throwable> expect(block: () -> Unit): T {
        try { block() } catch (e: Throwable) { if (e is T) return e; throw e }
        fail("Expected ${T::class.simpleName}"); error("unreachable")
    }
    private fun body(request: HttpRequest) = JSONObject(String(request.body!!))
    private fun post(id: String = Fixtures.OTHER, likes: Int = 3) =
        """{"id":"$id","creator":"${Fixtures.USER}","creator_name":"Ink","caption":"c","published_at":"2026-10-01T00:00:00Z","allow_export":false,"title":"Fight","url":"https://media.example.test/v.mp4","likes":$likes,"liked":false,"following":false}"""

    @Test fun rpcUsesTheMemberJwtAndOmitsNulls() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"posts":[${post()}],"has_more":true,"next_cursor":"$cursor","as_of":"2026-10-14T00:00:00Z"}""") }
        val page = FeedClient(CommunityGateway(FixedSession(), transport)).page(FeedCategory.Trending)
        val request = transport.requests.single()
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_feed_page", request.url)
        assertEquals("Bearer member-token", request.headers["Authorization"])
        assertEquals(Fixtures.KEY, request.headers["apikey"])
        val sent = body(request)
        assertEquals("trending", sent.getString("category"))
        assertFalse(sent.has("as_of")); assertFalse(sent.has("page_cursor")); assertFalse(sent.has("page")); assertFalse(sent.has("offset"))
        assertEquals(1, page.posts.size); assertTrue(page.hasMore); assertEquals("2026-10-14T00:00:00Z", page.asOf); assertEquals(cursor, page.cursor)
        assertEquals(3, page.posts[0].likes)
    }

    @Test fun laterPagesSendTheCursorAndSnapshotAndBoundsAreEnforced() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"posts":[],"has_more":false,"next_cursor":null}""") }
        val feed = FeedClient(CommunityGateway(FixedSession(), transport))
        val last = feed.page(FeedCategory.Recent, cursor, "snap")
        assertFalse(last.hasMore); assertNull(last.cursor)
        val sent = body(transport.requests.single())
        assertEquals(cursor, sent.getString("page_cursor")); assertEquals("snap", sent.getString("as_of")); assertFalse(sent.has("page"))
        expect<CommunityException.Stale> { feed.page(FeedCategory.Recent, cursor, null) }
        expect<CommunityException.Stale> { feed.page(FeedCategory.Recent, "x".repeat(121), "snap") }
        assertEquals(1, transport.requests.size)
        val noCursor = ScriptedTransport { ScriptedTransport.json(200, """{"posts":[],"has_more":true}""") }
        expect<CommunityException.InvalidResponse> { FeedClient(CommunityGateway(FixedSession(), noCursor)).page(FeedCategory.Recent) }
        val oversized = ScriptedTransport { ScriptedTransport.json(200, """{"posts":[${(1..26).joinToString(",") { post() }}],"has_more":false}""") }
        expect<CommunityException.InvalidResponse> { FeedClient(CommunityGateway(FixedSession(), oversized)).page(FeedCategory.Recent) }
        val incomplete = ScriptedTransport { ScriptedTransport.json(200, """{"posts":[{"id":"${Fixtures.OTHER}"}],"has_more":false}""") }
        expect<CommunityException.InvalidResponse> { FeedClient(CommunityGateway(FixedSession(), incomplete)).page(FeedCategory.Recent) }
    }

    @Test fun postersAreRecordedUrlsOrPlaceholdersAndLoadOnlyCompleteBoundedJpegs() {
        val withPoster = post().dropLast(1) + ""","poster_url":"https://media.example.test/v.poster.jpg"}"""
        val reply = """{"posts":[$withPoster,${post(Fixtures.USER)}],"has_more":false}"""
        val page = FeedClient(CommunityGateway(FixedSession(), ScriptedTransport { ScriptedTransport.json(200, reply) })).page(FeedCategory.Recent)
        assertEquals("https://media.example.test/v.poster.jpg", page.posts[0].safePosterUrl)
        assertNull(page.posts[1].safePosterUrl)
        assertNull(page.posts[0].copy(posterUrl = "http://media.example.test/p.jpg").safePosterUrl)
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 1, 2, 0xFF.toByte(), 0xD9.toByte())
        val images = ScriptedTransport { request -> HttpResponse(200, if (request.url.endsWith("v.poster.jpg")) jpeg else byteArrayOf(1, 2, 3, 4, 5, 6)) }
        val loader = FeedPosterLoader(images)
        assertTrue(loader.load(page.posts[0])!!.contentEquals(jpeg))
        assertTrue(loader.load(page.posts[0])!!.contentEquals(jpeg))
        assertEquals(1, images.requests.size) // cached
        assertTrue(images.requests.single().headers.isEmpty()) // no account credentials on media
        assertNull(loader.load(page.posts[1])) // nothing recorded: placeholder, no request
        assertNull(loader.load(page.posts[0].copy(posterUrl = "https://media.example.test/broken.jpg")))
        assertFalse(FeedPosterLoader.isCompleteJpeg(ByteArray(FeedPosterLoader.MAXIMUM_POSTER_BYTES + 1) { if (it < 3) jpeg[it] else 0 }))
    }

    @Test fun serverErrorsAndHttpFailuresAreMapped() {
        val server = ScriptedTransport { ScriptedTransport.json(200, """{"error":"Slow down.","code":"rate_limited"}""") }
        assertTrue(expect<CommunityException.Server> { FeedClient(CommunityGateway(FixedSession(), server)).like(Fixtures.OTHER, true) }.isRateLimited)
        val denied = ScriptedTransport { ScriptedTransport.json(401, """{"message":"JWT expired"}""") }
        expect<CommunityException.SignedOut> { FeedClient(CommunityGateway(FixedSession(), denied)).like(Fixtures.OTHER, true) }
        val failing = ScriptedTransport { ScriptedTransport.json(500, """{"message":"internal detail"}""") }
        val error = expect<CommunityException.Transport> { FeedClient(CommunityGateway(FixedSession(), failing)).like(Fixtures.OTHER, true) }
        assertFalse(error.message!!.contains("internal detail"))
        expect<CommunityException.Transport> { FeedClient(CommunityGateway(FixedSession(), ScriptedTransport.offline())).like(Fixtures.OTHER, true) }
        val huge = ScriptedTransport { ScriptedTransport.json(200, "{\"pad\":\"" + "x".repeat(CommunityGateway.MAXIMUM_BODY_BYTES) + "\"}") }
        expect<CommunityException.InvalidResponse> { FeedClient(CommunityGateway(FixedSession(), huge)).like(Fixtures.OTHER, true) }
    }

    @Test fun nothingIsSentWithoutConfigurationOrSession() {
        val transport = ScriptedTransport { fail("must not send"); error("unreachable") }
        expect<CommunityException.NotConfigured> { FeedClient(CommunityGateway(FixedSession(configured = null), transport)).page(FeedCategory.Recent) }
        expect<CommunityException.SignedOut> { FeedClient(CommunityGateway(FixedSession(token = null), transport)).page(FeedCategory.Recent) }
        assertTrue(transport.requests.isEmpty())
    }

    @Test fun replyForAnEarlierAccountIsStale() {
        val session = FixedSession()
        val transport = ScriptedTransport { session.generation++; ScriptedTransport.json(200, """{"status":"confirmed"}""") }
        expect<CommunityException.Stale> { FeedClient(CommunityGateway(session, transport)).follow(Fixtures.USER, true) }
    }

    @Test fun likeIsConfirmedOnlyByTheServer() {
        val transport = ScriptedTransport { ScriptedTransport.json(200, """{"status":"unchanged"}""") }
        assertFalse(FeedClient(CommunityGateway(FixedSession(), transport)).like(Fixtures.OTHER, true))
        val sent = body(transport.requests.single())
        assertEquals("like", sent.getString("action")); assertEquals(Fixtures.OTHER, sent.getString("post_id")); assertTrue(sent.getBoolean("enabled"))
    }

    @Test fun profileRecordsRequireCompleteOwnReplies() {
        val complete = """{"show_records":false,"show_badges":true,"revision":4,"wins":2,"losses":1,"ties":0,"badges":[]}"""
        val transport = ScriptedTransport { ScriptedTransport.json(200, complete) }
        val profile = ProfileClient(CommunityGateway(FixedSession(), transport))
        assertEquals(2, profile.readRecords().wins)
        expect<CommunityException.InvalidResponse> { profile.saveRecords(4, showRecords = true, showBadges = true) }
        assertEquals("save", body(transport.requests.last()).getString("action"))
        val hidden = ProfileClient(CommunityGateway(FixedSession(), ScriptedTransport { ScriptedTransport.json(200, """{"show_records":false}""") }))
        assertNull(hidden.readRecords(Fixtures.OTHER).wins)
        expect<CommunityException.InvalidResponse> { hidden.readRecords() }
    }

    @Test fun portfolioFiltersUnsafeAndUnapprovedRows() {
        val rows = """[{"id":"1","title":"b","url":"https://m.example.test/1.mp4","approved":true},
            {"id":"2","title":"a","url":"http://m.example.test/2.mp4","approved":true},
            {"id":"3","title":"c","url":"https://m.example.test/3.mp4","approved":false}]"""
        val transport = ScriptedTransport { ScriptedTransport.json(200, rows) }
        val items = ProfileClient(CommunityGateway(FixedSession(), transport)).portfolio(Fixtures.USER)
        assertEquals(listOf("1"), items.map { it.id })
        val url = transport.requests.single().url
        assertTrue(url.startsWith("${Fixtures.URL}/rest/v1/sdi_watch_media?select="))
        assertTrue(url.contains("owner_id=eq.${Fixtures.USER}")); assertTrue(url.endsWith("limit=100"))
        assertEquals("GET", transport.requests.single().method)
    }

    @Test fun roomJoinNeedsAWellFormedCodeAndExplicitConsent() {
        val transport = ScriptedTransport { request ->
            when (body(request).getString("action")) {
                "preview" -> ScriptedTransport.json(200, """{"status":"preview","room_id":"${Fixtures.OTHER}","title":"Duel"}""")
                "request" -> ScriptedTransport.json(200, """{"status":"pending_owner_approval","room_id":"${Fixtures.OTHER}"}""")
                else -> ScriptedTransport.json(200, """{"error":"unexpected"}""")
            }
        }
        val rooms = RoomsClient(CommunityGateway(FixedSession(), transport))
        expect<CommunityException.Server> { rooms.previewInvitation("not-a-code") }
        expect<CommunityException.Server> { rooms.requestAdmission(code, consent = false) }
        assertTrue(transport.requests.isEmpty())
        assertEquals(InvitationPreview(Fixtures.OTHER, "Duel"), rooms.previewInvitation("  ${code.uppercase()} "))
        assertEquals(AdmissionOutcome.PendingOwnerApproval(Fixtures.OTHER), rooms.requestAdmission(code, consent = true))
        val sent = body(transport.requests.last())
        assertEquals("${Fixtures.URL}/rest/v1/rpc/sdi_room_action", transport.requests.last().url)
        assertEquals(code, sent.getString("code")); assertTrue(sent.getBoolean("consent"))
        assertFalse(body(transport.requests.first()).getBoolean("consent"))
    }

    @Test fun mintedInvitationMustBeWellFormed() {
        val bad = RoomsClient(CommunityGateway(FixedSession(), ScriptedTransport { ScriptedTransport.json(200, """{"status":"invitation_created","code":"short"}""") }))
        expect<CommunityException.InvalidResponse> { bad.mintInvitation(Fixtures.OTHER) }
        val good = RoomsClient(CommunityGateway(FixedSession(), ScriptedTransport { ScriptedTransport.json(200, """{"status":"invitation_created","code":"$code"}""") }))
        assertEquals(code, good.mintInvitation(Fixtures.OTHER))
        assertTrue(RoomInvitationPolicy.shareText(code, "Duel").contains("owner still approves"))
    }

    @Test fun myRoomsHidesClosedRooms() {
        val rows = """[{"id":"${Fixtures.OTHER}","owner_id":"${Fixtures.USER}","title":"Open","permissions":["view","edit"]},
            {"id":"${Fixtures.USER}","owner_id":"${Fixtures.USER}","title":"Closed","closed":true}]"""
        val rooms = RoomsClient(CommunityGateway(FixedSession(), ScriptedTransport { ScriptedTransport.json(200, rows) })).myRooms()
        assertEquals(listOf("Open"), rooms.map { it.title }); assertTrue(rooms[0].sharesEdit)
    }

    @Test fun everyClientRpcIsInTheBackendContract() {
        val names = mutableSetOf<String>()
        val transport = ScriptedTransport { request -> names += request.url.substringAfterLast("/").substringBefore("?"); ScriptedTransport.json(200, "{}") }
        val gateway = CommunityGateway(FixedSession(), transport)
        runCatching { FeedClient(gateway).page(FeedCategory.Recent) }
        runCatching { ProfileClient(gateway).readRecords() }
        runCatching { ProfileClient(gateway).achievements() }
        runCatching { ProfileClient(gateway).setExportPermission(Fixtures.OTHER, 1, true) }
        runCatching { RoomsClient(gateway).pendingRequests() }
        runCatching { RoomsClient(gateway).leave(Fixtures.OTHER) }
        val contract = com.stickdeath.studio.BackendContract.rpcs.map { it.name }.toSet()
        assertEquals(setOf("sdi_feed_page", "sdi_profile_records", "sdi_achievement_catalog", "sdi_export_consent", "sdi_room_manage", "sdi_room_action"), names)
        assertTrue(contract.containsAll(names))
        names.forEach { name -> listOf("chat", "message", "call", "voice").forEach { assertFalse(name, name.contains(it)) } }
    }
}
