plugins {
    kotlin("multiplatform") version "2.4.20"
}

kotlin {
    linuxX64 {
        binaries.executable {
            entryPoint = "main"
        }
    }
}
