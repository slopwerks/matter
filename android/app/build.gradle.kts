import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The same public Firebase options are supplied to Dart and native startup.
// PushFirebaseApplication also uses these when no runtime config is saved.
val pushDefines =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.associate { encoded ->
            val value = String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
            val parts = value.split("=", limit = 2)
            parts[0] to parts.getOrElse(1) { "" }
        }.orEmpty()
val firebaseResources =
    mapOf(
        "google_app_id" to "MATTER_FIREBASE_APP_ID",
        "google_api_key" to "MATTER_FIREBASE_API_KEY",
        "gcm_defaultSenderId" to "MATTER_FIREBASE_SENDER_ID",
        "project_id" to "MATTER_FIREBASE_PROJECT_ID",
    )

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}
val releaseSigningProperties =
    listOf(
        "storeFile",
        "storePassword",
        "keyAlias",
        "keyPassword",
    )
val missingReleaseSigningProperties =
    releaseSigningProperties.filter {
        (keystoreProperties[it] as String?).isNullOrBlank()
    }
val configuredNdkVersion =
    System.getenv("ANDROID_NDK_VERSION")
        ?: project.findProperty("android.ndkVersion") as String?
        ?: flutter.ndkVersion

android {
    namespace = "moe.aks.matter"
    compileSdk = 37
    ndkVersion = configuredNdkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "moe.aks.matter"
        minSdk = 31
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (firebaseResources.values.all { !pushDefines[it].isNullOrBlank() }) {
            firebaseResources.forEach { (resource, define) ->
                resValue("string", resource, pushDefines.getValue(define))
            }
        }
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists() && missingReleaseSigningProperties.isEmpty()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "Release signing requires android/key.properties; refusing to use the debug key.",
                )
            }
            if (missingReleaseSigningProperties.isNotEmpty()) {
                throw GradleException(
                    "Missing release signing properties: ${missingReleaseSigningProperties.joinToString()}",
                )
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-common")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

val rustSoFile = file("src/main/jniLibs/arm64-v8a/librust_lib_matter.so")

tasks.register<Exec>("buildRust") {
    val isRelease = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
    workingDir = file("../../rust")
    doFirst {
        if (rustSoFile.exists() && !rustSoFile.delete()) {
            throw GradleException("Failed to remove stale Rust library: ${rustSoFile.absolutePath}")
        }
    }
    if (isRelease) {
        commandLine("cargo", "ndk", "-t", "arm64-v8a", "-o", "../android/app/src/main/jniLibs", "build", "--release")
    } else {
        commandLine("cargo", "ndk", "-t", "arm64-v8a", "-o", "../android/app/src/main/jniLibs", "build")
    }
}

tasks.register<Exec>("stripRustSo") {
    dependsOn("buildRust")
    val llvmStrip = file("${android.ndkDirectory}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip")
    commandLine(llvmStrip, "--strip-all", rustSoFile.absolutePath)
    onlyIf { rustSoFile.exists() }
}

tasks.named("preBuild").configure {
    dependsOn("stripRustSo")
}
