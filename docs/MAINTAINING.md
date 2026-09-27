# Maintaining kotlin-native-rt

For whoever builds a new version, moves the series to a new Kotlin, or has to decide whether a check
that went red is the patch or the build. A consumer needs only the [README](../README.md).

## The layout

| path | what it is |
|---|---|
| `patches/kotlin-native/<kotlin>/series` | the patches, in the order they apply |
| `patches/kotlin-native/<kotlin>/modules` | the runtime modules the series must change - and nothing else may |
| `patches/kotlin-native/<kotlin>/compiler` | compiler sources the series changes: `<path> <jar in the distribution> <Kotlin module>` |
| `scripts/build-dist.sh` | builds one version into `build/out` in Maven layout |
| `scripts/rebuild_runtime.py` | rebuilds every runtime bitcode module and compares it with the shipped one |
| `scripts/alloc_tests.py` | builds and runs the runtime's `custom_alloc_test` group outside JetBrains' build |
| `scripts/swap_classes.py` | replaces one source file's classes in a jar, refusing if the class sets differ |
| `scripts/publish.sh` | uploads a version and reads it back through the URL a consumer uses |
| `consumer-check/` | the smallest consumer; `run.sh` and `static.sh` are the checks a version has to pass |
| `acceptance/` | the pause measurement against stock, and its logs |
| `iconv/` | iconv-unicode, a separate library: `iconv` without gconv for static executables; its own [README](../iconv/README.md) and checks |
| `research/` | what was examined and not taken into the series |
| `.github/workflows/publish.yml` | all of the above, in CI |

## Versions

`<kotlin>-yrt.<n>`. A number is never reused (reposilite answers 409 to a second upload), and the
stock version string is never published: a machine that holds the stock distribution in `~/.konan` or
in Gradle's cache would take either one silently. `konan.properties` keeps `compilerVersion=<kotlin>`,
since klibs record the compiler version; the plugin accepts that next to the suffixed version.

**`yrt.0` is the control and is never published** (`publish.sh` and the workflow both refuse it). It
packages the stock runtime exactly as a patched version is packaged, with the compiler sources in
`compiler` recompiled unchanged.

## What a build does, and why each step

`KOTLIN_SRC=~/kotlin-src scripts/build-dist.sh 2.4.20 2` on a Linux x86_64 host with a JDK, the dev
LLVM bundle and the gcc toolchain in `~/.konan/dependencies` (a build of `consumer-check` with
`-Prt.llvmVariant=dev` fetches both), and a clean checkout of `JetBrains/kotlin` at `v<kotlin>` - a
sparse checkout of `kotlin-native/runtime` and `native/utils/src` is enough.

1. **The stock distribution as JetBrains published it**, from Maven Central, checked against its
   digest. Not the unpacked copy in `~/.konan`: the plugin and the compiler add to it
   (`klib/commonized`, caches, markers), and packaging from it made the tarball depend on the machine.
2. **The control:** the stock runtime sources rebuilt with the dev LLVM bundle must match every shipped
   module byte for byte. If they do not, the toolchain has drifted, and a patched module would differ
   for a second reason; the build stops.
3. **The series applied**, the runtime rebuilt, and exactly the modules in `modules` may differ.
4. **The allocator's own tests** on the patched sources. They pass even with the empty-page frees
   removed altogether, which is why 0002 carries a test of its own,
   `HeapFreesEmptyPagesAfterThePause`: it fails on stock ("an empty page was destroyed inside the
   pause"), fails on that mutant ("the detached page was not destroyed by the sweep after the pause"),
   and passes on the series.
5. **The compiler sources** in `compiler` recompiled with the kotlinc of the same release (checked
   against its digest), with `-Xfriend-paths=<jar> -Xlambdas=class -jvm-target 1.8 -module-name <module>`:
   those reproduce the set of classes JetBrains' build made from the file, and `swap_classes.py`
   refuses to swap if the set differs. The bytes differ from JetBrains' - a different build of the
   same compiler - which is why the control recompiles the file too.
6. **The distribution:** stock without `klib/cache` (caches carry the runtime that built them) and
   without `provisioned.ok`, with the changed modules and classes swapped in, the top directory named as
   the plugin names it on disk, and a deterministic archive - sorted, zero times and owners, gzip
   without a timestamp - so the same version is the same bytes on any host. CI and a local build of
   `yrt.1` and of `yrt.2` came out identical.

## The checks a version has to pass

- **`consumer-check/run.sh`** links the smallest consumer against stock and against the version: the
  patched build must differ, and the `yrt.0` control must come out byte for byte the same as stock.
  The first alone proves nothing - packaging or the version string could change the binary; the
  control is what shows the difference is the patches. The allocator's functions are inlined into the
  GC thread in a release binary, so there is no symbol to look for instead.
- **`consumer-check/static.sh`** links it with `-static` against the host's glibc: stock must keep an
  interpreter or shared libraries (else the check cannot tell), the patched build must have neither and
  `sched_yield` defined, and the program must run.
- **`acceptance/pause.sh`** measures the end-of-marking pause of a service built on the version against
  the same service on stock, starts alternated, one process resident. A version whose pause did not fall
  is not published. It is run by hand, since it needs a service with a large heap; the logs are in
  `acceptance/`.

## Publishing

Push a `kn-<kotlin>-yrt.<n>` tag; the workflow repeats every check above on a clean machine and then
uploads. Its reposilite token was issued by the infra repository's `reposilite-token` workflow with
the coordinate `org.jetbrains.kotlin:kotlin-native-prebuilt` (route
`/snapshots/org/jetbrains/kotlin/kotlin-native-prebuilt/`) and sits in this repository's secrets.
Running the workflow by hand with `kotlin` and `n` builds and checks without uploading.

## Moving to a new Kotlin

First check whether the new release still needs each patch - when JetBrains changes
`PageStore::PrepareForGC` or `GccBasedLinker`, the patch may be obsolete, and when nothing is left, so
is this repository. Then copy the directory to `patches/kotlin-native/<new>/`, apply the series to the
new tag, fix what does not apply, check the `compiler` manifest still names the right jar and module,
build `<new>` 0 and `<new>` 1, run the checks and the pause measurement, and tag `kn-<new>-yrt.1`.
