plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}
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
    }
    // Reuse the licensed native catalogue; no duplicate asset checkout.
    sourceSets.getByName("main").assets.srcDir("../../StickDeathInfinity/Resources/StudioSounds")
    sourceSets.getByName("main").assets.srcDir(generatedStudioAssets)
    androidResources { noCompress += listOf("wav", "m4a") }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
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
