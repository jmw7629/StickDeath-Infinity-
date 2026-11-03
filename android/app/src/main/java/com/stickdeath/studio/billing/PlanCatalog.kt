package com.stickdeath.studio.billing

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Pure-Kotlin plan model: the Android mirror of iOS `BillingPlanCatalog.swift` (StudioPlanLimits,
// BillingPlanCatalog, BillingCopy) as revised by the owner on 2026-10-15
// (docs/PLAN_DECISIONS_2026_10_15.md) and again on 2026-10-20 (three paid tiers, free trial),
// plus the Spatter credits decision for Free accounts.
// No Android imports, so the JVM unit tests exercise exactly the rules the app ships.
//
// - Plans: Free; Creator USD 4.99/month (250 server-funded Spatter messages per billing period);
//   Pro USD 9.99/month (500); Unlimited USD 19.99/month (unlimited). Rank Unlimited > Pro >
//   Creator > Free. Every paid plan unlocks the full Studio and includes bring-your-own AI key
//   (own-key prompts are not counted).
// - Every paid plan has a 3-day free trial. During the trial the Studio is fully unlocked but
//   Spatter is preview-only: suggested prompts and the upgrade note, nothing sent, no credits.
//   Whether an account is in its trial is a server/store fact ([PlanStatus.inTrial]), never guessed.
// - Amounts are never stored or shown from here: the price on screen is Google Play's
//   formatted price, or "Price shown when configured". Trial length on screen comes from Play's
//   zero-price phase.
// - Free Studio limits (FlipaClip-style, no ads) apply only while [StudioPlanLimits.enforcing]
//   is true: real Play product ids, the store loaded them, and purchasing can complete.
//   Until then every account keeps the full Studio, so nobody is locked out of a feature
//   they cannot buy.

enum class PlanTier(val wire: String, val rank: Int, val title: String) {
    Free("free", 0, "Free"), Creator("creator", 1, "Creator"), Pro("pro", 2, "Pro"), Unlimited("unlimited", 3, "Unlimited");

    val isPaid get() = this != Free
    /** Bring-your-own AI key is part of every paid plan; own-key prompts are not counted. */
    val includesOwnAIKey get() = isPaid
    /** Every paid plan starts with a 3-day free trial (owner decision 2026-10-20). */
    val offersTrial get() = isPaid
    /** Server-funded Spatter messages per billing period: 0 for Free (preview only), null when unlimited.
     * The server counts and enforces; this is the plan definition the copy and tests read. */
    val spatterMessagesPerPeriod: Int? get() = when (this) { Free -> 0; Creator -> 250; Pro -> 500; Unlimited -> null }
    val promptAllowance get() = when (this) {
        Free -> SpatterPromptAllowance.PreviewOnly
        Creator, Pro -> SpatterPromptAllowance.PerPeriod
        Unlimited -> SpatterPromptAllowance.Unlimited
    }

    companion object {
        /** Unknown or missing plans are not guessed. */
        fun fromWire(value: String?): PlanTier? = entries.firstOrNull { it.wire == value?.trim()?.lowercase() }
        /** The higher plan wins (server entitlement and a verified store purchase may both exist). */
        fun best(vararg tiers: PlanTier?): PlanTier = tiers.filterNotNull().maxByOrNull { it.rank } ?: Free
    }
}

enum class SpatterPromptAllowance {
    /** Free: Spatter and its suggested prompts are visible; a send gets the upgrade note unless the
     * account holds Spatter credits, which the server spends one per prompt (pay as you go). */
    PreviewOnly,
    /** Creator (250) and Pro (500): server-funded messages per billing period
     * ([PlanTier.spatterMessagesPerPeriod]), then credits when the account holds them. */
    PerPeriod,
    Unlimited,
}

/** The plan in force plus whether it is still in its free trial. [inTrial] only matters for a paid
 * tier; it comes from the server or a verified store purchase and is never assumed. */
data class PlanStatus(val tier: PlanTier, val inTrial: Boolean = false) {
    val trialing get() = inTrial && tier.isPaid
    /** Trial rule: Studio fully unlocked, Spatter preview-only (nothing sent, no credits used). */
    val spatterPreviewOnly get() = tier == PlanTier.Free || trialing
    val studioLimits get() = StudioPlanLimits.forTier(tier, trialing)
}

/** Output size of a rendered MP4/GIF. [scale] maps canvas pixels to output pixels. */
data class ExportRendition(val width: Int, val height: Int, val scale: Float, val watermark: Boolean) {
    val resized get() = scale != 1f
}

/** Integer pixel rectangle (left/top inclusive, right/bottom exclusive). */
data class PixelRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width get() = right - left
    val height get() = bottom - top
}

/** Canvas presets offered to every plan; Free may not type a custom width and height. */
object CanvasPresets {
    data class Preset(val name: String, val width: Int, val height: Int)
    val all = listOf(Preset("Portrait", 1080, 1920), Preset("Landscape", 1920, 1080),
        Preset("Square", 1080, 1080), Preset("TikTok", 1080, 1920), Preset("YouTube", 1920, 1080),
        Preset("Instagram", 1080, 1350), Preset("SD", 640, 480), Preset("HD", 1280, 720))
    fun isPreset(width: Int, height: Int) = all.any { it.width == width && it.height == height }
}

/** Studio limits per plan. Null or true means no limit. Mirrors iOS `StudioPlanLimits`. */
data class StudioPlanLimits(
    /** Maximum layers (Android layers span every frame, so this is the per-frame layer count). */
    val maxLayers: Int?,
    val maxOnionSkinBack: Int?,
    val maxOnionSkinForward: Int?,
    /** Custom canvas width/height (presets stay available). */
    val customCanvasSize: Boolean,
    /** Longest exported video/GIF edge in pixels (720p = 1280). */
    val maxExportLongEdge: Int?,
    /** The SDI watermark burned into exported MP4 and GIF files. */
    val exportWatermark: Boolean,
    val audioImport: Boolean,
    val soundLibrary: Boolean,
    /** Blur, Smudge, Sharpen, Dodge/Burn, extra brushes and background cut. */
    val advancedTools: Boolean,
    /** PNG image-sequence export. */
    val pngSequenceExport: Boolean,
    /** Submitting to the official SDI channels (no Android submission flow exists yet). */
    val sdiChannelSubmission: Boolean,
    /** Spatter answers and edits without credits. */
    val spatterActive: Boolean,
) {
    fun allowsNewLayer(currentCount: Int) = maxLayers?.let { currentCount < it } ?: true
    /** Projects already above the cap still open and edit; they only cannot gain layers. */
    fun allowsLayerChange(before: Int, after: Int) = after <= before || maxLayers?.let { after <= it } ?: true
    /** Basic brushes stay free; the rest are the extra brushes (iOS `basicBrushFamilies`). */
    fun allowsBrush(familyName: String) = advancedTools || familyName in BASIC_BRUSH_FAMILIES
    fun allowsCanvasSize(width: Int, height: Int) = customCanvasSize || CanvasPresets.isPreset(width, height)
    /** A canvas change is allowed when it keeps the current size or picks a preset. */
    fun allowsCanvasChange(fromWidth: Int, fromHeight: Int, toWidth: Int, toHeight: Int) =
        (fromWidth == toWidth && fromHeight == toHeight) || allowsCanvasSize(toWidth, toHeight)
    fun allowsOnion(previous: Int, next: Int) =
        previous <= (maxOnionSkinBack ?: previous) && next <= (maxOnionSkinForward ?: next)
    /** What the editor shows; the saved settings are not rewritten. */
    fun clampedOnion(previous: Int, next: Int): Pair<Int, Int> =
        min(previous, maxOnionSkinBack ?: previous) to min(next, maxOnionSkinForward ?: next)

    /** MP4/GIF output size: the canvas, or scaled down to fit [maxExportLongEdge]. MP4 needs even
     * dimensions; a scaled MP4 rounds each edge down to an even number. */
    fun exportRendition(canvasWidth: Int, canvasHeight: Int, evenDimensions: Boolean): ExportRendition {
        require(canvasWidth > 0 && canvasHeight > 0)
        val limit = maxExportLongEdge
        val longEdge = max(canvasWidth, canvasHeight)
        if (limit == null || longEdge <= limit) return ExportRendition(canvasWidth, canvasHeight, 1f, exportWatermark)
        val scale = limit.toDouble() / longEdge
        fun edge(value: Int): Int {
            val scaled = floor(value * scale + 1e-9).toInt().coerceAtLeast(2)
            return if (evenDimensions) (scaled - scaled % 2).coerceAtLeast(2) else scaled
        }
        return ExportRendition(edge(canvasWidth), edge(canvasHeight), scale.toFloat(), exportWatermark)
    }

    companion object {
        val BASIC_BRUSH_FAMILIES = setOf("Round", "Stipple", "Grain", "RoughPen", "Calligraphy", "DipPen")

        val Free = StudioPlanLimits(maxLayers = 3, maxOnionSkinBack = 1, maxOnionSkinForward = 0,
            customCanvasSize = false, maxExportLongEdge = 1280, exportWatermark = true,
            audioImport = false, soundLibrary = false, advancedTools = false,
            pngSequenceExport = false, sdiChannelSubmission = false, spatterActive = false)
        val Unrestricted = StudioPlanLimits(maxLayers = null, maxOnionSkinBack = null, maxOnionSkinForward = null,
            customCanvasSize = true, maxExportLongEdge = null, exportWatermark = false,
            audioImport = true, soundLibrary = true, advancedTools = true,
            pngSequenceExport = true, sdiChannelSubmission = true, spatterActive = true)

        /** During a paid plan's free trial the Studio is fully unlocked but Spatter is preview-only. */
        fun forTier(tier: PlanTier, inTrial: Boolean = false) = when {
            tier == PlanTier.Free -> Free
            inTrial -> Unrestricted.copy(spatterActive = false)
            else -> Unrestricted
        }

        /** Limits apply only once the catalogue names real Play products, Play has loaded them and a
         * purchase can complete (server verification exists). Until then everyone keeps the full
         * Studio. iOS uses the same rule; Android adds [purchasesAvailable] because Android purchase
         * verification is not built yet, and a plan nobody can buy must not lock anything. */
        fun enforcing(catalog: PlanCatalog, storeLoaded: Boolean, purchasesAvailable: Boolean) =
            !catalog.usesPlaceholderIdentifiers && storeLoaded && purchasesAvailable

        /** The trial rule follows the reported trial state even before Studio limits are enforced:
         * a trialing account's Spatter stays preview-only while its Studio stays unlocked. */
        fun effective(tier: PlanTier, enforcing: Boolean, inTrial: Boolean = false) = when {
            enforcing -> forTier(tier, inTrial)
            inTrial && tier.isPaid -> forTier(tier, inTrial = true)
            else -> Unrestricted
        }

        const val UPGRADE_NOTE = "This is part of Creator, Pro and Unlimited. Upgrade in Account, Plans to unlock it."
    }
}

/** Where the SDI watermark sits on an exported frame: a small mark at the bottom right. */
object ExportWatermarkLayout {
    const val TEXT = "SDI"
    /** Mark height is 5% of the shorter edge (at least 12 px); width fits the three letters. */
    fun rect(width: Int, height: Int): PixelRect {
        require(width > 0 && height > 0)
        val markHeight = max(12, (min(width, height) * 0.05).roundToInt()).coerceAtMost(min(width, height))
        val markWidth = (markHeight * 2.2).roundToInt().coerceAtMost(width)
        val margin = (markHeight * 0.4).roundToInt()
        val right = (width - margin).coerceAtLeast(markWidth)
        val bottom = (height - margin).coerceAtLeast(markHeight)
        return PixelRect(right - markWidth, bottom - markHeight, right, bottom)
    }
}

data class PlanEntitlement(val text: String, val isLive: Boolean)

data class PlanDefinition(
    val tier: PlanTier,
    /** Google Play product id; null for Free. */
    val productId: String?,
    val entitlements: List<PlanEntitlement>,
    val promptAllowance: SpatterPromptAllowance,
) {
    val name get() = tier.title
    val studioLimits get() = StudioPlanLimits.forTier(tier)
    val spatterMessagesPerPeriod get() = tier.spatterMessagesPerPeriod
}

/** A consumable Spatter credit pack. The number of credits granted is the server's decision and the
 * store listing's description; the app never states an amount of its own. */
data class CreditPackDefinition(val productId: String)

data class PlanCatalog(
    val plans: List<PlanDefinition>,
    val creditPacks: List<CreditPackDefinition>,
    val usesPlaceholderIdentifiers: Boolean,
    val creditPacksUsePlaceholders: Boolean,
) {
    val subscriptionProductIds get() = plans.mapNotNull { it.productId }
    val creditProductIds get() = creditPacks.map { it.productId }
    fun plan(productId: String) = plans.firstOrNull { it.productId == productId }
    /** Unknown ids grant nothing. */
    fun tier(productId: String) = plan(productId)?.tier ?: PlanTier.Free
    fun isCreditPack(productId: String) = creditPacks.any { it.productId == productId }

    companion object {
        const val PLACEHOLDER_CREATOR_MONTHLY = "com.stickdeath.studio.creator.monthly.placeholder"
        const val PLACEHOLDER_PRO_MONTHLY = "com.stickdeath.studio.pro.monthly.placeholder"
        const val PLACEHOLDER_UNLIMITED_MONTHLY = "com.stickdeath.studio.unlimited.monthly.placeholder"
        const val PLACEHOLDER_CREDIT_PACK = "com.stickdeath.studio.spatter.credits.placeholder"
        private val PRODUCT_ID = Regex("^[a-z0-9][a-z0-9._]{0,138}[a-z0-9]$")

        val freeEntitlements = listOf(
            PlanEntitlement("Studio on this device, up to 3 layers per frame", true),
            PlanEntitlement("Projects stay on this device", true),
            PlanEntitlement("Onion skin 1 frame back", true),
            PlanEntitlement("Preset canvas sizes", true),
            PlanEntitlement("Exports up to 720p with the SDI watermark", true),
            PlanEntitlement("Preview Spatter and its suggested prompts; answers need a paid plan or Spatter credits (1 credit per prompt)", true),
        )
        private const val TRIAL_ENTITLEMENT = "3-day free trial when Google Play offers it to your account: the full Studio, with Spatter as a preview (nothing is sent and no credits are used)"
        val creatorEntitlements = listOf(
            PlanEntitlement("Everything in Free", true),
            PlanEntitlement("Unlimited layers, full onion skin and custom canvas sizes", true),
            PlanEntitlement("No watermark, full-size exports and PNG sequences", true),
            PlanEntitlement("Import audio and use the sound library", true),
            PlanEntitlement("Extra brushes (Halftone, Hatch, Marker, Crayon)", true),
            PlanEntitlement("250 Spatter messages each billing period, then credits", false),
            PlanEntitlement("Use your own AI key; own-key prompts are not counted (available in the iOS app; not yet on Android)", false),
            PlanEntitlement("Submit videos to the official SDI channels (watermarked, reviewed before posting; not yet on Android)", false),
            PlanEntitlement(TRIAL_ENTITLEMENT, true),
        )
        val proEntitlements = listOf(
            PlanEntitlement("Everything in Creator", true),
            PlanEntitlement("500 Spatter messages each billing period, then credits", false),
            PlanEntitlement(TRIAL_ENTITLEMENT, true),
        )
        val unlimitedEntitlements = listOf(
            PlanEntitlement("Everything in Pro", true),
            PlanEntitlement("Unlimited Spatter messages", false),
            PlanEntitlement(TRIAL_ENTITLEMENT, true),
        )

        /** Build from the Gradle-supplied BuildConfig values. A blank, malformed or placeholder id is
         * not configuration; a reused id offers neither duplicate. [creditPackIds] is comma-separated. */
        fun load(creatorMonthly: String?, proMonthly: String?, unlimitedMonthly: String?, creditPackIds: String?): PlanCatalog {
            fun real(value: String?, placeholder: String) = value?.trim()?.takeIf { PRODUCT_ID.matches(it) && it != placeholder }
            val creator = real(creatorMonthly, PLACEHOLDER_CREATOR_MONTHLY)
            val pro = real(proMonthly, PLACEHOLDER_PRO_MONTHLY)
            val unlimited = real(unlimitedMonthly, PLACEHOLDER_UNLIMITED_MONTHLY)
            val plans = listOf(
                PlanDefinition(PlanTier.Free, null, freeEntitlements, PlanTier.Free.promptAllowance),
                PlanDefinition(PlanTier.Creator, creator ?: PLACEHOLDER_CREATOR_MONTHLY, creatorEntitlements, PlanTier.Creator.promptAllowance),
                PlanDefinition(PlanTier.Pro, pro ?: PLACEHOLDER_PRO_MONTHLY, proEntitlements, PlanTier.Pro.promptAllowance),
                PlanDefinition(PlanTier.Unlimited, unlimited ?: PLACEHOLDER_UNLIMITED_MONTHLY, unlimitedEntitlements, PlanTier.Unlimited.promptAllowance),
            )
            val packs = creditPackIds.orEmpty().split(',').mapNotNull { real(it, PLACEHOLDER_CREDIT_PACK) }.distinct()
            val ids = plans.mapNotNull { it.productId } + packs
            val duplicates = ids.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
            return PlanCatalog(
                plans = plans.filter { it.productId == null || it.productId !in duplicates },
                creditPacks = packs.filter { it !in duplicates }.map(::CreditPackDefinition),
                usesPlaceholderIdentifiers = creator == null || pro == null || unlimited == null ||
                    setOf(creator, pro, unlimited).size < 3,
                creditPacksUsePlaceholders = packs.none { it !in duplicates },
            )
        }
    }
}

// MARK: - Spatter gate

/** Server-reported Spatter usage (`public.sdi_spatter_my_usage`). Display data only: the server
 * decides and counts every prompt. [credits] and [available] are null when the server did not
 * report them; they are never invented. */
data class SpatterUsage(
    val plan: PlanTier,
    val unlimited: Boolean,
    val limit: Int?,
    val remaining: Int?,
    val credits: Int?,
    val available: Boolean?,
    val resetsAt: String?,
    val paused: Boolean,
    /** True while the paid plan is in its free trial (Spatter preview-only); null when not reported. */
    val inTrial: Boolean? = null,
)

sealed class SpatterGate {
    /** Send to the backend. [payAsYouGo] marks a Free or exhausted-Creator send paid by one credit. */
    data class Send(val payAsYouGo: Boolean) : SpatterGate()
    /** Free without credits: the fixed upgrade note answers on the device; nothing is sent. */
    object UpgradeNote : SpatterGate()
    /** Creator's or Pro's period allowance is used up and the server reports no credits. */
    object AllowanceUsed : SpatterGate()
    /** A paid plan in its free trial: Spatter is preview-only, nothing is sent and no credits are used. */
    object TrialPreview : SpatterGate()
    /** The plan must be known before a send (Studio limits enforcing Free, usage still loading). */
    object Checking : SpatterGate()

    companion object {
        /**
         * [limits] are the Studio limits in force; [usage] is the latest server report for the
         * signed-in account (null when unknown); [usageLoading] is true while it is being fetched.
         * When nothing is enforced and the server has not reported a plan, the send goes through:
         * the server still refuses Free without credits (HTTP 402 `upgrade_required`).
         * [inTrial] is the trial state known outside [usage] (e.g. a verified store purchase); a trial
         * reported by either source makes Spatter preview-only before any credit check.
         */
        fun decide(limits: StudioPlanLimits, usage: SpatterUsage?, usageLoading: Boolean, inTrial: Boolean = false): SpatterGate {
            val trialing = if (usage == null) inTrial else usage.plan.isPaid && (inTrial || usage.inTrial == true)
            if (trialing) return TrialPreview
            if (usage == null) return when {
                limits.spatterActive -> Send(payAsYouGo = false)
                usageLoading -> Checking
                else -> UpgradeNote
            }
            val hasCredits = (usage.credits ?: 0) > 0
            return when (usage.plan) {
                PlanTier.Unlimited -> Send(payAsYouGo = false)
                PlanTier.Creator, PlanTier.Pro ->
                    if (usage.remaining == 0) { if (hasCredits) Send(payAsYouGo = true) else AllowanceUsed }
                    else Send(payAsYouGo = false)
                PlanTier.Free -> when {
                    usage.available == false -> UpgradeNote
                    usage.available == true || hasCredits -> Send(payAsYouGo = true)
                    else -> UpgradeNote
                }
            }
        }
    }
}

// MARK: - Purchases

enum class PurchaseKind { Subscription, CreditPack }
enum class StorePurchaseState { Purchased, Pending, Unspecified }

/** What the server said about one store purchase. */
sealed class PurchaseVerification {
    /** No Android verification endpoint exists in this build; nothing is granted or finalised. */
    object NotConfigured : PurchaseVerification()
    data class Granted(val tier: PlanTier?, val creditsBalance: Int?) : PurchaseVerification()
    data class Rejected(val reason: String) : PurchaseVerification()
    data class Failed(val reason: String) : PurchaseVerification()
}

enum class PurchaseAction {
    /** Subscription confirmed by the server: acknowledge it with Play. */
    Acknowledge,
    /** Credit pack confirmed by the server: consume it so it can be bought again. */
    Consume,
    /** Leave it untouched (pending, unverified or already finalised). Play refunds an
     * unacknowledged purchase automatically after three days. */
    Hold,
}

object PurchasePolicy {
    /** Acknowledgement and consumption happen only after the server confirms the grant. */
    fun action(kind: PurchaseKind, state: StorePurchaseState, acknowledged: Boolean, verification: PurchaseVerification): PurchaseAction {
        if (state != StorePurchaseState.Purchased || verification !is PurchaseVerification.Granted) return PurchaseAction.Hold
        return when (kind) {
            PurchaseKind.Subscription -> if (acknowledged) PurchaseAction.Hold else PurchaseAction.Acknowledge
            PurchaseKind.CreditPack -> PurchaseAction.Consume
        }
    }
}

// MARK: - Copy

object PlanCopy {
    /** The only answer Spatter gives a Free account without credits. Shown on the device; nothing is sent. */
    const val SPATTER_UPGRADE_NOTE = "Spatter is part of Creator, Pro and Unlimited. Upgrade in Account, Plans to activate it, or buy Spatter credits to pay as you go (1 credit per prompt)."
    const val SPATTER_ALLOWANCE_USED = "This billing period's Spatter allowance is used. Buy Spatter credits, move to a higher plan (Pro: 500 messages, Unlimited: no limit), or wait for your renewal."
    /** Shown instead of a Spatter answer during a paid plan's free trial; nothing is sent. */
    const val SPATTER_TRIAL_PREVIEW = "You're in your free trial: the full Studio is unlocked and Spatter is a preview until the trial ends. Nothing was sent and no credits were used."
    const val TRIAL_RULE = "Paid plans start with a 3-day free trial when Google Play offers one to your account. During the trial the Studio is fully unlocked and Spatter is a preview: nothing is sent and no credits are used."
    const val SPATTER_CHECKING = "Checking your Spatter plan… try again in a moment."
    const val PRICE_UNCONFIGURED = "Price shown when configured"
    const val PURCHASES_UNAVAILABLE = "Purchases on Android are not available yet: the StickDeath server cannot verify Google Play purchases, so nothing can be bought or granted here. You keep the full Studio until plans can be purchased."
    const val MANAGE_NOTE = "Billed by Google Play. Manage, change or cancel in Google Play subscriptions; cancelling keeps access until the period ends. Projects stay on this device."

    /** [formattedPrice] is Google Play's own string; null until Play supplies it. */
    fun price(formattedPrice: String?, isoPeriod: String? = "P1M"): String {
        if (formattedPrice.isNullOrBlank()) return PRICE_UNCONFIGURED
        val per = when (isoPeriod) { "P1M" -> " per month"; "P1Y" -> " per year"; "P1W" -> " per week"; null -> ""; else -> "" }
        return formattedPrice + per
    }

    /** Free-trial text from a zero-price Play pricing phase (Play lists only offers the account is
     * eligible for). [isoPeriod] is the phase's ISO-8601 billing period, e.g. "P7D", "P1W", "P1M". */
    fun trial(isoPeriod: String?, cycles: Int = 1): String? {
        val match = Regex("^P(\\d{1,3})([DWMY])$").matchEntire(isoPeriod ?: return null) ?: return null
        val amount = match.groupValues[1].toInt() * cycles.coerceAtLeast(1)
        if (amount <= 0) return null
        val unit = when (match.groupValues[2]) { "D" -> "day"; "W" -> "week"; "M" -> "month"; else -> "year" }
        return "$amount-$unit free trial"
    }

    fun usage(usage: SpatterUsage?): String {
        if (usage == null) return "Your Spatter plan has not been reported by the server yet."
        val credits = usage.credits?.let { " Credits: $it." } ?: ""
        if (usage.paused) return "Spatter is paused by the service operator.$credits"
        if (usage.inTrial == true && usage.plan.isPaid) return "${usage.plan.title} free trial: Spatter is a preview until the trial ends; nothing is sent and no credits are used.$credits"
        return when (usage.plan) {
            PlanTier.Unlimited -> "Unlimited: unlimited Spatter messages.$credits"
            PlanTier.Creator, PlanTier.Pro -> {
                val name = usage.plan.title
                val left = usage.remaining?.let { r -> usage.limit?.let { "$r of $it" } ?: "$r" }
                (left?.let { "$name: $it Spatter messages left this billing period." }
                    ?: "$name: remaining messages appear once the server reports them.") + credits
            }
            PlanTier.Free -> if ((usage.credits ?: 0) > 0) "Free: pay as you go, 1 credit per Spatter prompt.$credits"
                else "Free: Spatter answers need a paid plan or Spatter credits.$credits"
        }
    }
}
