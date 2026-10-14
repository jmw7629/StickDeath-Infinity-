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
    }
}
