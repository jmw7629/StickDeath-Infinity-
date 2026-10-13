package com.stickdeath.studio

import android.app.Application

/** Installs the local, redacted crash reporter before any activity runs. No SDK, no upload. */
class StudioApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        LocalCrashReporter(this).install()
    }
}
