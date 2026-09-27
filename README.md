# kotlin-native-rt

A patched Kotlin/Native distribution for `linux-x86_64`, published to our own reposilite under the
coordinate the Kotlin Gradle plugin already resolves:

```
org.jetbrains.kotlin:kotlin-native-prebuilt:<kotlin>-yrt.<n>:linux-x86_64@tar.gz
```

The compiler, the standard library and the platform libraries are JetBrains' own, byte for byte. What
differs is a small patch series against the runtime (and, later, the distribution's
`konan.properties`), kept here as files so each change can be read on its own. This is **not a JetBrains
build**, and nothing here is sent upstream.

**Status: draft.** `2.4.20-yrt.1` was built end to end on 2026-09-27 on a Linux x86_64 host: the
control rebuilt all 24 shipped runtime modules byte for byte, the series changed `custom_alloc` alone
(md5 `b8f9bc7d…`), and the tarball (264 MB) carries that module, no `klib/cache`, and
`compilerVersion=2.4.20`. The tarball is built from JetBrains' own on Maven Central and is
reproducible: CI and a local host produced the same bytes. **The Kotlin Gradle plugin takes it** (`consumer-check`, below): it resolves
`kotlin.native.version=2.4.20-yrt.1` from a Maven repository, unpacks it, links and runs, and the
unpatched control links to the stock binary byte for byte. **Nothing is published.**

## What is patched

`patches/kotlin-native/<kotlin>/series` lists the patches in order; `modules` lists the runtime modules
the series is expected to change, and the build refuses to package if any other module differs.

| patch | what it changes | why |
|---|---|---|
| `0001-restore-page-list-transfer-order` | the order of the two page-list merges in `PageStore::PrepareForGC` | At the end of marking, with the world stopped, the second merge walks its source list to the tail. [`ec891474b0`](https://github.com/JetBrains/kotlin/commit/ec891474b0) (January 2023) put the long list (`used_`) first so the short one is walked; [`7854b01473`](https://github.com/JetBrains/kotlin/commit/7854b01473) two weeks later reversed the lines without comment. 2.4.20 walks the long list in every cycle. |
| `0002-free-empty-pages-after-resume` | empty pages are detached in the pause (one CAS) and unmapped by the GC thread when the sweep starts, after the world resumes | Freeing inside the pause is how the runtime stays safe with lock-free page stacks ([`AtomicStack.hpp`](https://github.com/JetBrains/kotlin/blob/v2.4.20/kotlin-native/runtime/src/alloc/custom/cpp/AtomicStack.hpp)); detaching the whole list keeps that safety - no mutator can reach a detached page, and none is inside `Pop` at a safepoint - and moves one `munmap` per page out of the pause. |

**What the two buy**, measured on a synthetic Ktor service with a 1 GB live heap and 100 allocating
threads, 16 KiB pages, CMS, one process on a four-core host, end-of-marking pause at p99: 23–52 ms
stock, 0.9–4.5 ms with both. Each alone fixes only its half (0001 the median, 0002 the tail). Request
latency and CPU per request did not get worse at 100 req/s, and at 90 % of capacity 0002 removed
latency spikes of hundreds of milliseconds. The pause mechanism with its controls, on an independent
subject, is in [`youndie/kesh` `bench/reports/b-19`](https://github.com/youndie/kesh/tree/main/bench/reports/b-19).

**Only services with a large heap gain anything.** Up to a live heap of about 128 MB the pause is a
few milliseconds on the stock runtime and these patches do not move anything that matters.

## Planned, not here yet

- **`-static` that links a static executable** ([KT-89362](https://youtrack.jetbrains.com/issue/KT-89362)).
  Two halves. The compiler's `GccBasedLinker` emits `-dynamic-linker` unconditionally, so a
  `-static` binary still carries `PT_INTERP` and segfaults at start; the fix is
  [JetBrains/kotlin#8127](https://github.com/JetBrains/kotlin/pull/8127) (closed unmerged), 16 lines
  in `native/utils/.../Linker.kt` with a test. And `linkerKonanFlags.linux_x64` carries a hardcoded
  `-Bdynamic` after the user's flags, which is a `konan.properties` line in this distribution. **This
  one is not a runtime patch**: `Linker.kt` is compiled into the compiler's jar, so the build has to
  recompile those classes and replace them in `konan/lib`, and the control becomes "the stock
  `Linker.kt`, recompiled and swapped in the same way, links a consumer to the stock binary". The
  recipe and the measurements are in sborka's `docs/research/static-probe`.
- **Resident memory that follows the thread count** ([KT-89365](https://youtrack.jetbrains.com/issue/KT-89365)):
  RSS = 7 MB + 2.96 MB x threads at the default page size, because every thread keeps a page per size
  class it has touched until the next collection. JetBrains closed it as a duplicate of
  [KT-74834](https://youtrack.jetbrains.com/issue/KT-74834) (how many empty pages to keep) and
  pointed at [KT-89435](https://youtrack.jetbrains.com/issue/KT-89435) (fewer size classes); both are
  open. `fixedBlockPageSize=16` is the workaround for the size, not the policy. Candidates for a patch,
  none tried: map fixed-block pages without `MAP_POPULATE`, so a thread's partly used page is resident
  only as far as it was touched; merge neighbouring size classes; give a thread's pages back when it
  parks. The measurement that decides is the slope of peak RSS against thread count.
- **`ktor-io` with UTF-8 outside iconv** — a separate artifact with its own version line, because it
  follows Ktor's releases, not Kotlin's. On Kotlin/Native the charset layer is glibc `iconv`, which
  `dlopen`s gconv modules even for UTF-8, so a `scratch` image fails the first URL encoding.

## Versions

`<kotlin>-yrt.<n>`: `2.4.20-yrt.1`, `2.4.20-yrt.2`, ... A number is never reused (reposilite answers
409), and the stock version string is never published here: a machine that already holds the stock
`2.4.20` in `~/.konan` or in Gradle's cache would pick either one silently.

`konan.properties` keeps `compilerVersion=<kotlin>`: the compiler is JetBrains' and klibs record the
compiler version. The plugin accepts that next to `kotlin.native.version=<kotlin>-yrt.<n>`.

**`yrt.0` is reserved for the control**: `scripts/build-dist.sh <kotlin> 0` packages the stock runtime
exactly as a patched build is packaged, and `scripts/publish.sh` refuses it.

## Building

On a Linux x86_64 host with the stock distribution of that version in `~/.konan` and a clean checkout
of `JetBrains/kotlin` at `v<kotlin>` (a sparse checkout of `kotlin-native/runtime`,
`kotlin-native/backend.native` and `kotlin-native/build-tools` is enough):

```bash
KOTLIN_SRC=~/kotlin-src scripts/build-dist.sh 2.4.20 1
```

1. **Control:** the stock sources are rebuilt with the dev LLVM bundle the runtime was built with and
   must match every shipped module byte for byte. If they do not, the toolchain has drifted, and a
   patched module would differ for a second reason; the build stops.
2. The series is applied, the runtime rebuilt, the checkout restored. Exactly the modules in `modules`
   may differ.
3. The stock distribution is copied **without `klib/cache`** (caches the compiler builds on demand,
   carrying whatever runtime built them) and without the plugin's `provisioned.ok`; the changed modules
   are swapped in; the top directory is named as the plugin names it on disk; a tarball, a POM and
   digests go to `build/out` in Maven layout.

## Checking that a consumer gets it

`consumer-check/` is the smallest consumer: one program that fills the heap across size classes and
collects, a Kotlin Multiplatform build with no other dependency, and a repository filter that admits
only `-yrt` versions of `kotlin-native-prebuilt`. `run.sh` links it against stock and against a
version from the given repository and compares:

```bash
consumer-check/run.sh 2.4.20 2.4.20-yrt.1 file://$PWD/build/out   # must differ from stock
consumer-check/run.sh 2.4.20 2.4.20-yrt.0 file://$PWD/build/out   # must not
```

Both halves are needed. The patched binary differing from stock proves nothing on its own - the
packaging or the version string could change it; the control coming out identical is what shows the
difference is the runtime. The allocator's functions are inlined into the GC thread in a release
binary, so there is no symbol to look for instead.

On 2026-09-27: stock `72d58837`, `2.4.20-yrt.1` `03039fc1`, `2.4.20-yrt.0` `72d58837`; all three ran.
The plugin unpacked each into `~/.konan/kotlin-native-prebuilt-linux-x86_64-<version>`.

## Acceptance before a version is published

- the build's control and module check (above), and `consumer-check` against the patched build and
  its `yrt.0` control;
- the runtime's own allocator tests, the `custom_alloc_test` group, built outside JetBrains' build by
  `scripts/alloc_tests.py` on their recipe and run by `build-dist.sh` on the patched sources. **They
  pass with the empty-page frees removed altogether** (29 of 29 on that mutant), so patch 0002 carries
  its own test, `HeapFreesEmptyPagesAfterThePause`: it fails on stock ("an empty page was destroyed
  inside the pause"), fails on that mutant ("... was not destroyed by the sweep after the pause"), and
  passes on the series - 30 of 30;
- one pause measurement at a large heap against stock (`acceptance/pause.sh`): a version whose pause
  did not fall is not published.

**2.4.20-yrt.1, 2026-09-27** (`acceptance/2026-09-27-2.4.20-yrt.1-pause.log`), a synthetic Ktor
service with the GC log, one host with 20 cores (shared with other work, so absolute numbers are
noisier than on a dedicated host), 100 req/s for 150 s, three alternating starts, end-of-marking pause:

| | stock p50 / p99 | 2.4.20-yrt.1 p50 / p99 |
|---|---|---|
| 1 GB live heap, 100 threads | 11.4–15.0 / 19.6–26.4 ms | **0.11–0.33 / 0.46–1.16 ms** |
| 512 MB live heap, 5 threads | 7.5–9.4 / 11.7–14.9 ms | **0.07–0.11 / 0.39–0.62 ms** |

Resident memory and request latency p99 are the same for both (maximum latency lower on the patched
build: 11–18 against 22–40 ms). The CI build and a local build of 2.4.20-yrt.1 are the same bytes
(sha256 `8105e7dd…`).

## Publishing and consuming

```bash
REPOSILITE_USER=... REPOSILITE_SECRET=... scripts/publish.sh 2.4.20-yrt.1
```

The token is issued by the infra repository's `reposilite-token` workflow with the coordinate
`org.jetbrains.kotlin:kotlin-native-prebuilt`, and lands in this repository's secrets. A consumer sets
`kotlin.native.version=2.4.20-yrt.1` and needs reposilite among the repositories the plugin resolves
the distribution from, with nothing filtering `org.jetbrains.kotlin` out of it. In the portfolio that
is sborka's job: only executables link a runtime, so libraries stay on stock.

## Moving to a new Kotlin

Copy the series to `patches/kotlin-native/<new>/`, apply it to the new tag, fix what does not apply,
build, run the acceptance, publish `<new>-yrt.1`. **First check whether the new version still needs
each patch**: when JetBrains changes `PrepareForGC`, the patch goes, and when nothing is left, so does
this repository.

## Open questions

1. ~~Does the plugin accept a suffixed `kotlin.native.version` with `compilerVersion=<kotlin>`?~~
   Yes (`consumer-check`, 2026-09-27).
2. ~~Is the tarball's top directory what the plugin expects?~~ Yes: it unpacked into the directory it
   names and linked from it.
3. Does a debug or test binary take the runtime from somewhere other than `konan/targets/*/native`
   (a cache built on the consumer's machine is built from this distribution, so it should be fine)?
4. Where does the publishing run: GitHub Actions do not start on a private repository here, and the
   publishing secret is not meant to leave CI.

## License

Apache License 2.0, as the Kotlin sources the patches apply to. The patches are derived from
JetBrains' Kotlin (`https://github.com/JetBrains/kotlin`); this repository is not affiliated with
JetBrains.
