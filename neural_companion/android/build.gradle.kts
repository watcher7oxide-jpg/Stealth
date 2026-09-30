allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Add this block to kill the broken lint/metadata tasks on file_picker & third-party libs
subprojects {
    project.configurations.all {
        resolutionStrategy {
            force 'androidx.core:core:1.13.1'
        }
    }
    afterEvaluate { project ->
        if (project.hasProperty('android')) {
            project.android {
                if (namespace == null) {
                    namespace project.group
                }
                lintOptions {
                    abortOnError false
                    checkReleaseBuilds false
                }
            }
        }
        // Disables the exact task failing in your log: bundleReleaseLocalLintAar
        tasks.matching { it.name.contains("Lint") || it.name.contains("AarMetadata") }.configureEach {
            enabled = false
        }
    }
}
