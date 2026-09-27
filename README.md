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
`compilerVersion=2.4.20`. **Nothing is published**, and the open questions at the end decide whether
a consumer can pick it up at all.

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

- **Static linking without overrides** — the five `konan.properties` values that let `-static`
  produce a binary for a `FROM scratch` image, written into this distribution's own file instead of
  passed as `-Xoverride-konan-properties` (which JetBrains calls unstable between patch releases).
  Tracked upstream as [KT-89362](https://youtrack.jetbrains.com/issue/KT-89362); the recipe is in
  sborka's `docs/research/static-probe`.
- **`ktor-io` with UTF-8 outside iconv** — a separate artifact with its own version line, because it
  follows Ktor's releases, not Kotlin's. On Kotlin/Native the charset layer is glibc `iconv`, which
  `dlopen`s gconv modules even for UTF-8, so a `scratch` image fails the first URL encoding.

## Versions

`<kotlin>-yrt.<n>`: `2.4.20-yrt.1`, `2.4.20-yrt.2`, ... A number is never reused (reposilite answers
409), and the stock version string is never published here: a machine that already holds the stock
`2.4.20` in `~/.konan` or in Gradle's cache would pick either one silently.

`konan.properties` keeps `compilerVersion=<kotlin>`: the compiler is JetBrains' and klibs record the
compiler version. Whether the plugin accepts that next to `kotlin.native.version=<kotlin>-yrt.<n>` is
open question 1.

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

## Acceptance before a version is published

- the build's control and module check (above);
- JetBrains' runtime tests for the custom allocator (`CustomAllocatorTest`, the `PageStore` tests) —
  **not run yet**; the patches' safety rests on the argument in 0002 and on an assertions-on smoke
  (`-Xbinary=runtimeAssertionsMode=panic`) per build;
- one pause measurement at a large heap against stock: a version whose pause did not fall is not
  published.

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

1. Does the plugin accept `kotlin.native.version` with a suffix, and a distribution whose
   `compilerVersion` is the plain `<kotlin>`? Everything else depends on it.
2. Is the tarball's top directory name what the plugin expects when it unpacks into `~/.konan`?
3. Does a debug or test binary take the runtime from somewhere other than `konan/targets/*/native`
   (a cache built on the consumer's machine is built from this distribution, so it should be fine)?
4. Where does the publishing run: GitHub Actions do not start on a private repository here, and the
   publishing secret is not meant to leave CI.

## License

Apache License 2.0, as the Kotlin sources the patches apply to. The patches are derived from
JetBrains' Kotlin (`https://github.com/JetBrains/kotlin`); this repository is not affiliated with
JetBrains.
