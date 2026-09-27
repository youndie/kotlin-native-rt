plugins {
    kotlin("multiplatform") version "2.4.20"
}

kotlin {
    linuxX64 {
        binaries.executable {
            entryPoint = "main"
        }
    }
    // On a clean machine, `-Prt.llvmVariant=dev` makes this one build fetch the LLVM bundle the runtime
    // itself is built with (konan.properties names it `llvm.linux_x64.dev`), which scripts/build-dist.sh
    // needs and an ordinary build never downloads. Never set for a build whose binary is compared.
    providers.gradleProperty("rt.llvmVariant").orNull?.let { variant ->
        compilerOptions { freeCompilerArgs.add("-Xllvm-variant=$variant") }
    }
}
