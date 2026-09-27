// iconv-unicode: iconv for the Unicode charsets without glibc's gconv modules, as a klib whose only
// content is src/iconv_unicode.c and the linker options that route iconv through it.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        // a patched distribution, when -Pkotlin.native.version names one (check/ passes it through)
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

rootProject.name = "iconv-unicode"
