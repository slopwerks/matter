import com.android.build.api.variant.LibraryAndroidComponentsExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    plugins.withId("com.android.library") {
        extensions.getByType<LibraryAndroidComponentsExtension>().finalizeDsl {
            it.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
            it.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            if (name == "firebase_messaging") {
                it.compileSdk = 37
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}
gradle.projectsEvaluated {
    subprojects {
        // Compile plugin sources with the app's Java/Kotlin target, including
        // plugins that still declare the obsolete Java 8 target upstream.
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
        if (name == "firebase_messaging") {
            check(file("../pubspec.yaml").readText().contains("version: 17.1.0")) {
                "Review the Firebase metadata patch for the upgraded firebase_messaging package"
            }
            dependencies.add("implementation", "androidx.core:core:1.16.0")
            dependencies.add("testImplementation", "org.robolectric:robolectric:4.16.1")
            val gateFile = "FlutterFirebaseMessagingBackgroundGate.java"
            val upstreamGate = file("src/main/java/io/flutter/plugins/firebase/messaging/$gateFile")
            tasks.withType<JavaCompile>().matching { !it.name.contains("Test") }.configureEach {
                exclude { it.file.canonicalFile == upstreamGate.canonicalFile }
                source(rootProject.file("patches/firebase_messaging/$gateFile"))
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
