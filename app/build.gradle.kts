plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The app ships rombooter-setup.sh as an asset so it can set up distros in Termux by itself.
val rbAssets = layout.buildDirectory.dir("generated/rombooter-assets")
val copySetupScript by tasks.registering(Copy::class) {
    from(rootProject.file("rombooter-setup.sh"))
    into(rbAssets)
}
tasks.named("preBuild") { dependsOn(copySetupScript) }

android {
    namespace = "org.rombooter"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.rombooter"
        minSdk = 26
        targetSdk = 35
        versionCode = 6
        versionName = "1.3.1"
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    sourceSets["main"].assets.srcDir(rbAssets)
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
