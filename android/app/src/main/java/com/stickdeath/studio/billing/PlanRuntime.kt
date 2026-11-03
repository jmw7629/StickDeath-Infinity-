package com.stickdeath.studio.billing

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.stickdeath.studio.BuildConfig

/**
 * The process-wide plan state the Studio reads (iOS `StudioPlanLimits.current`). Inputs are facts
 * only: the server-reported plan and trial state (`sdi_spatter_my_usage`), a server-verified Play
 * subscription and the Play catalogue state. [limits] starts unrestricted and stays unrestricted
 * until [StudioPlanLimits.enforcing] holds, except that a reported free trial keeps Spatter
 * preview-only. Compose state, so every screen updates when it changes.
 */
object PlanRuntime {
    val catalog: PlanCatalog = PlanCatalog.load(BuildConfig.SDI_PLAY_CREATOR_MONTHLY_PRODUCT_ID,
        BuildConfig.SDI_PLAY_PRO_MONTHLY_PRODUCT_ID, BuildConfig.SDI_PLAY_UNLIMITED_MONTHLY_PRODUCT_ID,
        BuildConfig.SDI_PLAY_CREDIT_PACK_PRODUCT_IDS)

    /** Plan the server last reported for the signed-in account; null when signed out or unknown. */
    var serverPlan by mutableStateOf<PlanTier?>(null); private set
    /** True when the server reported that [serverPlan] is in its free trial. */
    var serverTrial by mutableStateOf(false); private set
    /** Highest subscription the server verified from a Play purchase on this device. */
    var verifiedPurchaseTier by mutableStateOf<PlanTier?>(null); private set
    /** True when that verified purchase is still in its free trial. */
    var verifiedPurchaseTrial by mutableStateOf(false); private set
    var storeLoaded by mutableStateOf(false); private set
    var purchasesAvailable by mutableStateOf(false); private set
    var limits by mutableStateOf(StudioPlanLimits.Unrestricted); private set

    val tier get() = PlanTier.best(serverPlan, verifiedPurchaseTier)
    /** The trial state of whichever source supplies [tier]; a paid, non-trial source wins a tie. */
    val inTrial: Boolean get() {
        val t = tier
        if (!t.isPaid) return false
        val fromServer = serverPlan == t
        val fromPurchase = verifiedPurchaseTier == t
        return (!fromServer || serverTrial) && (!fromPurchase || verifiedPurchaseTrial)
    }
    val status get() = PlanStatus(tier, inTrial)
    val enforcing get() = StudioPlanLimits.enforcing(catalog, storeLoaded, purchasesAvailable)

    fun reportServerPlan(plan: PlanTier?, inTrial: Boolean = false) { serverPlan = plan; serverTrial = plan != null && inTrial; recompute() }
    fun reportVerifiedPurchase(tier: PlanTier?, inTrial: Boolean = false) { verifiedPurchaseTier = tier; verifiedPurchaseTrial = tier != null && inTrial; recompute() }
    fun reportStore(loaded: Boolean, purchasable: Boolean) { storeLoaded = loaded; purchasesAvailable = purchasable; recompute() }

    private fun recompute() { limits = StudioPlanLimits.effective(tier, enforcing, inTrial) }
}
