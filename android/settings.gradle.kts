pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.3" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")

// Use AGP's built-in Kotlin without modifying the shared Pub packages.
// These scripts retain the upstream plugin sources and Android dependencies.
mapOf(
    "desktop_drop" to "0.8.4",
    "flutter_image_compress_common" to "1.1.1",
    "photo_manager" to "3.12.0",
).forEach { (name, expectedVersion) ->
    val plugin = project(":$name")
    val pubspec = plugin.projectDir.parentFile.resolve("pubspec.yaml").readText()
    val version = Regex("""(?m)^version:\s*['"]?([^'"\s]+)""").find(pubspec)?.groupValues?.get(1)
    check(version == expectedVersion) {
        "Update android/plugins/$name.gradle for $name $version (verified with $expectedVersion)"
    }
    plugin.buildFileName = file("plugins/$name.gradle").relativeTo(plugin.projectDir).path
}
