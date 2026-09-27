plugins {
    kotlin("multiplatform") version "2.4.20"
}

kotlin {
    linuxX64 {
        binaries.executable {
            entryPoint = "main"
            // `-Prt.static=true`: a static executable against the HOST's glibc, the recipe that reaches
            // a `FROM scratch` image (sborka, docs/research/research-static-binary.md, 1.5a) - minus the
            // two flags the static-linking patch makes unnecessary, `--no-dynamic-linker` and the
            // `linkerKonanFlags` override without `-Bdynamic`. The paths are Ubuntu 24.04's; a host
            // with another gcc passes -Prt.hostGccDir.
            if (providers.gradleProperty("rt.static").orNull.toBoolean()) {
                val gccDir = providers.gradleProperty("rt.hostGccDir").orNull ?: "usr/lib/gcc/x86_64-linux-gnu/13"
                val libDir = "/usr/lib/x86_64-linux-gnu"
                // `-Prt.staticRecipe=full`: the same link on a STOCK compiler, with the two flags the patch
                // makes unnecessary passed by hand. It is the control for the patch: both must produce
                // the same binary.
                val byHand = providers.gradleProperty("rt.staticRecipe").orNull == "full"
                if (byHand) linkerOpts("-static", "--no-dynamic-linker", "-L$libDir") else linkerOpts("-static", "-L$libDir")
                freeCompilerArgs += "-Xoverride-konan-properties=" +
                    "targetSysRoot.linux_x64=/;" +
                    "crtFilesLocation.linux_x64=${libDir.removePrefix("/")};" +
                    "libGcc.linux_x64=$gccDir;" +
                    "linkerGccFlags=-lgcc -lgcc_eh -lc" +
                    (if (byHand) ";linkerKonanFlags.linux_x64=-Bstatic -lstdc++ -ldl -lm -lpthread " +
                        "--defsym __cxa_demangle=Konan_cxa_demangle --gc-sections" else "")
            }
        }
    }
    // On a clean machine, `-Prt.llvmVariant=dev` makes this one build fetch the LLVM bundle the runtime
    // itself is built with (konan.properties names it `llvm.linux_x64.dev`), which scripts/build-dist.sh
    // needs and an ordinary build never downloads. Never set for a build whose binary is compared.
    providers.gradleProperty("rt.llvmVariant").orNull?.let { variant ->
        compilerOptions { freeCompilerArgs.add("-Xllvm-variant=$variant") }
    }
}
