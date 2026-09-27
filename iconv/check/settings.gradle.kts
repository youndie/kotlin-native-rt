// The consumer iconv-unicode exists for: ktor-io in a statically linked executable. -Piconv=true adds
// the library (from the build one directory up); without it this is the control, which must fail.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
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

includeBuild("..")

rootProject.name = "iconv-check"
