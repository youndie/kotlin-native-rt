# kotlin-native-rt

A patched Kotlin/Native distribution for `linux-x86_64`, published to our reposilite under the
coordinate the Kotlin Gradle plugin already resolves, so a service takes it with one property:

```
org.jetbrains.kotlin:kotlin-native-prebuilt:<kotlin>-yrt.<n>:linux-x86_64@tar.gz
```

The standard library, the platform libraries and nearly all of the compiler are JetBrains' own, byte
for byte. What differs is a short patch series, kept as files in
[`patches/kotlin-native/<kotlin>/`](patches/kotlin-native/): the runtime's allocator, and one compiler
source. This is **not a JetBrains build**, and nothing here is sent upstream.

## Versions

| version | patches | published |
|---|---|---|
| `2.4.20-yrt.1` | 0001, 0002 | 2026-09-27 |
| **`2.4.20-yrt.2`** | 0001, 0002, 0003 | 2026-09-27 |

A number is never reused, and the stock version string is never published here.

## What the patches do

| patch | what it fixes |
|---|---|
| `0001-restore-page-list-transfer-order` | The end-of-marking pause walks a page list to its tail. JetBrains ordered the two merges so the short list is walked ([`ec891474b0`](https://github.com/JetBrains/kotlin/commit/ec891474b0)); two weeks later [`7854b01473`](https://github.com/JetBrains/kotlin/commit/7854b01473) reversed them, and 2.4.20 walks the long one in every cycle. |
| `0002-free-empty-pages-after-resume` | Empty pages are unmapped one `munmap` at a time inside the pause. The patch detaches them in the pause (one CAS) and unmaps them after the world resumes; no mutator can reach a detached page, so the lock-free stacks stay safe. Carries its own test. |
| `0003-static-executable` | `-linker-option -static` does not produce a static executable ([KT-89362](https://youtrack.jetbrains.com/issue/KT-89362)): the compiler emits a dynamic interpreter and a `-Bdynamic` that switches `-lc` back to shared. The patch drops both for a static link ([JetBrains/kotlin#8127](https://github.com/JetBrains/kotlin/pull/8127) plus the `-Bdynamic` half) and asks for `sched_yield` by name: libstdc++ reaches it only weakly, and without it a static binary calls address zero the first time the collector waits for a concurrent sweeper. |

**What 0001 + 0002 buy.** The end-of-marking pause of a synthetic Ktor service, 100 req/s, measured
against stock ([`acceptance/`](acceptance/)):

| live heap, threads | stock p99 | 2.4.20-yrt.1 p99 |
|---|---|---|
| 1 GB, 100 | 19.6–26.4 ms | **0.46–1.16 ms** |
| 512 MB, 5 | 11.7–14.9 ms | **0.39–0.62 ms** |

Resident memory and request latency p99 are unchanged; at 90 % of capacity the patched build also
lost the latency spikes stock had. **Only a large heap gains anything**: up to a live heap of about
128 MB the stock pause is a few milliseconds and these patches move nothing that matters. The
mechanism, with controls, on an independent subject:
[`youndie/kesh` `bench/reports/b-19`](https://github.com/youndie/kesh/tree/main/bench/reports/b-19).

**What 0003 buys.** With `-static` and the host's glibc, stock links a binary that still has an
interpreter and three shared libraries; `2.4.20-yrt.2` links one with neither, which runs in an empty
`FROM scratch` image. Without `-static`, 0003 changes nothing: the same program links to the same bytes
as on `yrt.1`.

## Using it

In the service's `gradle.properties`:

```properties
kotlin.native.version=2.4.20-yrt.2
```

and reposilite among the repositories, admitting only the patched versions of this one module, so the
stock distribution keeps coming from Central:

```kotlin
// settings.gradle.kts, dependencyResolutionManagement.repositories
maven("https://reposilite.kotlin.website/snapshots") {
    mavenContent {
        includeVersionByRegex("org\\.jetbrains\\.kotlin", "kotlin-native-prebuilt", ".*-yrt\\.[0-9]+")
    }
}
```

Only executables link a runtime, so libraries stay on stock. For a static executable, the host-glibc
linker options are in [`consumer-check/build.gradle.kts`](consumer-check/build.gradle.kts)
(`-Prt.static`); with 0003 they no longer include `--no-dynamic-linker` or a `linkerKonanFlags`
override.

## What it does not do

- **Other hosts and targets.** It is a distribution for `linux-x86_64` hosts; a Mac builds with stock.
  On this host the runtime patches reach the `linux_x64` target only - other targets keep the stock
  runtime - while 0003, being in the linker, applies to any GCC-linked target asked for `-static`.
- **Resident memory that follows the thread count** ([KT-89365](https://youtrack.jetbrains.com/issue/KT-89365)).
  Examined and not patched: the mechanism is reproduced, but a service on 16 KiB pages gains about 5 %
  from the fix. See [`research/kt-89365/`](research/kt-89365/); `fixedBlockPageSize=16` is the
  workaround.
- **`scratch` without gconv.** Ktor's charsets on Kotlin/Native are glibc `iconv`, which `dlopen`s
  gconv modules even for UTF-8; a static Ktor service still needs them in the image. A `ktor-io` that
  does UTF-8 itself would be a separate artifact on Ktor's release cadence, and does not exist.
- **Debug and test binaries** are not checked separately; the checks link release executables.

## Building, checking, publishing

A version is built, checked and published by CI on a `kn-<kotlin>-yrt.<n>` tag; running the workflow
by hand builds and checks without publishing. What each check is and why, how to build locally, and
how to move the series to a new Kotlin: [`docs/MAINTAINING.md`](docs/MAINTAINING.md).

## License

Apache License 2.0, as the Kotlin sources the patches apply to. The patches are derived from
JetBrains' Kotlin (`https://github.com/JetBrains/kotlin`); this repository is not affiliated with
JetBrains.
