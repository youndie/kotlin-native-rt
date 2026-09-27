plugins {
    kotlin("multiplatform") version "2.4.20"
    `maven-publish`
}

group = "io.github.youndie.kotlin-native-rt"
version = providers.gradleProperty("iconv.version").getOrElse("0.0.0-local")

// The C file is compiled by the host's C compiler into a static library the klib carries, rather than
// placed after `---` in the definition: code there is compiled into the program's bitcode, where the
// optimiser makes the `__wrap_*` functions local and the linker no longer finds them. A static
// library stays outside that, and `linkerOpts` travel in the klib's manifest to the link of every
// executable that depends on it. Linux hosts only, as the checks are.
val cDir = layout.buildDirectory.dir("c")
val compileC = tasks.register<Exec>("compileIconvUnicode") {
    val source = layout.projectDirectory.file("src/iconv_unicode.c")
    inputs.file(source)
    outputs.dir(cDir)
    val out = cDir.get().asFile
    doFirst { out.mkdirs() }
    commandLine(
        "sh", "-c",
        "cc -O2 -fPIC -fno-stack-protector -U_FORTIFY_SOURCE -Wall -Wextra -Werror -c \"$1\" -o \"$2/iconv_unicode.o\" " +
            "&& rm -f \"$2/libiconv_unicode.a\" && ar rcs \"$2/libiconv_unicode.a\" \"$2/iconv_unicode.o\"",
        "cc", source.asFile.absolutePath, out.absolutePath,
    )
}

val defPath = layout.buildDirectory.file("cinterop/iconvUnicode.def")
val generateDef = tasks.register("generateDef") {
    val def = defPath
    val libDir = cDir.get().asFile.absolutePath
    outputs.file(def)
    doLast {
        def.get().asFile.writeText(
            """
            |package = io.github.youndie.iconv.unicode.internal
            |staticLibraries = libiconv_unicode.a
            |libraryPaths = $libDir
            |linkerOpts = --wrap=iconv_open --wrap=iconv --wrap=iconv_close
            |
            """.trimMargin()
        )
    }
}

kotlin {
    linuxX64 {
        compilations.getByName("main").cinterops.create("iconvUnicode") {
            defFile(defPath.get().asFile)
        }
    }
}

tasks.matching { it.name == "cinteropIconvUnicodeLinuxX64" }.configureEach { dependsOn(generateDef, compileC) }

// Published by CI on an `iconv-v<version>` tag (.github/workflows/iconv.yml), to the same reposilite
// repository as the distribution; the token's route covers this group.
publishing {
    repositories {
        maven("https://reposilite.kotlin.website/snapshots") {
            name = "reposilite"
            credentials {
                username = providers.environmentVariable("REPOSILITE_USER").orNull
                password = providers.environmentVariable("REPOSILITE_SECRET").orNull
            }
        }
    }
}
