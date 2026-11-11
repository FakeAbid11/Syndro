plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// One UI, one source of truth: the browser-mode web app is copied into the APK
// assets at build time instead of being duplicated in this repository.
val webUiSource = rootProject.file("../desktop/web")
val syncWebUi = tasks.register<Copy>("syncWebUi") {
    from(webUiSource)
    into(layout.buildDirectory.dir("generated/webui/web"))
    doFirst {
        if (!webUiSource.isDirectory) {
            throw GradleException("Missing web UI at ${webUiSource.absolutePath}")
        }
    }
}

android {
    namespace = "dev.syndro.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.syndro.app"
        minSdk = 29
        targetSdk = 35
        versionCode = 2
        versionName = "0.1.1"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets.getByName("main").assets.srcDir(layout.buildDirectory.dir("generated/webui"))

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

tasks.matching { it.name.endsWith("Assets") }.configureEach { dependsOn(syncWebUi) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")

    implementation("com.google.zxing:core:3.5.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
