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
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
