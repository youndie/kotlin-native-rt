// The consumer iconv-unicode exists for: ktor-io in a statically linked executable. -Piconv=true adds
// the library - built one directory up, or the published one with -Piconv.version; without it this
// is the control, which must fail.
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
        // -Piconv.version=<v>: the published library instead of the build one directory up
        maven("https://reposilite.kotlin.website/snapshots") {
            name = "iconv-unicode"
            mavenContent { includeGroup("io.github.youndie.kotlin-native-rt") }
        }
        mavenCentral()
    }
}

if (providers.gradleProperty("iconv.version").orNull == null) includeBuild("..")

rootProject.name = "iconv-check"
