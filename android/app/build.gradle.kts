plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
// Public connection values (never secrets): `-Psdi.supabaseUrl=… -Psdi.supabasePublishableKey=…` or the
// matching SDI_* environment variables. Unset values build an honestly unconnected app with no INTERNET
// permission; the connected manifest (INTERNET only) is merged only when both identity values are set.
fun sdiValue(property: String, environment: String): String {
    val value = (providers.gradleProperty(property).orNull ?: System.getenv(environment) ?: "").trim()
    require(value.none { it == '"' || it == '\\' || it == '$' || it.isISOControl() }) { "$property contains unsupported characters" }
    return value
}
val sdiSupabaseUrl = sdiValue("sdi.supabaseUrl", "SDI_SUPABASE_URL")
val sdiPublishableKey = sdiValue("sdi.supabasePublishableKey", "SDI_SUPABASE_PUBLISHABLE_KEY")
val sdiSpatterUrl = sdiValue("sdi.spatterBackendUrl", "SDI_SPATTER_BACKEND_URL")
val sdiOAuthProviders = sdiValue("sdi.oauthProviders", "SDI_OAUTH_PROVIDERS")
val sdiConnected = sdiSupabaseUrl.isNotEmpty() && sdiPublishableKey.isNotEmpty()
val generatedStudioAssets = layout.buildDirectory.dir("generated/studioAssets")
val stageStudioImages by tasks.registering(Sync::class) {
    from("../../StickDeathInfinity/Resources/StudioImages")
    into(generatedStudioAssets.map { it.dir("StudioImages") })
}
android {
    namespace = "com.stickdeath.studio"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.stickdeath.studio"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SDI_SUPABASE_URL", "\"$sdiSupabaseUrl\"")
        buildConfigField("String", "SDI_SUPABASE_PUBLISHABLE_KEY", "\"$sdiPublishableKey\"")
        buildConfigField("String", "SDI_SPATTER_BACKEND_URL", "\"$sdiSpatterUrl\"")
        buildConfigField("String", "SDI_OAUTH_PROVIDERS", "\"$sdiOAuthProviders\"")
        buildConfigField("boolean", "SDI_NETWORK_DECLARED", sdiConnected.toString())
    }
    if (sdiConnected) {
        sourceSets.getByName("debug").manifest.srcFile("src/connected/AndroidManifest.xml")
        sourceSets.getByName("release").manifest.srcFile("src/connected/AndroidManifest.xml")
    }
    // Reuse the licensed native catalogue; no duplicate asset checkout.
    sourceSets.getByName("main").assets.srcDir("../../StickDeathInfinity/Resources/StudioSounds")
    sourceSets.getByName("main").assets.srcDir(generatedStudioAssets)
    // Shared iOS/Android `.sdi` golden fixtures (Tests/SDIFixtures) feed the instrumented import tests.
    sourceSets.getByName("androidTest").assets.srcDir("../../Tests/SDIFixtures/assets")
    androidResources { noCompress += listOf("wav", "m4a") }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    // Plain JVM unit tests (app/src/test) cover the pure mixing/blend-name math; no Android runtime needed.
    testImplementation("junit:junit:4.13.2")
    // The mockable android.jar stubs org.json; the real library lets JVM tests exercise the retained
    // Swift brush descriptor (SwiftRoundBrush) that the .sdi export round-trips.
    testImplementation("org.json:json:20240303")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("junit:junit:4.13.2")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.ui:ui")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

tasks.named("preBuild").configure { dependsOn(stageStudioImages) }
