// KT-89365 in isolation: resident memory against the number of threads that have allocated.
// `-Prss.pageSize=16` builds the page-size workaround; the distribution under test comes from
// `-Pkotlin.native.home` or `-Pkotlin.native.version`.
plugins { kotlin("multiplatform") version "2.4.20" }
kotlin {
    linuxX64 {
        binaries.executable {
            entryPoint = "main"
            providers.gradleProperty("rss.pageSize").orNull?.let { binaryOption("fixedBlockPageSize", it) }
        }
    }
}
