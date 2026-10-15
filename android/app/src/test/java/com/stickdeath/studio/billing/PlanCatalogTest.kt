package com.stickdeath.studio.billing

import com.stickdeath.studio.BrushFamily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlanCatalogTest {
    private val real = PlanCatalog.load("com.stickdeath.studio.creator.monthly", "com.stickdeath.studio.pro.monthly", "com.stickdeath.studio.credits.small")
    private val placeholder = PlanCatalog.load(PlanCatalog.PLACEHOLDER_CREATOR_MONTHLY, PlanCatalog.PLACEHOLDER_PRO_MONTHLY, PlanCatalog.PLACEHOLDER_CREDIT_PACK)

    @Test fun freeLimitsMatchTheOwnerDecision() {
        val free = StudioPlanLimits.Free
        assertEquals(3, free.maxLayers)
        assertEquals(1, free.maxOnionSkinBack); assertEquals(0, free.maxOnionSkinForward)
        assertFalse(free.customCanvasSize)
        assertEquals(1280, free.maxExportLongEdge); assertTrue(free.exportWatermark)
        assertFalse(free.audioImport); assertFalse(free.soundLibrary); assertFalse(free.advancedTools)
        assertFalse(free.pngSequenceExport); assertFalse(free.sdiChannelSubmission); assertFalse(free.spatterActive)
        assertEquals(StudioPlanLimits.Unrestricted, StudioPlanLimits.forTier(PlanTier.Creator))
        assertEquals(StudioPlanLimits.Unrestricted, StudioPlanLimits.forTier(PlanTier.Pro))
        assertEquals(StudioPlanLimits.Free, StudioPlanLimits.forTier(PlanTier.Free))
    }

    @Test fun enforcementNeedsRealProductsLoadedStoreAndPurchasing() {
        assertTrue(placeholder.usesPlaceholderIdentifiers)
        assertFalse(StudioPlanLimits.enforcing(placeholder, storeLoaded = true, purchasesAvailable = true))
        assertFalse(StudioPlanLimits.enforcing(real, storeLoaded = false, purchasesAvailable = true))
        assertFalse(StudioPlanLimits.enforcing(real, storeLoaded = true, purchasesAvailable = false))
        assertTrue(StudioPlanLimits.enforcing(real, storeLoaded = true, purchasesAvailable = true))
        // Until enforcement, a Free account keeps the full Studio.
        assertEquals(StudioPlanLimits.Unrestricted, StudioPlanLimits.effective(PlanTier.Free, enforcing = false))
        assertEquals(StudioPlanLimits.Free, StudioPlanLimits.effective(PlanTier.Free, enforcing = true))
        assertEquals(StudioPlanLimits.Unrestricted, StudioPlanLimits.effective(PlanTier.Creator, enforcing = true))
    }

    @Test fun catalogueRefusesBlankMalformedAndDuplicateIds() {
        assertTrue(PlanCatalog.load("", "", "").usesPlaceholderIdentifiers)
        assertTrue(PlanCatalog.load(null, null, null).creditPacksUsePlaceholders)
        assertTrue(PlanCatalog.load("Bad Id!", "com.stickdeath.studio.pro.monthly", null).usesPlaceholderIdentifiers)
        val duplicate = PlanCatalog.load("com.same.id", "com.same.id", null)
        assertTrue(duplicate.usesPlaceholderIdentifiers)
        assertEquals(listOf(PlanTier.Free), duplicate.plans.map { it.tier })
        assertFalse(real.usesPlaceholderIdentifiers); assertFalse(real.creditPacksUsePlaceholders)
        assertEquals(listOf("com.stickdeath.studio.creator.monthly", "com.stickdeath.studio.pro.monthly"), real.subscriptionProductIds)
        assertEquals(PlanTier.Pro, real.tier("com.stickdeath.studio.pro.monthly"))
        assertEquals(PlanTier.Free, real.tier("com.unknown.product")) // unknown ids grant nothing
        assertTrue(real.isCreditPack("com.stickdeath.studio.credits.small"))
        val packs = PlanCatalog.load(null, null, " a.pack.one , a.pack.two,a.pack.one,,")
        assertEquals(listOf("a.pack.one", "a.pack.two"), packs.creditProductIds)
    }

    @Test fun trialAndOwnKeyBelongToPaidPlansOnly() {
        assertFalse(PlanTier.Free.offersTrial); assertTrue(PlanTier.Creator.offersTrial); assertTrue(PlanTier.Pro.offersTrial)
        assertFalse(PlanTier.Free.includesOwnAIKey); assertTrue(PlanTier.Creator.includesOwnAIKey)
        assertEquals(PlanTier.Pro, PlanTier.best(PlanTier.Creator, null, PlanTier.Pro))
        assertEquals(PlanTier.Free, PlanTier.best(null, null))
        assertNull(PlanTier.fromWire("enterprise"))
        assertEquals(PlanTier.Creator, PlanTier.fromWire(" Creator "))
    }

    @Test fun layersOnlyCapGrowth() {
        val free = StudioPlanLimits.Free
        assertTrue(free.allowsNewLayer(2)); assertFalse(free.allowsNewLayer(3))
        // A project that already has five layers still edits and may shrink, but cannot grow.
        assertTrue(free.allowsLayerChange(5, 5)); assertTrue(free.allowsLayerChange(5, 4)); assertFalse(free.allowsLayerChange(5, 6))
        assertTrue(StudioPlanLimits.Unrestricted.allowsNewLayer(31))
    }

    @Test fun onionCanvasAndBrushRules() {
        val free = StudioPlanLimits.Free
        assertTrue(free.allowsOnion(1, 0)); assertFalse(free.allowsOnion(2, 0)); assertFalse(free.allowsOnion(1, 1))
        assertEquals(1 to 0, free.clampedOnion(3, 2))
        assertEquals(3 to 2, StudioPlanLimits.Unrestricted.clampedOnion(3, 2))
        assertTrue(free.allowsCanvasSize(1080, 1920)); assertFalse(free.allowsCanvasSize(1000, 1000))
        assertTrue(free.allowsCanvasChange(1000, 1000, 1000, 1000)) // existing custom size keeps working
        assertFalse(free.allowsCanvasChange(1080, 1920, 1000, 1000))
        assertTrue(StudioPlanLimits.Unrestricted.allowsCanvasSize(1000, 1000))
        val basic = BrushFamily.entries.filter { free.allowsBrush(it.name) }.map { it.name }.toSet()
        assertEquals(setOf("Round", "Stipple", "Grain", "RoughPen", "Calligraphy", "DipPen"), basic)
        assertTrue(BrushFamily.entries.all { StudioPlanLimits.Unrestricted.allowsBrush(it.name) })
    }

    @Test fun freeExportsFit720pWithEvenMp4Dimensions() {
        val free = StudioPlanLimits.Free
        assertEquals(ExportRendition(720, 1280, 1280f / 1920f, true), free.exportRendition(1080, 1920, evenDimensions = true))
        assertEquals(ExportRendition(1280, 720, 1280f / 1920f, true), free.exportRendition(1920, 1080, evenDimensions = false))
        val insta = free.exportRendition(1080, 1350, evenDimensions = true)
        assertEquals(1024 to 1280, insta.width to insta.height)
        val small = free.exportRendition(640, 480, evenDimensions = true)
        assertEquals(ExportRendition(640, 480, 1f, true), small); assertFalse(small.resized)
        val odd = free.exportRendition(1999, 1001, evenDimensions = true)
        assertEquals(0, odd.width % 2); assertEquals(0, odd.height % 2); assertTrue(odd.width <= 1280)
        assertEquals(ExportRendition(1920, 1080, 1f, false), StudioPlanLimits.Unrestricted.exportRendition(1920, 1080, evenDimensions = true))
    }

    @Test fun watermarkSitsSmallAtTheBottomRight() {
        val r = ExportWatermarkLayout.rect(720, 1280)
        assertEquals(36, r.height) // 5% of the shorter edge
        assertTrue(r.right <= 720 && r.bottom <= 1280 && r.left > 720 / 2 && r.top > 1280 / 2)
        assertTrue(r.width * r.height < 720 * 1280 / 100)
        val tiny = ExportWatermarkLayout.rect(16, 16)
        assertTrue(tiny.left >= 0 && tiny.top >= 0 && tiny.right <= 16 && tiny.bottom <= 16)
    }

    private fun usage(plan: PlanTier, remaining: Int? = null, credits: Int? = null, available: Boolean? = null) =
        SpatterUsage(plan, plan == PlanTier.Pro, null, remaining, credits, available, null, false)

    @Test fun spatterGateFollowsPlanAndCredits() {
        val free = StudioPlanLimits.Free; val open = StudioPlanLimits.Unrestricted
        // Free without credits: upgrade note, nothing sent, whether or not the Studio enforces.
        assertEquals(SpatterGate.UpgradeNote, SpatterGate.decide(free, usage(PlanTier.Free, credits = 0), false))
        assertEquals(SpatterGate.UpgradeNote, SpatterGate.decide(open, usage(PlanTier.Free), false))
        // Free with credits: pay as you go, counted by the server.
        assertEquals(SpatterGate.Send(payAsYouGo = true), SpatterGate.decide(free, usage(PlanTier.Free, credits = 4), false))
        assertEquals(SpatterGate.Send(payAsYouGo = true), SpatterGate.decide(free, usage(PlanTier.Free, available = true), false))
        assertEquals(SpatterGate.UpgradeNote, SpatterGate.decide(free, usage(PlanTier.Free, credits = 4, available = false), false))
        // Unknown plan: enforcing Free waits or shows the note; otherwise the server decides.
        assertEquals(SpatterGate.Checking, SpatterGate.decide(free, null, true))
        assertEquals(SpatterGate.UpgradeNote, SpatterGate.decide(free, null, false))
        assertEquals(SpatterGate.Send(payAsYouGo = false), SpatterGate.decide(open, null, false))
        // Creator: allowance, then credits.
        assertEquals(SpatterGate.Send(payAsYouGo = false), SpatterGate.decide(open, usage(PlanTier.Creator, remaining = 3), false))
        assertEquals(SpatterGate.AllowanceUsed, SpatterGate.decide(open, usage(PlanTier.Creator, remaining = 0), false))
        assertEquals(SpatterGate.Send(payAsYouGo = true), SpatterGate.decide(open, usage(PlanTier.Creator, remaining = 0, credits = 2), false))
        assertEquals(SpatterGate.Send(payAsYouGo = false), SpatterGate.decide(open, usage(PlanTier.Pro), false))
    }

    @Test fun purchasesAreFinalisedOnlyAfterAServerGrant() {
        val granted = PurchaseVerification.Granted(PlanTier.Creator, null)
        val purchased = StorePurchaseState.Purchased
        assertEquals(PurchaseAction.Acknowledge, PurchasePolicy.action(PurchaseKind.Subscription, purchased, false, granted))
        assertEquals(PurchaseAction.Hold, PurchasePolicy.action(PurchaseKind.Subscription, purchased, true, granted))
        assertEquals(PurchaseAction.Consume, PurchasePolicy.action(PurchaseKind.CreditPack, purchased, false, granted))
        for (v in listOf(PurchaseVerification.NotConfigured, PurchaseVerification.Rejected("no"), PurchaseVerification.Failed("offline"))) {
            assertEquals(PurchaseAction.Hold, PurchasePolicy.action(PurchaseKind.Subscription, purchased, false, v))
            assertEquals(PurchaseAction.Hold, PurchasePolicy.action(PurchaseKind.CreditPack, purchased, false, v))
        }
        assertEquals(PurchaseAction.Hold, PurchasePolicy.action(PurchaseKind.CreditPack, StorePurchaseState.Pending, false, granted))
    }

    @Test fun copyUsesStorePricesOnly() {
        assertEquals("Price shown when configured", PlanCopy.price(null))
        assertEquals("Price shown when configured", PlanCopy.price(" "))
        assertEquals("€5,49 per month", PlanCopy.price("€5,49", "P1M"))
        assertEquals("€5,49", PlanCopy.price("€5,49", null))
        assertEquals("7-day free trial", PlanCopy.trial("P7D"))
        assertEquals("1-month free trial", PlanCopy.trial("P1M"))
        assertNull(PlanCopy.trial(null)); assertNull(PlanCopy.trial("garbage"))
        assertTrue(PlanCopy.usage(usage(PlanTier.Free, credits = 5)).contains("Credits: 5"))
        assertTrue(!PlanCopy.usage(usage(PlanTier.Free)).contains("Credits")) // absent balance is not invented
        val allPlanText = (PlanCatalog.freeEntitlements + PlanCatalog.creatorEntitlements + PlanCatalog.proEntitlements).joinToString { it.text }
        assertFalse(allPlanText.contains("4.99") || allPlanText.contains("9.99"))
    }
}
