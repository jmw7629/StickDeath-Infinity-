package com.stickdeath.studio

/** Local notification preference model (#290, Android half). No push transport exists on Android
 * yet: there is no FCM dependency, no `POST_NOTIFICATIONS` request and nothing is sent. The
 * preferences are stored so that, when the owner configures a provider, delivery honours choices
 * the creator already made. Pure Kotlin apart from the thin store at the bottom. */
enum class NotificationKind(val label: String) { Transactional("Account and safety"), Product("Studio and community"), Marketing("Announcements") }

enum class NotificationCategory(val label: String, val kind: NotificationKind, val defaultEnabled: Boolean, val canDisable: Boolean) {
    SecurityAndAccount("Sign-in, security and account changes", NotificationKind.Transactional, true, false),
    BillingReceipts("Subscription receipts and renewals", NotificationKind.Transactional, true, false),
    ModerationDecisions("Moderation and appeal decisions", NotificationKind.Transactional, true, false),
    RoomInvitations("Room invitations and approvals", NotificationKind.Product, true, true),
    WarRoomResults("War Room matches and results", NotificationKind.Product, true, true),
    ChallengeReminders("Challenge phases and reminders", NotificationKind.Product, true, true),
    ReviewOutcomes("Render review outcomes", NotificationKind.Product, true, true),
    Announcements("Product announcements", NotificationKind.Marketing, false, true)
}

data class NotificationDecision(val deliver: Boolean, val reason: String)

data class NotificationPreferences(
    val enabled: Map<NotificationCategory, Boolean> = NotificationCategory.entries.associateWith { it.defaultEnabled },
    /** Quiet hours in minutes of day, inclusive start, exclusive end; may wrap past midnight. */
    val quietStartMinute: Int? = null,
    val quietEndMinute: Int? = null,
    /** Product + marketing notices per day; transactional notices are never capped. */
    val dailyCap: Int = DEFAULT_DAILY_CAP
) {
    fun isEnabled(category: NotificationCategory) = if (!category.canDisable) true else enabled[category] ?: category.defaultEnabled
    fun setting(category: NotificationCategory, value: Boolean): NotificationPreferences {
        require(category.canDisable || value) { "${category.label} cannot be turned off; it is required for account safety." }
        return copy(enabled = enabled + (category to value))
    }
    fun validate() {
        require(dailyCap in 1..50) { "Daily cap must be 1–50." }
        require((quietStartMinute == null) == (quietEndMinute == null)) { "Quiet hours need both a start and an end." }
        quietStartMinute?.let { require(it in 0..1439 && quietEndMinute!! in 0..1439 && it != quietEndMinute) { "Quiet hours must be two different times of day." } }
    }
    fun inQuietHours(minuteOfDay: Int): Boolean {
        val start = quietStartMinute ?: return false; val end = quietEndMinute ?: return false
        require(minuteOfDay in 0..1439)
        return if (start < end) minuteOfDay in start until end else minuteOfDay >= start || minuteOfDay < end
    }
    /** The delivery rule a future transport must apply; transactional notices bypass quiet hours and caps. */
    fun shouldDeliver(category: NotificationCategory, minuteOfDay: Int, deliveredTodayNonTransactional: Int): NotificationDecision {
        validate()
        if (!isEnabled(category)) return NotificationDecision(false, "${category.label} is turned off.")
        if (category.kind == NotificationKind.Transactional) return NotificationDecision(true, "Transactional notices are always delivered.")
        if (inQuietHours(minuteOfDay)) return NotificationDecision(false, "Quiet hours are active; hold until they end.")
        if (deliveredTodayNonTransactional >= dailyCap) return NotificationDecision(false, "Daily cap of $dailyCap reached.")
        return NotificationDecision(true, "Within preferences.")
    }
    /** `key=value;` text, stable across releases; unknown categories are ignored on read. */
    fun serialize(): String = buildString {
        append("v=1;")
        NotificationCategory.entries.forEach { append(it.name).append('=').append(if (isEnabled(it)) '1' else '0').append(';') }
        append("cap=").append(dailyCap).append(';')
        if (quietStartMinute != null && quietEndMinute != null) append("quiet=").append(quietStartMinute).append('-').append(quietEndMinute).append(';')
    }
    companion object {
        const val DEFAULT_DAILY_CAP = 5
        fun parse(text: String?): NotificationPreferences {
            if (text.isNullOrBlank()) return NotificationPreferences()
            require(text.length <= 2048) { "Notification preferences exceed their limit." }
            val fields = text.split(';').filter { it.isNotEmpty() }.associate { field ->
                val index = field.indexOf('=')
                require(index > 0) { "Malformed notification preference \"$field\"." }
                field.substring(0, index) to field.substring(index + 1)
            }
            require(fields["v"] == "1") { "Unsupported notification preference version." }
            val enabled = NotificationCategory.entries.associateWith { category ->
                when (fields[category.name]) {
                    null -> category.defaultEnabled
                    "1" -> true
                    "0" -> !category.canDisable // a required notice stays on even if an old record says otherwise
                    else -> throw IllegalArgumentException("Malformed notification flag for ${category.name}.")
                }
            }
            val cap = fields["cap"]?.toIntOrNull() ?: DEFAULT_DAILY_CAP
            val quiet = fields["quiet"]?.split('-')?.map { it.toIntOrNull() ?: throw IllegalArgumentException("Malformed quiet hours.") }
            require(quiet == null || quiet.size == 2) { "Malformed quiet hours." }
            return NotificationPreferences(enabled, quiet?.get(0), quiet?.get(1), cap).also { it.validate() }
        }
    }
}

/** App-private storage of the serialized preferences; corrupt records are preserved and reported. */
class NotificationPreferenceStore(context: android.content.Context) {
    private val preferences = context.getSharedPreferences("studio-notifications", android.content.Context.MODE_PRIVATE)
    fun load(): Result<NotificationPreferences> = runCatching { NotificationPreferences.parse(preferences.getString(KEY, null)) }
    fun save(value: NotificationPreferences) { value.validate(); preferences.edit().putString(KEY, value.serialize()).apply() }
    companion object { const val KEY = "preferences" }
}
