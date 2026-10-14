package com.stickdeath.studio

/** Description of the server contract the Android client speaks (see the `connect` package for the
 * GoTrue session, PostgREST gateway, feed/profile/Rooms clients and Spatter transport). Nothing
 * here opens a connection. Unless the owner supplies public Supabase values at build time the
 * merged manifest declares no INTERNET permission and every connected feature reports
 * [SessionState.NotConfigured] honestly instead of inventing data. */
enum class BackendArea(val label: String) {
    Identity("Account"), Feed("Video feed"), Rooms("Rooms"), WarRoom("War Room"), Challenges("Challenges"),
    Achievements("Badges"), Profile("Profile"), Billing("Subscription"), Support("Support"),
    Account("Account lifecycle"), Publishing("Publishing"), Moderation("Moderation")
}
enum class BackendAccess { Member, MemberFresh, Service, Admin }

/** One PostgREST `rpc/<name>` call. [sqlFile] is the candidate that defines `public.<name>`. */
data class BackendRpc(val name: String, val area: BackendArea, val sqlFile: String, val access: BackendAccess, val summary: String)

object BackendContract {
    const val TRANSPORT = "Supabase PostgREST `rpc/<name>` over HTTPS with the member's own session JWT; no provider keys on the device."
    const val IDENTITY = "Apple, Google, GitHub and Microsoft sign-in through the identity provider; sessions restore from the platform keystore. Server-authorized admin roles; MFA for administrators."

    /** Client-facing RPCs only (service-role workers and admin consoles stay server/web side). */
    val rpcs: List<BackendRpc> = listOf(
        BackendRpc("sdi_feed_action", BackendArea.Feed, "video-feed.sql", BackendAccess.Member, "Approved-video wall pages, likes, follows, blocks and reports."),
        BackendRpc("sdi_room_action", BackendArea.Rooms, "room-invitations.sql", BackendAccess.Member, "Invitation codes, consent, approval, rotation, revocation and membership."),
        BackendRpc("sdi_room_manage", BackendArea.Rooms, "rooms-v2.sql", BackendAccess.Member, "Shared project reference, title, view/edit permission and member roles."),
        BackendRpc("sdi_room_command", BackendArea.Rooms, "rooms-v2.sql", BackendAccess.Member, "Versioned shared edit commands with conflict responses."),
        BackendRpc("sdi_war_action", BackendArea.WarRoom, "war-room.sql", BackendAccess.Member, "Matchup proposals, acceptance, withdrawal and one mutable vote."),
        BackendRpc("sdi_war_report", BackendArea.WarRoom, "war-moderation.sql", BackendAccess.Member, "Report a match submission."),
        BackendRpc("sdi_war_notices", BackendArea.WarRoom, "war-appeals.sql", BackendAccess.Member, "Member-visible match and appeal notices."),
        BackendRpc("sdi_war_leaderboard", BackendArea.Profile, "profile-records.sql", BackendAccess.Member, "Server-counted standings; hidden unless the creator opts in."),
        BackendRpc("sdi_challenge_action", BackendArea.Challenges, "challenges.sql", BackendAccess.Member, "Submit, withdraw and vote within server-time phases."),
        BackendRpc("sdi_calendar_range", BackendArea.Challenges, "challenges.sql", BackendAccess.Member, "Calendar entries for a range of at most 62 days."),
        BackendRpc("sdi_achievement_catalog", BackendArea.Achievements, "achievements.sql", BackendAccess.Member, "The caller's earned and locked badges."),
        BackendRpc("sdi_profile_records", BackendArea.Profile, "profile-records.sql", BackendAccess.Member, "Optional win/loss and statistics preferences."),
        BackendRpc("sdi_my_entitlement", BackendArea.Billing, "billing.sql", BackendAccess.Member, "Read-only entitlement from verified provider events; clients write nothing."),
        BackendRpc("sdi_support_action", BackendArea.Support, "support-requests.sql", BackendAccess.Member, "Create, list, withdraw and delete support requests (five per day)."),
        BackendRpc("sdi_account_lifecycle", BackendArea.Account, "account-lifecycle.sql", BackendAccess.Member, "Data export and deletion requests with a seven-day cooling-off."),
        BackendRpc("sdi_member_notices", BackendArea.Account, "account-lifecycle.sql", BackendAccess.Member, "Member notices (transactional only)."),
        BackendRpc("sdi_account_appeal_action", BackendArea.Account, "admin-users.sql", BackendAccess.MemberFresh, "Own account state and restriction appeals."),
        BackendRpc("sdi_moderation_appeal", BackendArea.Moderation, "rooms-v2.sql", BackendAccess.Member, "Appeal a feed removal within 30 days."),
        BackendRpc("sdi_creator_review", BackendArea.Publishing, "creator-reviews.sql", BackendAccess.Member, "Queue a private render for review or a destination; never publishes by itself."),
        BackendRpc("sdi_export_consent", BackendArea.Publishing, "feed-publication.sql", BackendAccess.Member, "Creator export permission, separate from approval evidence."),
        BackendRpc("sdi_review_rights", BackendArea.Publishing, "review-rights.sql", BackendAccess.Member, "Asset and contributor rights declarations for a review."),
        BackendRpc("sdi_upload_identity", BackendArea.Publishing, "upload-identity.sql", BackendAccess.Member, "Identity for a private render upload."),
        BackendRpc("sdi_register_upload", BackendArea.Publishing, "upload-registration.sql", BackendAccess.Member, "Register the exact uploaded digest and version."),
        BackendRpc("sdi_upload_preview", BackendArea.Publishing, "upload-preview.sql", BackendAccess.Member, "Expiring private preview of an uploaded render."),
        BackendRpc("sdi_preview_permit", BackendArea.Publishing, "preview-renewal.sql", BackendAccess.Member, "Permit for an authorized preview."),
        BackendRpc("sdi_preview_renew", BackendArea.Publishing, "preview-renewal.sql", BackendAccess.Member, "Renew an expiring preview permit."))

    fun rpcs(area: BackendArea) = rpcs.filter { it.area == area }
    val sqlFiles: Set<String> get() = rpcs.map { it.sqlFile }.toSet()
}

enum class IdentityProvider(val label: String) { Apple("Apple"), Google("Google"), GitHub("GitHub"), Microsoft("Microsoft") }

/** What the client can truthfully say about its connection. Android ships only [NotConfigured]. */
sealed class SessionState {
    abstract val summary: String
    data class NotConfigured(val reason: String) : SessionState() { override val summary get() = "Not connected — $reason" }
    object SignedOut : SessionState() { override val summary get() = "Signed out" }
    data class SignedIn(val provider: IdentityProvider, val displayName: String) : SessionState() { override val summary get() = "Signed in with ${provider.label} as $displayName" }
}

object AndroidIdentity {
    /** Providers the owner configured for this build (BuildConfig); none by default. */
    val configuredProviders: Set<IdentityProvider>
        get() = com.stickdeath.studio.connect.BackendConfig.parseProviders(BuildConfig.SDI_OAUTH_PROVIDERS)
            .map { IdentityProvider.valueOf(it.title) }.toSet()
    /** True only for builds given public Supabase values; the default build declares no network permission. */
    val NETWORK_PERMISSION_DECLARED: Boolean get() = BuildConfig.SDI_NETWORK_DECLARED
    fun currentState(configured: Set<IdentityProvider> = configuredProviders, network: Boolean = NETWORK_PERMISSION_DECLARED): SessionState = when {
        !network -> SessionState.NotConfigured("this build declares no network access, so sign-in, feed, Rooms, War Room, challenges, billing and Spatter cloud assistance are unavailable.")
        configured.isEmpty() -> SessionState.NotConfigured("no identity provider is configured for Android yet.")
        else -> SessionState.SignedOut
    }
}
