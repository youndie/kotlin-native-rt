// The smallest consumer of a patched distribution: no conventions, no other dependency, so a failure
// here is about the distribution and the Kotlin Gradle plugin, not about anything built on them.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        // Where the patched distribution comes from: a local directory while it is unpublished,
        // reposilite once it is. Admits the -yrt versions of that one module and nothing else, so the
        // stock distribution can only come from Central.
        providers.gradleProperty("rt.repo").orNull?.let { url ->
            maven(url) {
                name = "kotlin-native-rt"
                mavenContent {
                    includeVersionByRegex("org\\.jetbrains\\.kotlin", "kotlin-native-prebuilt", ".*-yrt\\.[0-9]+")
                }
            }
        }
        mavenCentral()
    }
}

rootProject.name = "consumer-check"
