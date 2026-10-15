package com.stickdeath.studio.billing

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.stickdeath.studio.BuildConfig

/**
 * The process-wide plan state the Studio reads (iOS `StudioPlanLimits.current`). Inputs are facts
 * only: the server-reported plan (`sdi_spatter_my_usage`), a server-verified Play subscription and
 * the Play catalogue state. [limits] starts unrestricted and stays unrestricted until
 * [StudioPlanLimits.enforcing] holds. Compose state, so every screen updates when it changes.
 */
object PlanRuntime {
    val catalog: PlanCatalog = PlanCatalog.load(BuildConfig.SDI_PLAY_CREATOR_MONTHLY_PRODUCT_ID,
        BuildConfig.SDI_PLAY_PRO_MONTHLY_PRODUCT_ID, BuildConfig.SDI_PLAY_CREDIT_PACK_PRODUCT_IDS)

    /** Plan the server last reported for the signed-in account; null when signed out or unknown. */
    var serverPlan by mutableStateOf<PlanTier?>(null); private set
    /** Highest subscription the server verified from a Play purchase on this device. */
    var verifiedPurchaseTier by mutableStateOf<PlanTier?>(null); private set
    var storeLoaded by mutableStateOf(false); private set
    var purchasesAvailable by mutableStateOf(false); private set
    var limits by mutableStateOf(StudioPlanLimits.Unrestricted); private set

    val tier get() = PlanTier.best(serverPlan, verifiedPurchaseTier)
    val enforcing get() = StudioPlanLimits.enforcing(catalog, storeLoaded, purchasesAvailable)

    fun reportServerPlan(plan: PlanTier?) { serverPlan = plan; recompute() }
    fun reportVerifiedPurchase(tier: PlanTier?) { verifiedPurchaseTier = tier; recompute() }
    fun reportStore(loaded: Boolean, purchasable: Boolean) { storeLoaded = loaded; purchasesAvailable = purchasable; recompute() }

    private fun recompute() { limits = StudioPlanLimits.effective(tier, enforcing) }
}
