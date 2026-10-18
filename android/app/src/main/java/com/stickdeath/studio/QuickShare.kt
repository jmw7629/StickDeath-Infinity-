package com.stickdeath.studio

/** Six configurable quick-share shortcuts for the Export panel (#242), mirroring iOS
 * `StudioQuickShareDestinations.swift`. Android sends the freshly rendered file with a plain
 * `ACTION_SEND` intent addressed to the destination app's package; when that app is not installed
 * (or refuses the file type) the system chooser opens instead. Nothing here posts, uploads or reports
 * delivery: Android only says that an app received the intent, never whether a post went live. Direct
 * provider APIs stay unavailable until the owner supplies their developer credentials and terms. */
enum class QuickShareFile(val label: String) { MP4("MP4"), GIF("GIF"), PNG("PNG");
    val exportKind get() = when (this) { MP4 -> ExportKind.MP4; GIF -> ExportKind.GIF; PNG -> ExportKind.PNG }
}

enum class QuickShareDestination(val wire: String, val title: String, val accepted: List<QuickShareFile>, val packages: List<String>) {
    YouTube("youtube", "YouTube", listOf(QuickShareFile.MP4), listOf("com.google.android.youtube")),
    Instagram("instagram", "Instagram", listOf(QuickShareFile.MP4, QuickShareFile.PNG), listOf("com.instagram.android")),
    TikTok("tiktok", "TikTok", listOf(QuickShareFile.MP4), listOf("com.zhiliaoapp.musically", "com.ss.android.ugc.trill")),
    Facebook("facebook", "Facebook", listOf(QuickShareFile.MP4, QuickShareFile.PNG), listOf("com.facebook.katana")),
    X("x", "X", listOf(QuickShareFile.MP4, QuickShareFile.GIF, QuickShareFile.PNG), listOf("com.twitter.android")),
    Reddit("reddit", "Reddit", listOf(QuickShareFile.MP4, QuickShareFile.GIF, QuickShareFile.PNG), listOf("com.reddit.frontpage")),
    Threads("threads", "Threads", listOf(QuickShareFile.MP4, QuickShareFile.PNG), listOf("com.instagram.barcelona")),
    Pinterest("pinterest", "Pinterest", listOf(QuickShareFile.PNG, QuickShareFile.MP4), listOf("com.pinterest")),
    /** Saves through the system document picker (no third-party app). */
    Files("files", "Files", listOf(QuickShareFile.MP4, QuickShareFile.GIF, QuickShareFile.PNG), emptyList()),
    Photos("photos", "Google Photos", listOf(QuickShareFile.MP4, QuickShareFile.GIF, QuickShareFile.PNG), listOf("com.google.android.apps.photos"));

    val isThirdPartyApp get() = packages.isNotEmpty() && this != Photos
    companion object { fun of(raw: String) = entries.firstOrNull { it.wire == raw } }
}

data class QuickShareConfiguration(val slots: List<QuickShareDestination> = DEFAULT_SLOTS, val preferredFiles: Map<QuickShareDestination, QuickShareFile> = emptyMap()) {
    init {
        require(slots.size == SLOT_COUNT && slots.toSet().size == SLOT_COUNT) { "Six distinct quick-share destinations are required." }
        require(preferredFiles.all { (destination, file) -> file in destination.accepted }) { "A destination was given a file it does not accept." }
    }
    /** Puts [destination] in [slot]; one already pinned elsewhere swaps places so the six stay distinct. */
    fun assign(destination: QuickShareDestination, slot: Int): QuickShareConfiguration {
        if (slot !in slots.indices || slots[slot] == destination) return this
        val next = slots.toMutableList()
        val existing = next.indexOf(destination)
        if (existing >= 0) { next[existing] = next[slot] }
        next[slot] = destination
        return copy(slots = next)
    }
    /** Ignores a file kind the destination does not accept. */
    fun preferring(file: QuickShareFile, destination: QuickShareDestination) =
        if (file in destination.accepted) copy(preferredFiles = preferredFiles + (destination to file)) else this
    fun file(destination: QuickShareDestination) = preferredFiles[destination] ?: destination.accepted.first()

    /** `v=1;slots=a,b,…;file.<dest>=<FILE>;` — stable across releases. */
    fun serialize(): String = buildString {
        append("v=1;slots=").append(slots.joinToString(",") { it.wire }).append(';')
        preferredFiles.entries.sortedBy { it.key.ordinal }.forEach { (d, f) -> append("file.").append(d.wire).append('=').append(f.name).append(';') }
    }

    /** What a tap does: the rendered file kind and the honest note shown with it. */
    fun instruction(destination: QuickShareDestination): String {
        val file = file(destination)
        return when {
            destination == QuickShareDestination.Files -> "Renders the ${file.label} and opens the system save picker."
            else -> "Renders the ${file.label} and hands it to ${destination.title}. If ${destination.title} is not installed or refuses the file, the system share sheet opens instead. Studio does not post for you and cannot confirm a post."
        }
    }

    companion object {
        const val SLOT_COUNT = 6
        val DEFAULT_SLOTS = listOf(QuickShareDestination.YouTube, QuickShareDestination.Instagram, QuickShareDestination.TikTok,
            QuickShareDestination.Facebook, QuickShareDestination.X, QuickShareDestination.Reddit)
        /** Malformed, duplicated or unknown stored values fall back to the default set (iOS rule). */
        fun parse(text: String?): QuickShareConfiguration {
            if (text.isNullOrBlank() || text.length > 1024) return QuickShareConfiguration()
            val fields = text.split(';').filter { it.isNotEmpty() }.mapNotNull { field ->
                val index = field.indexOf('='); if (index <= 0) null else field.substring(0, index) to field.substring(index + 1)
            }.toMap()
            if (fields["v"] != "1") return QuickShareConfiguration()
            val slots = fields["slots"]?.split(',')?.map { QuickShareDestination.of(it) }
            val validSlots = slots?.takeIf { list -> list.size == SLOT_COUNT && list.all { it != null } && list.toSet().size == SLOT_COUNT }?.map { it!! } ?: DEFAULT_SLOTS
            val files = fields.filterKeys { it.startsWith("file.") }.mapNotNull { (key, value) ->
                val destination = QuickShareDestination.of(key.removePrefix("file.")) ?: return@mapNotNull null
                val file = QuickShareFile.entries.firstOrNull { it.name == value } ?: return@mapNotNull null
                if (file in destination.accepted) destination to file else null
            }.toMap()
            return QuickShareConfiguration(validSlots, files)
        }
    }
}
