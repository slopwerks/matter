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

android {
    namespace = "moe.aks.matter"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

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
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
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

tasks.register<Exec>("buildRust") {
    val isRelease = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }
    workingDir = file("../../rust")
    if (isRelease) {
        commandLine("cargo", "ndk", "-t", "arm64-v8a", "-o", "../android/app/src/main/jniLibs", "build", "--release")
    } else {
        commandLine("cargo", "ndk", "-t", "arm64-v8a", "-o", "../android/app/src/main/jniLibs", "build")
    }
}

tasks.register<Exec>("stripRustSo") {
    dependsOn("buildRust")
    val soFile = file("src/main/jniLibs/arm64-v8a/librust_lib_matter.so")
    val llvmStrip = file("${android.ndkDirectory}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip")
    commandLine(llvmStrip, "--strip-all", soFile.absolutePath)
    onlyIf { soFile.exists() }
}

tasks.named("preBuild").configure {
    dependsOn("stripRustSo")
}

dependencies {
    // AppCompat provides Theme.AppCompat.* used by image_cropper's uCrop activity.
    implementation("androidx.appcompat:appcompat:1.7.0")
}
