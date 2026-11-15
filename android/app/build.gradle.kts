import com.android.apksig.ApkSigner
import com.android.apksig.ApkVerifier
import com.android.apksig.SigningCertificateLineage
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
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
        "rotationKeyAlias",
        "signingLineage",
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
        // Flutter's per-ABI splits configure the filters; AGP rejects both.
        if (project.findProperty("split-per-abi")?.toString() != "true") {
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
            }
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
    implementation("com.google.firebase:firebase-messaging")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

// AGP's signing DSL does not expose certificate lineage. Re-sign its final APKs
// before Flutter copies them, keeping Android 12 and Android 13+ on one lineage.
val signReleaseApks = tasks.register("signReleaseApks") {
    dependsOn("packageRelease")
    inputs.file(keystorePropertiesFile)
    if (missingReleaseSigningProperties.isEmpty()) {
        inputs.file(file(keystoreProperties.getProperty("storeFile")))
        inputs.file(file(keystoreProperties.getProperty("signingLineage")))
    }
    doLast {
        val store = KeyStore.getInstance("PKCS12")
        file(keystoreProperties.getProperty("storeFile")).inputStream().use {
            store.load(it, keystoreProperties.getProperty("storePassword").toCharArray())
        }
        val signers = listOf("keyAlias", "rotationKeyAlias").map { property ->
            val alias = keystoreProperties.getProperty(property)
            val key = store.getKey(alias, keystoreProperties.getProperty("keyPassword").toCharArray()) as PrivateKey
            val certificates = store.getCertificateChain(alias).map { it as X509Certificate }
            ApkSigner.SignerConfig.Builder(alias, key, certificates).build()
        }
        val lineage = SigningCertificateLineage.readFromFile(file(keystoreProperties.getProperty("signingLineage")))
        val apks = fileTree(layout.buildDirectory.dir("outputs/apk/release")) { include("*.apk") }.files
        check(apks.isNotEmpty()) { "No release APKs found for signing" }
        apks.forEach { apk ->
            val signedApk = File(apk.parentFile, "${apk.name}.signed")
            val idsig = File(apk.parentFile, "${apk.name}.idsig")
            ApkSigner.Builder(signers)
                .setInputApk(apk)
                .setOutputApk(signedApk)
                .setV4SignatureOutputFile(idsig)
                .setSigningCertificateLineage(lineage)
                .setMinSdkVersionForRotation(33)
                .setV1SigningEnabled(false)
                .setV2SigningEnabled(true)
                .setV3SigningEnabled(true)
                .setV4SigningEnabled(true)
                .setV4ErrorReportingEnabled(true)
                .build().sign()
            // Explicitly check v2 too: the verifier normally skips it when the
            // manifest's minSdk is already covered by v3.
            val result = ApkVerifier.Builder(signedApk)
                .setMinCheckedPlatformVersion(24)
                .setV4SignatureFile(idsig).build().verify()
            check(result.isVerified && result.isVerifiedUsingV2Scheme && result.isVerifiedUsingV3Scheme &&
                result.isVerifiedUsingV31Scheme && result.isVerifiedUsingV4Scheme) {
                "Release APK verification failed: v2=${result.isVerifiedUsingV2Scheme}, " +
                    "v3=${result.isVerifiedUsingV3Scheme}, v3.1=${result.isVerifiedUsingV31Scheme}, " +
                    "v4=${result.isVerifiedUsingV4Scheme}, errors=${result.allErrors}"
            }
            Files.move(signedApk.toPath(), apk.toPath(), StandardCopyOption.REPLACE_EXISTING)
            logger.lifecycle("Verified ${apk.name}: v2, v3, v3.1 and v4")
        }
    }
}

tasks.matching { it.name == "assembleRelease" }.configureEach {
    dependsOn(signReleaseApks)
    doLast {
        copy {
            from(layout.buildDirectory.dir("outputs/apk/release")) { include("*.apk.idsig") }
            into(layout.buildDirectory.dir("outputs/flutter-apk"))
        }
    }
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
