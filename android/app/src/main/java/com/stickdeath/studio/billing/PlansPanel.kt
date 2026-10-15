package com.stickdeath.studio.billing

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** Plans and Spatter credit packs for the Account panel. Prices, titles and trials come only from
 * Google Play; nothing is purchasable until the server can verify Play purchases. */
@Composable fun PlansSection() {
    val context = LocalContext.current
    val catalog = PlanRuntime.catalog
    val repository = remember { BillingRuntime.repository(context) }
    LaunchedEffect(repository) { repository.start() }
    Text("Plans", style = MaterialTheme.typography.titleMedium)
    Text("Current plan: ${PlanRuntime.tier.title}" + if (PlanRuntime.enforcing) "" else ". Plan limits are not applied yet: every account keeps the full Studio until plans can be purchased on Android.")
    val status = repository.status
    Text(when (status) {
        StoreStatus.NotConfigured -> "Plans are not configured for this build. Nothing is requested from Google Play and nothing is billed."
        StoreStatus.Connecting -> "Loading plans from Google Play…"
        is StoreStatus.Unavailable -> status.reason
        StoreStatus.Loaded -> if (repository.purchasesAvailable) "Prices and trials below come from Google Play." else PlanCopy.PURCHASES_UNAVAILABLE
    })
    val activity = context.activity()
    catalog.plans.forEach { plan ->
        val product = plan.productId?.let { id -> repository.subscriptions.firstOrNull { it.productId == id } }
        Text(plan.name + if (plan.tier == PlanTier.Free) "" else " · " + PlanCopy.price(product?.formattedPrice, product?.billingPeriod),
            style = MaterialTheme.typography.titleSmall)
        product?.trial?.takeIf { plan.tier.offersTrial }?.let { Text(it) }
        plan.entitlements.forEach { Text("• ${it.text}" + if (it.isLive) "" else " (turns on when the server applies your plan)") }
        if (product != null && activity != null && plan.tier != PlanTier.Free) {
            Button({ repository.purchase(activity, product) }, enabled = repository.purchasesAvailable && !repository.busy && PlanRuntime.tier.rank < plan.tier.rank) {
                Text(if (PlanRuntime.tier == plan.tier) "Current plan" else "Choose ${plan.name}")
            }
        }
    }
    Text("Spatter credits", style = MaterialTheme.typography.titleSmall)
    Text("Free accounts can pay as you go: the server spends 1 credit per Spatter prompt. Creator uses credits after its billing-period allowance. The credits each pack adds are listed by Google Play and granted by the server.")
    if (repository.creditPacks.isEmpty()) Text("No credit packs are available on Android yet.")
    repository.creditPacks.forEach { pack ->
        Text("${pack.title} · ${PlanCopy.price(pack.formattedPrice, null)}")
        if (pack.description.isNotBlank()) Text(pack.description, style = MaterialTheme.typography.bodySmall)
        if (activity != null) Button({ repository.purchase(activity, pack) }, enabled = repository.purchasesAvailable && !repository.busy) { Text("Buy") }
    }
    repository.message?.let { Text(it) }
    if (status == StoreStatus.Loaded || status is StoreStatus.Unavailable) TextButton({ repository.start(); repository.refresh() }) { Text("Refresh from Google Play") }
    Text(PlanCopy.MANAGE_NOTE, style = MaterialTheme.typography.bodySmall)
}
