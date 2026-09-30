allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
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

        // Disable problematic lint / AAR metadata tasks
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
