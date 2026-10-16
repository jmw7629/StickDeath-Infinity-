package com.stickdeath.studio.billing

import android.app.Activity
import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.consumePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The facts a server needs to verify one Google Play purchase. The token is never logged or shown. */
class PurchaseFacts(val productId: String, val kind: PurchaseKind, val purchaseToken: String, val orderId: String?) {
    override fun toString() = "PurchaseFacts($productId, $kind)"
}

/** Server confirmation of a Play purchase. Only a server grant may lead to acknowledgement or
 * consumption (see [PurchasePolicy]). */
interface PurchaseVerifier {
    val configured: Boolean
    suspend fun verify(facts: PurchaseFacts): PurchaseVerification
}

/** The StickDeath backend has no Google Play verification endpoint yet (only Stripe/App Store
 * paths exist), so this build cannot grant or finalise any Play purchase. Purchasing stays off. */
object NotConfiguredPurchaseVerifier : PurchaseVerifier {
    override val configured = false
    override suspend fun verify(facts: PurchaseFacts) = PurchaseVerification.NotConfigured
}

/** One Play product with store-provided display values only. */
data class StoreProduct(
    val productId: String,
    val kind: PurchaseKind,
    val tier: PlanTier?,
    val title: String,
    val description: String,
    /** Play's formatted price of the recurring (or one-time) phase; null when Play gave none. */
    val formattedPrice: String?,
    val billingPeriod: String?,
    /** Present only when Play lists a free-trial phase, which it does only for eligible accounts. */
    val trial: String?,
    internal val offerToken: String?,
    internal val details: ProductDetails,
)

sealed class StoreStatus {
    /** Placeholder product ids: nothing is requested from Google Play. */
    object NotConfigured : StoreStatus()
    object Connecting : StoreStatus()
    data class Unavailable(val reason: String) : StoreStatus()
    object Loaded : StoreStatus()
}

/**
 * Google Play Billing for the two monthly plans and consumable Spatter credit packs.
 * - Connects only when the build names real product ids.
 * - Prices, titles and trials come only from Play.
 * - A purchase is acknowledged (subscription) or consumed (credit pack) only after
 *   [PurchaseVerifier] reports a server grant. The shipped verifier is [NotConfiguredPurchaseVerifier],
 *   so purchasing is disabled and any purchase Play reports is held unacknowledged (Play refunds it
 *   automatically after three days). Nothing here claims a grant the server did not make.
 */
class BillingRepository(
    context: Context,
    private val catalog: PlanCatalog,
    private val verifier: PurchaseVerifier = NotConfiguredPurchaseVerifier,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val listener = PurchasesUpdatedListener { result, purchases -> onPurchasesUpdated(result, purchases) }
    private val client: BillingClient = BillingClient.newBuilder(context.applicationContext)
        .setListener(listener)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    var status by mutableStateOf<StoreStatus>(StoreStatus.NotConfigured); private set
    var subscriptions by mutableStateOf<List<StoreProduct>>(emptyList()); private set
    var creditPacks by mutableStateOf<List<StoreProduct>>(emptyList()); private set
    var message by mutableStateOf<String?>(null); private set
    var busy by mutableStateOf(false); private set

    private val configured get() = !catalog.usesPlaceholderIdentifiers || !catalog.creditPacksUsePlaceholders
    val purchasesAvailable get() = verifier.configured && status == StoreStatus.Loaded

    fun start() {
        if (!configured) { status = StoreStatus.NotConfigured; publish(); return }
        if (status == StoreStatus.Connecting || client.isReady) return
        status = StoreStatus.Connecting
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                scope.launch {
                    if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                        status = StoreStatus.Unavailable("Google Play billing is unavailable on this device (code ${result.responseCode})."); publish(); return@launch
                    }
                    refresh()
                }
            }
            override fun onBillingServiceDisconnected() {
                scope.launch { if (status == StoreStatus.Connecting) { status = StoreStatus.Unavailable("Google Play billing disconnected."); publish() } }
            }
        })
    }

    /** Reloads products and re-checks purchases Play still reports for this account. */
    fun refresh() {
        if (!configured || !client.isReady) return
        scope.launch {
            val subs = if (catalog.usesPlaceholderIdentifiers) emptyList() else query(catalog.subscriptionProductIds, BillingClient.ProductType.SUBS)
            val packs = if (catalog.creditPacksUsePlaceholders) emptyList() else query(catalog.creditProductIds, BillingClient.ProductType.INAPP)
            subscriptions = subs.sortedBy { it.tier?.rank ?: 0 }
            creditPacks = packs
            val bothPlans = PlanTier.entries.filter { it != PlanTier.Free }.all { tier -> subs.any { it.tier == tier } }
            status = if (bothPlans || packs.isNotEmpty()) StoreStatus.Loaded
                else StoreStatus.Unavailable("Google Play has no products for this app yet.")
            publish()
            reconcileOwnedPurchases()
        }
    }

    private suspend fun query(ids: List<String>, type: String): List<StoreProduct> {
        if (ids.isEmpty()) return emptyList()
        val params = QueryProductDetailsParams.newBuilder().setProductList(ids.map {
            QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(type).build()
        }).build()
        val result = client.queryProductDetails(params)
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) return emptyList()
        return result.productDetailsList.orEmpty().filter { it.productId in ids }.mapNotNull(::describe)
    }

    private fun describe(details: ProductDetails): StoreProduct? {
        val subscription = details.productType == BillingClient.ProductType.SUBS
        if (subscription) {
            val offers = details.subscriptionOfferDetails.orEmpty()
            // Play lists only offers this account is eligible for; prefer one with a free-trial phase.
            val offer = offers.firstOrNull { o -> o.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L } }
                ?: offers.firstOrNull { it.offerId == null } ?: offers.firstOrNull() ?: return null
            val phases = offer.pricingPhases.pricingPhaseList
            val recurring = phases.lastOrNull { it.priceAmountMicros > 0L }
            val trialPhase = phases.firstOrNull { it.priceAmountMicros == 0L }
            return StoreProduct(details.productId, PurchaseKind.Subscription, catalog.plan(details.productId)?.tier,
                details.name, details.description, recurring?.formattedPrice, recurring?.billingPeriod,
                trialPhase?.let { PlanCopy.trial(it.billingPeriod, it.billingCycleCount) }, offer.offerToken, details)
        }
        val oneTime = details.oneTimePurchaseOfferDetails ?: return null
        return StoreProduct(details.productId, PurchaseKind.CreditPack, null, details.name, details.description,
            oneTime.formattedPrice, null, null, null, details)
    }

    /** Starts Play's purchase sheet. Refused while purchasing cannot be verified by the server. */
    fun purchase(activity: Activity, product: StoreProduct) {
        if (!purchasesAvailable) { message = PlanCopy.PURCHASES_UNAVAILABLE; return }
        if (busy) return
        val params = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product.details)
            .apply { product.offerToken?.let { setOfferToken(it) } }.build()
        val result = client.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(params)).build())
        if (result.responseCode == BillingClient.BillingResponseCode.OK) { busy = true; message = "Complete or cancel the purchase in Google Play." }
        else message = "Google Play could not start the purchase (code ${result.responseCode}). Nothing was billed."
    }

    private fun onPurchasesUpdated(result: BillingResult, purchases: List<Purchase>?) {
        scope.launch {
            busy = false
            when (result.responseCode) {
                // Re-reads every purchase Play holds (including this one) so the verified tier stays whole.
                BillingClient.BillingResponseCode.OK -> if (!purchases.isNullOrEmpty()) reconcileOwnedPurchases()
                BillingClient.BillingResponseCode.USER_CANCELED -> message = null
                BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> { message = "Google Play reports you already own this."; reconcileOwnedPurchases() }
                else -> message = "The purchase did not complete (code ${result.responseCode}). Nothing was billed or granted."
            }
        }
    }

    private suspend fun reconcileOwnedPurchases() {
        if (!client.isReady) return
        var verifiedTier: PlanTier? = null
        for (type in listOf(BillingClient.ProductType.SUBS, BillingClient.ProductType.INAPP)) {
            val owned = client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(type).build())
            if (owned.billingResult.responseCode != BillingClient.BillingResponseCode.OK) continue
            owned.purchasesList.forEach { purchase -> handle(purchase)?.let { verifiedTier = PlanTier.best(verifiedTier, it) } }
        }
        PlanRuntime.reportVerifiedPurchase(verifiedTier)
    }

    /** Returns the subscription tier the server granted for [purchase], if any. */
    private suspend fun handle(purchase: Purchase): PlanTier? {
        val productId = purchase.products.firstOrNull() ?: return null
        val kind = when {
            catalog.plan(productId) != null -> PurchaseKind.Subscription
            catalog.isCreditPack(productId) -> PurchaseKind.CreditPack
            else -> return null // Unknown ids grant nothing.
        }
        val state = when (purchase.purchaseState) {
            Purchase.PurchaseState.PURCHASED -> StorePurchaseState.Purchased
            Purchase.PurchaseState.PENDING -> StorePurchaseState.Pending
            else -> StorePurchaseState.Unspecified
        }
        if (state == StorePurchaseState.Pending) {
            message = "Google Play is waiting for payment approval. Nothing is granted until it completes."
            return null
        }
        if (state != StorePurchaseState.Purchased) return null
        val verification = runCatching { verifier.verify(PurchaseFacts(productId, kind, purchase.purchaseToken, purchase.orderId)) }
            .getOrElse { PurchaseVerification.Failed(it.message ?: "the server could not be reached") }
        when (PurchasePolicy.action(kind, state, purchase.isAcknowledged, verification)) {
            PurchaseAction.Acknowledge -> {
                val ack = client.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build())
                message = if (ack.responseCode == BillingClient.BillingResponseCode.OK) "Your plan is active." else "The server granted your plan; Google Play will be confirmed on the next refresh."
            }
            PurchaseAction.Consume -> {
                val consumed = client.consumePurchase(ConsumeParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build())
                message = if (consumed.billingResult.responseCode == BillingClient.BillingResponseCode.OK) "Spatter credits added by the server." else "The server added your credits; Google Play will be confirmed on the next refresh."
            }
            PurchaseAction.Hold -> message = when (verification) {
                PurchaseVerification.NotConfigured -> "Google Play reports a purchase this build cannot verify yet. Nothing was granted; Google Play refunds it automatically if it is not confirmed within three days."
                is PurchaseVerification.Rejected -> "The server did not accept this purchase (${verification.reason}). Nothing was granted."
                is PurchaseVerification.Failed -> "The purchase could not be verified (${verification.reason}). Nothing was granted yet; try Refresh."
                is PurchaseVerification.Granted -> message
            }
        }
        return (verification as? PurchaseVerification.Granted)?.tier?.takeIf { kind == PurchaseKind.Subscription }
    }

    private fun publish() = PlanRuntime.reportStore(loaded = status == StoreStatus.Loaded && subscriptions.size >= 2, purchasable = purchasesAvailable)
}

/** One repository per process; started from [com.stickdeath.studio.StudioApplication]. */
object BillingRuntime {
    @Volatile private var repository: BillingRepository? = null
    fun repository(context: Context): BillingRepository = repository ?: synchronized(this) {
        repository ?: BillingRepository(context.applicationContext, PlanRuntime.catalog).also { repository = it }
    }
}
