import com.android.build.gradle.BaseExtension
import java.util.Properties
import java.io.File

// The 16 KB page-size fplayer rebuild is not published to any remote repository:
// it ships inside the flv_lzc package, under its own android/libs Maven layout.
// Gradle resolves the *app's* runtime classpath against the repositories of the
// project that owns the configuration, so the plugin's own `repositories {}`
// block cannot help here — the app has to declare that repository itself.
//
// flv_lzc arrives ONLY as a transitive dependency of the FVP backend. The
// aggressive single-kernel build no longer ships that backend, so the Gradle
// plugin project is absent; looking it up with project(...) would fail the
// whole build with "Project with path ':flv_lzc' could not be found".
// findProject + conditional keeps this file working for both configurations.
val flvLibs = rootProject.findProject(":flv_lzc")?.projectDir?.resolve("libs")

allprojects {
    repositories {
        flvLibs?.let { libs ->
            maven(libs) {
                content {
                    includeModule("io.github.flutterplayer", "fplayer-core")
                }
            }
        }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    afterEvaluate {
        if (project.name != "app") {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.apply {
                compileSdkVersion(37)
                if (namespace.isNullOrBlank()) {
                    namespace = project.group.toString()
                }
            }
        }
    }
}

subprojects {
    if (project.name != "app") {
        evaluationDependsOn(":app")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
