plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.matter"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.matter"
        minSdk = 31
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
