package com.stickdeath.studio.connect

import org.junit.Assert.*
import org.junit.Test

class FeedLikeMutationsTest {
    private fun post(id: String = "post", liked: Boolean = false, likes: Int = 8) =
        FeedPost(id, "creator", "Artist", "", "2026-11-03", false, "Film", "https://example.invalid/video", likes, liked, false)

    @Test fun repeatedTapCannotIssueReversedRequestsAndConfirmedUnlikeStartsFromLatestCard() {
        val owner = FeedLikeMutations()
        val first = owner.begin(post(), 2, 10)!!
        assertTrue(first.optimistic.liked)
        assertEquals(9, first.optimistic.likes)
        assertNull(owner.begin(first.optimistic, 2, 10))
        assertEquals(setOf("post"), owner.pendingIds)
        assertSame(FeedLikeMutations.Completion.Confirmed, owner.finish(first, 2, 10, first.optimistic, true))
        val second = owner.begin(first.optimistic, 2, 10)!!
        assertFalse(second.optimistic.liked)
        assertEquals(8, second.optimistic.likes)
        // Even an accidental duplicate first completion cannot unlock the second request.
        assertSame(FeedLikeMutations.Completion.Stale, owner.finish(first, 2, 10, second.optimistic, false))
        assertNull(owner.begin(second.optimistic, 2, 10))
        assertSame(FeedLikeMutations.Completion.Confirmed, owner.finish(second, 2, 10, second.optimistic, true))
        assertTrue(owner.pendingIds.isEmpty())
    }

    @Test fun failureRollsBackOnlyItsOwnOptimisticCardAndAllowsRetry() {
        val owner = FeedLikeMutations(); val original = post()
        val mutation = owner.begin(original, 1, 3)!!
        assertEquals(FeedLikeMutations.Completion.Rollback(original), owner.finish(mutation, 1, 3, mutation.optimistic, false))
        assertNotNull(owner.begin(original, 1, 3))
    }

    @Test fun refreshOrChangedCardRequiresServerReconciliationInsteadOfStaleRollback() {
        for (confirmed in listOf(false, true)) {
            val owner = FeedLikeMutations(); val mutation = owner.begin(post(), 1, 3)!!
            assertSame(FeedLikeMutations.Completion.Refresh, owner.finish(mutation, 1, 4, post(likes = 99), confirmed))
            val next = owner.begin(post(), 1, 4)!!
            assertSame(FeedLikeMutations.Completion.Refresh, owner.finish(next, 1, 4, next.optimistic.copy(caption = "New caption"), confirmed))
        }
    }

    @Test fun oldAccountReplyCannotChangeCardsButOtherPostsCanProceedIndependently() {
        val owner = FeedLikeMutations()
        val a = owner.begin(post(), 1, 3)!!
        val b = owner.begin(post("other"), 1, 3)!!
        assertSame(FeedLikeMutations.Completion.Stale, owner.finish(a, 2, 3, a.optimistic, false))
        assertEquals(setOf("other"), owner.pendingIds)
        assertSame(FeedLikeMutations.Completion.Stale, owner.finish(b, 2, 3, b.optimistic, true))
        assertTrue(owner.pendingIds.isEmpty())
    }

    @Test fun countBoundsDoNotWrapOrBecomeNegative() {
        val owner = FeedLikeMutations()
        assertEquals(Int.MAX_VALUE, owner.begin(post("max", likes = Int.MAX_VALUE), 1, 1)!!.optimistic.likes)
        assertEquals(0, owner.begin(post("min", liked = true, likes = 0), 1, 1)!!.optimistic.likes)
    }
}
