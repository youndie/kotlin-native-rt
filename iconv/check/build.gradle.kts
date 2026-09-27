plugins {
    kotlin("multiplatform") version "2.4.20"
}

kotlin {
    linuxX64 {
        binaries.executable {
            entryPoint = "main"
            // the static recipe of consumer-check, on a distribution with 0003-static-executable
            val gccDir = providers.gradleProperty("rt.hostGccDir").orNull ?: "usr/lib/gcc/x86_64-linux-gnu/13"
            val libDir = "/usr/lib/x86_64-linux-gnu"
            linkerOpts("-static", "-L$libDir")
            freeCompilerArgs += "-Xoverride-konan-properties=" +
                "targetSysRoot.linux_x64=/;" +
                "crtFilesLocation.linux_x64=${libDir.removePrefix("/")};" +
                "libGcc.linux_x64=$gccDir;" +
                "linkerGccFlags=-lgcc -lgcc_eh -lc"
        }
    }
    sourceSets {
        linuxX64Main.dependencies {
            implementation("io.ktor:ktor-io:3.5.2")
            if (providers.gradleProperty("iconv").orNull.toBoolean()) {
                implementation("io.github.youndie.kotlin-native-rt:iconv-unicode" +
                    (providers.gradleProperty("iconv.version").orNull?.let { ":$it" } ?: ""))
            }
        }
    }
}
