package com.stickdeath.studio.connect

/** Main-thread owner of one outstanding server mutation per post. A stale completion cannot
 * release a newer operation or roll its card back. Account/category refreshes reconcile from
 * the server instead of applying a captured card over a newer page. */
internal class FeedLikeMutations {
    data class Mutation internal constructor(
        val serial: Long, val original: FeedPost, val optimistic: FeedPost,
        val generation: Long, val request: Int,
    )
    sealed class Completion {
        object Stale : Completion()
        object Refresh : Completion()
        object Confirmed : Completion()
        data class Rollback(val original: FeedPost) : Completion()
    }
    private var serial = 0L
    private val pending = mutableMapOf<String, Mutation>()
    val pendingIds: Set<String> get() = pending.keys.toSet()

    fun begin(post: FeedPost, generation: Long, request: Int): Mutation? {
        if (pending.containsKey(post.id)) return null
        val count = (post.likes.toLong() + if (post.liked) -1 else 1).coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
        return Mutation(++serial, post, post.copy(liked = !post.liked, likes = count), generation, request)
            .also { pending[post.id] = it }
    }

    fun finish(mutation: Mutation, generation: Long, request: Int, latest: FeedPost?, confirmed: Boolean): Completion {
        if (pending[mutation.original.id] !== mutation) return Completion.Stale
        pending.remove(mutation.original.id)
        if (generation != mutation.generation) return Completion.Stale
        // A new query may have read before the mutation reached the server; fetch again after
        // its result, whether confirmed or failed. Never restore a card from that old page.
        if (request != mutation.request || latest != mutation.optimistic) return Completion.Refresh
        return if (confirmed) Completion.Confirmed else Completion.Rollback(mutation.original)
    }
}
