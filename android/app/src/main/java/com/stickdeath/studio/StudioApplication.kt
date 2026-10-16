package com.stickdeath.studio

import android.app.Application
import com.stickdeath.studio.diagnostics.DiagnosticsCounter
import com.stickdeath.studio.diagnostics.DiagnosticsStore

/** Installs the local, redacted crash reporter before any activity runs. No SDK, no upload. */
class StudioApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        LocalCrashReporter(this).install()
        // Opt-in, count-only diagnostics (#291): records nothing unless the member switched it on.
        DiagnosticsStore(this).apply { installBreadcrumbs(); record(DiagnosticsCounter.AppLaunch) }
        // Plan catalogue: contacts Google Play only when the build names real product ids, so the
        // Studio limits are known before the first project opens. Placeholder builds stay offline.
        if (!com.stickdeath.studio.billing.PlanRuntime.catalog.usesPlaceholderIdentifiers || !com.stickdeath.studio.billing.PlanRuntime.catalog.creditPacksUsePlaceholders) {
            com.stickdeath.studio.billing.BillingRuntime.repository(this).start()
        }
    }
}
