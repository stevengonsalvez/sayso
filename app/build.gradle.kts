import java.net.URI
import java.security.MessageDigest

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// sherpa-onnx has no Maven artifact; fetch the official AAR from GitHub releases.
val sherpaVersion = "1.13.8"
val sherpaSha256 = "633c24321e06b1fe79feafa03ea16cbc0f8a286641e2da3559bac91bdb13bd96"
val sherpaAar = layout.projectDirectory.file("libs/sherpa-onnx-$sherpaVersion.aar")
val fetchSherpaOnnx by tasks.registering {
    outputs.file(sherpaAar)
    doLast {
        val target = sherpaAar.asFile
        // Already in place: trust it rather than re-hashing 30 MB on every build.
        if (target.exists()) return@doLast

        target.parentFile.mkdirs()
        val url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$sherpaVersion/sherpa-onnx-$sherpaVersion.aar"
        logger.lifecycle("Downloading $url")

        // Native code from an unauthenticated redirect chain, so it is verified before it is
        // named as the artifact the build compiles against.
        val part = target.resolveSibling("${target.name}.part")
        try {
            URI(url).toURL().openStream().use { input -> part.outputStream().use { input.copyTo(it) } }
            val digest = MessageDigest.getInstance("SHA-256").digest(part.readBytes())
                .joinToString("") { "%02x".format(it) }
            if (digest != sherpaSha256) {
                throw GradleException(
                    "sherpa-onnx AAR checksum mismatch; delete app/libs and retry, " +
                        "or place the AAR manually at app/libs/sherpa-onnx-$sherpaVersion.aar",
                )
            }
            if (!part.renameTo(target)) throw GradleException("Could not move the sherpa-onnx AAR into app/libs")
        } finally {
            part.delete()
        }
    }
}
tasks.named("preBuild") { dependsOn(fetchSherpaOnnx) }

val releaseKeystore: String? = System.getenv("SAYSO_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }

android {
    namespace = "com.shotclubhouse.sayso"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.shotclubhouse.sayso"
        minSdk = 30
        targetSdk = 36
        versionCode = 7
        versionName = "1.0.6"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    signingConfigs {
        // Release signing material comes from the environment, never from the repository.
        // With SAYSO_KEYSTORE_PATH unset there is simply no config, so a local
        // assembleRelease still builds and just produces an unsigned APK.
        releaseKeystore?.let { keystore ->
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("SAYSO_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("SAYSO_KEY_ALIAS")
                keyPassword = System.getenv("SAYSO_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = signingConfigs.findByName("release")
        }
    }

    buildFeatures { compose = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs.useLegacyPackaging = false
    }
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation(files(sherpaAar))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.extended)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.commons.compress)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
