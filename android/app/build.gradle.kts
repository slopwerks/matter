import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}
val releaseSigningProperties = listOf(
    "storeFile",
    "storePassword",
    "keyAlias",
    "keyPassword",
)
val missingReleaseSigningProperties = releaseSigningProperties.filter {
    (keystoreProperties[it] as String?).isNullOrBlank()
}
val configuredNdkVersion =
    System.getenv("ANDROID_NDK_VERSION")
        ?: project.findProperty("android.ndkVersion") as String?
        ?: flutter.ndkVersion

android {
    namespace = "moe.aks.matter"
    compileSdk = 36
    ndkVersion = configuredNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "moe.aks.matter"
        minSdk = 31
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
