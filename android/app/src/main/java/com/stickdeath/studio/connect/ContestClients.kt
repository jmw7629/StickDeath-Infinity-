package com.stickdeath.studio.connect

import org.json.JSONObject
import java.time.Instant
import java.time.OffsetDateTime

// Kotlin mirrors of the iOS WarRoomClient and ChallengeLifecycleClient over the same RPCs
// (backend/sql/war-room.sql, war-moderation.sql, war-appeals.sql, challenges.sql). War Room is a
// contest between two submitted, approved renditions; viewers cast one mutable, authenticated vote
// and the server alone finalises results. Nothing here invents opponents, viewers, tallies,
// winners or entries: every number shown comes from a server reply.

/** Postgres `timestamptz` JSON (`2026-10-14T12:00:00.123456+00:00` or `…Z`); null when absent or unreadable. */
internal fun serverInstant(raw: String?): Instant? = raw?.let { runCatching { OffsetDateTime.parse(it).toInstant() }.getOrNull() }

// MARK: War Room

enum class WarVoteChoice(val wire: String) { Left("left"), Right("right");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.wire == raw } }
}

data class WarMatch(
    val id: String, val creator: String, val opponent: String, val status: String, val endsAt: String?,
    val leftTitle: String, val leftUrl: String, val rightTitle: String?, val rightUrl: String?,
    val leftVotes: Int, val rightVotes: Int, val myVote: WarVoteChoice?, val outcome: String?,
) {
    val leftSafeUrl get() = CommunityGateway.checkedMediaUrl(leftUrl)
    val rightSafeUrl get() = CommunityGateway.checkedMediaUrl(rightUrl)
    companion object {
        fun parse(o: JSONObject): WarMatch {
            val left = o.int("left_votes"); val right = o.int("right_votes")
            if (left == null || right == null) throw CommunityException.InvalidResponse("The matchup reply was incomplete.")
            if (left < 0 || right < 0) throw CommunityException.InvalidResponse("The server reported a negative tally.")
            return WarMatch(requireUuidOr(o.need("id")), requireUuidOr(o.need("creator")), requireUuidOr(o.need("opponent")), o.need("status"),
                o.str("ends_at"), o.str("left_title").orEmpty(), o.need("left_url"), o.str("right_title"), o.str("right_url"),
                left, right, WarVoteChoice.of(o.str("my_vote")), o.str("outcome"))
        }
    }
}

/** What a matchup card may show for the signed-in account (iOS `WarMatchPresentation`). Results come
 * only from server fields: `completed` plus an `outcome`; an ended but unfinalised match says so. */
data class WarMatchPresentation(
    val phase: Phase, val heading: String, val resultText: String?, val canVote: Boolean, val canAccept: Boolean,
    val canWithdraw: Boolean, val showsTallies: Boolean, val isParticipant: Boolean,
) {
    enum class Phase { Proposal, AwaitingOpponent, Voting, AwaitingFinalisation, Final, Unavailable }
    companion object {
        fun of(match: WarMatch, viewer: String?, now: Instant): WarMatchPresentation {
            val me = viewer?.lowercase()
            val participant = me != null && (me == match.creator || me == match.opponent)
            val ended = serverInstant(match.endsAt)?.let { !it.isAfter(now) } ?: false
            return when {
                match.status == "pending" -> {
                    val mine = me == match.opponent
                    WarMatchPresentation(if (mine) Phase.Proposal else Phase.AwaitingOpponent,
                        if (mine) "You were invited to a matchup" else "Awaiting opponent consent", null,
                        canVote = false, canAccept = mine, canWithdraw = participant, showsTallies = false, isParticipant = participant)
                }
                match.status == "active" && !ended -> WarMatchPresentation(Phase.Voting,
                    if (participant) "Voting is open on your matchup" else "Choose your favorite", null,
                    canVote = me != null && !participant, canAccept = false, canWithdraw = participant, showsTallies = true, isParticipant = participant)
                match.status == "active" -> WarMatchPresentation(Phase.AwaitingFinalisation, "Voting closed — awaiting the server's final result", null,
                    canVote = false, canAccept = false, canWithdraw = false, showsTallies = true, isParticipant = participant)
                match.status == "completed" -> WarMatchPresentation(Phase.Final, "Final result", when (match.outcome) {
                    "tie" -> "Tie — no winner or loser"
                    "left" -> "Winner: ${match.leftTitle}"
                    "right" -> "Winner: ${match.rightTitle ?: "Second video"}"
                    else -> "Result not yet recorded by the server"
                }, canVote = false, canAccept = false, canWithdraw = false, showsTallies = true, isParticipant = participant)
                else -> WarMatchPresentation(Phase.Unavailable, "Matchup unavailable", null,
                    canVote = false, canAccept = false, canWithdraw = false, showsTallies = false, isParticipant = participant)
            }
        }
    }
}

/** One mutable vote per viewer (iOS `WarVoteMachine`). A tap stays pending until the server confirms;
 * a refused request keeps the server's last known vote and never implies a tally change. */
data class WarVoteMachine(val state: State) {
    sealed class State {
        object None : State()
        data class Pending(val choice: WarVoteChoice, val previous: WarVoteChoice?) : State()
        data class Confirmed(val choice: WarVoteChoice) : State()
        data class Failed(val message: String, val previous: WarVoteChoice?) : State()
    }
    val serverChoice: WarVoteChoice? get() = when (val s = state) {
        is State.Confirmed -> s.choice; is State.Failed -> s.previous; is State.Pending -> s.previous; State.None -> null
    }
    val isPending get() = state is State.Pending
    /** Null when a vote is already pending (double taps are ignored). */
    fun tap(choice: WarVoteChoice): WarVoteMachine? = if (isPending) null else WarVoteMachine(State.Pending(choice, serverChoice))
    fun confirm(): WarVoteMachine = (state as? State.Pending)?.let { WarVoteMachine(State.Confirmed(it.choice)) } ?: this
    fun fail(message: String): WarVoteMachine = WarVoteMachine(State.Failed(message, serverChoice))
    companion object { fun fromServer(raw: WarVoteChoice?) = WarVoteMachine(raw?.let { State.Confirmed(it) } ?: State.None) }
}

data class WarNotice(val id: String, val matchId: String, val message: String, val createdAt: String, val appealState: String?, val appealDeadline: String)

class WarRoomClient(private val gateway: CommunityGateway) {
    fun matches(): List<WarMatch> {
        val items = gateway.call("sdi_war_action", JSONObject().put("action", "list")).optJSONArray("matches")
            ?: throw CommunityException.InvalidResponse("Matchup list unavailable.")
        if (items.length() > 100) throw CommunityException.InvalidResponse("The server returned more matchups than allowed.")
        return items.objects().map(WarMatch::parse)
    }
    private fun confirmed(request: JSONObject) {
        if (gateway.call("sdi_war_action", request).str("status") != "confirmed") throw CommunityException.InvalidResponse("The operation was not confirmed.")
    }
    /** Proposal requires an explicit agreement to the visible rules; nothing is sent without it. */
    fun propose(media: String, opponent: String, agreed: Boolean) {
        if (!agreed) throw CommunityException.Server("Agree to the matchup rules before proposing.", null)
        confirmed(JSONObject().put("action", "propose").put("media", requireUuid(media)).put("opponent", requireUuid(opponent)))
    }
    fun accept(match: String, media: String, agreed: Boolean) {
        if (!agreed) throw CommunityException.Server("Agree to the matchup rules before accepting.", null)
        confirmed(JSONObject().put("action", "accept").put("match", requireUuid(match)).put("media", requireUuid(media)))
    }
    fun withdraw(match: String) = confirmed(JSONObject().put("action", "withdraw").put("match", requireUuid(match)))
    fun blockCreator(creator: String) = confirmed(JSONObject().put("action", "block").put("opponent", requireUuid(creator)))
    /** Returns only after the server confirms; the voter's identity is the JWT, never a parameter. */
    fun vote(match: String, choice: WarVoteChoice) = confirmed(JSONObject().put("action", "vote").put("match", requireUuid(match)).put("choice", choice.wire))
    fun report(match: String, reason: String) {
        val text = reason.trim()
        if (text.length !in 1..2000) throw CommunityException.Server("Describe the issue in up to 2000 characters.", null)
        if (gateway.call("sdi_war_report", JSONObject().put("match", requireUuid(match)).put("reason", text)).str("status") != "recorded") {
            throw CommunityException.InvalidResponse("Report was not confirmed.")
        }
    }
    fun notices(): List<WarNotice> {
        val items = gateway.call("sdi_war_notices", JSONObject().put("action", "list")).optJSONArray("notices")
            ?: throw CommunityException.InvalidResponse("Notices unavailable.")
        return items.objects().map { WarNotice(requireUuidOr(it.need("id")), requireUuidOr(it.need("match_id")), it.need("message"), it.need("created_at"), it.str("appeal_state"), it.need("appeal_deadline")) }
    }
    fun appeal(decision: String, explanation: String) {
        val text = explanation.trim()
        if (text.length !in 1..2000) throw CommunityException.Server("Explain the appeal in up to 2000 characters.", null)
        val reply = gateway.call("sdi_war_notices", JSONObject().put("action", "appeal").put("decision", requireUuid(decision)).put("explanation", text))
        if (reply.str("status") != "recorded") throw CommunityException.InvalidResponse("Appeal was not confirmed.")
    }
}

// MARK: Challenges

enum class ChallengePhase(val wire: String) { Draft("draft"), Upcoming("upcoming"), Active("active"), Voting("voting"), Completed("completed"), Cancelled("cancelled");
    val title get() = name
    companion object { fun of(raw: String?) = entries.firstOrNull { it.wire == raw } }
}

data class ChallengeSummary(
    val id: String, val title: String, val brief: String, val rewardText: String,
    val startsAt: String?, val submissionsCloseAt: String?, val votingEndsAt: String?,
    val revision: Int, val phase: String, val entryCount: Int, val myEntry: Boolean, val outcome: String?, val winnerEntry: String?,
) {
    /** Phase from the server clock anchor, so a wrong device clock still shows the server's phase. */
    fun phaseAt(serverNow: Instant): ChallengePhase {
        if (phase == "cancelled") return ChallengePhase.Cancelled
        val starts = serverInstant(startsAt); val closes = serverInstant(submissionsCloseAt); val ends = serverInstant(votingEndsAt)
        if (starts == null || closes == null || ends == null) return ChallengePhase.Draft
        return when { serverNow.isBefore(starts) -> ChallengePhase.Upcoming; serverNow.isBefore(closes) -> ChallengePhase.Active
            serverNow.isBefore(ends) -> ChallengePhase.Voting; else -> ChallengePhase.Completed }
    }
    val hasReward get() = rewardText.isNotBlank()
    val outcomeText: String? get() = when (outcome) {
        "winner" -> "Winner decided by viewer favourite"; "tie" -> "Tie — no winner recorded"
        "no_entries" -> "Completed without eligible entries"; else -> null
    }
}

data class ChallengeEntry(val id: String, val creator: String, val title: String, val url: String, val createdAt: String, val votes: Int?, val myVote: Boolean) {
    val safeUrl get() = CommunityGateway.checkedMediaUrl(url)
}

/** `server_time` from the list reply plus device time elapsed since it arrived (never negative). */
data class ChallengeClock(val serverTime: Instant, val receivedAtMillis: Long) {
    fun now(deviceNowMillis: Long): Instant = serverTime.plusMillis(maxOf(0L, deviceNowMillis - receivedAtMillis))
}
data class ChallengeListing(val challenges: List<ChallengeSummary>, val clock: ChallengeClock)
data class ChallengeEntries(val phase: ChallengePhase?, val entries: List<ChallengeEntry>)

class ChallengeClient(private val gateway: CommunityGateway) {
    fun list(nowMillis: Long = System.currentTimeMillis()): ChallengeListing {
        val reply = gateway.call("sdi_challenge_action", JSONObject().put("action", "list"))
        val items = reply.optJSONArray("challenges"); val serverTime = serverInstant(reply.str("server_time"))
        if (items == null || serverTime == null) throw CommunityException.InvalidResponse("Challenge list incomplete.")
        val challenges = items.objects().map { o ->
            val count = o.int("entry_count") ?: throw CommunityException.InvalidResponse("Challenge list incomplete.")
            if (count < 0) throw CommunityException.InvalidResponse("The server reported a negative entry count.")
            ChallengeSummary(requireUuidOr(o.need("id")), o.str("title").orEmpty(), o.str("brief").orEmpty(), o.str("reward_text").orEmpty(),
                o.str("starts_at"), o.str("submissions_close_at"), o.str("voting_ends_at"), o.int("revision") ?: 0, o.need("phase"),
                count, o.bool("my_entry") ?: false, o.str("outcome"), o.str("winner_entry"))
        }
        return ChallengeListing(challenges, ChallengeClock(serverTime, nowMillis))
    }
    fun entries(challenge: String): ChallengeEntries {
        val reply = gateway.call("sdi_challenge_action", JSONObject().put("action", "entries").put("challenge", requireUuid(challenge)))
        val items = reply.optJSONArray("entries") ?: throw CommunityException.InvalidResponse("Entries unavailable.")
        return ChallengeEntries(ChallengePhase.of(reply.str("phase")), items.objects().map { o ->
            val votes = o.int("votes")
            if (votes != null && votes < 0) throw CommunityException.InvalidResponse("The server reported a negative tally.")
            ChallengeEntry(requireUuidOr(o.need("id")), requireUuidOr(o.need("creator")), o.str("title").orEmpty(), o.need("url"), o.need("created_at"), votes, o.bool("my_vote") ?: false)
        })
    }
    private fun mutate(request: JSONObject, expecting: Set<String>) {
        val status = gateway.call("sdi_challenge_action", request).str("status")
        if (status == null || status !in expecting) throw CommunityException.InvalidResponse("The challenge operation was not confirmed.")
    }
    /** Submits the creator's own approved rendition; the server enforces phase, ownership, digest and one entry. */
    fun submit(challenge: String, media: String) = mutate(JSONObject().put("action", "submit").put("challenge", requireUuid(challenge)).put("media", requireUuid(media)), setOf("entered"))
    fun withdraw(entry: String) = mutate(JSONObject().put("action", "withdraw").put("entry", requireUuid(entry)), setOf("withdrawn"))
    fun vote(challenge: String, entry: String) = mutate(JSONObject().put("action", "vote").put("challenge", requireUuid(challenge)).put("entry", requireUuid(entry)), setOf("confirmed"))
}
