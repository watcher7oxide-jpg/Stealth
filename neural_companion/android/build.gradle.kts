allprojects {
    repositories {
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
    project.evaluationDependsOn(":app")

    configurations.all {
        resolutionStrategy {
            force("androidx.core:core:1.13.1")
        }
    }

    afterEvaluate {
        if (extensions.findByName("android") != null) {
            extensions.configure<com.android.build.gradle.BaseExtension> {
                if (namespace == null) {
                    namespace = project.group.toString()
                }

                lintOptions {
                    isAbortOnError = false
                    isCheckReleaseBuilds = false
                }
            }
        }

        tasks.configureEach {
            if (
                name.contains("Lint", ignoreCase = true) ||
                name.contains("AarMetadata", ignoreCase = true)
            ) {
                enabled = false
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
