# ktor-io charsets without iconv

A patch to `ktor-io` that serves UTF-8 and ISO-8859-1 from Kotlin instead of glibc `iconv` on
`linuxX64`, so a statically linked Ktor service needs no gconv modules for them. Written, tested,
**not sent upstream and not in use**: the route taken instead is [`iconv/`](../../iconv/), which
replaces `iconv` itself at link time and so needs no fork of Ktor. Kept for what it holds: a second,
independent implementation of the same conversions, and tests that pin iconv's behaviour.

| | |
|---|---|
| patch | [`ktor-io-charsets-without-iconv.patch`](ktor-io-charsets-without-iconv.patch) |
| base | `ktorio/ktor` `702ff9fb57a899320b10186c7ef70775b5328e22` (2026-09-14, after 3.5.2) |
| apply | `git apply ktor-io-charsets-without-iconv.patch` on that commit |

What it changes:

- `ktor-io/linux/src/CharsetLinux.kt` - UTF-8 and ISO-8859-1 encoders and decoders in Kotlin; every
  other charset still goes through `iconv`.
- `ktor-io/common/src/.../ISO88591.kt` - the web target's ISO-8859-1 moved to `common`, so `linux` can
  use it.
- three tests:
  - `linux/test/CharsetErrorSemanticsTest.kt` - what the charsets do with malformed, unmappable and
    truncated input, pinning behaviour a replacement must keep. Measured on stock ktor-io with glibc's
    iconv (27.09): the two byte-budget tests fail, since iconv does not honour `max` within a segment
    and the patch deliberately does; and `rejectsAnUnpairedSurrogateRatherThanSubstituting` never ends,
    because stock ktor-io hangs encoding a string that ends in an unpaired high surrogate (see
    [`iconv/README.md`](../../iconv/README.md#checks)). The rest pass.
  - `jvmAndPosix/test/Iso88591WithoutIconvTest.kt`, `jvmAndPosix/test/Utf8SegmentBoundaryTest.kt` -
    every byte value, and sequences cut by kotlinx-io segment boundaries.

Measured on the base commit with the patch, Ubuntu 24.04: `:ktor-io:linuxX64Test` 148 tests, 0
failures; `:ktor-io:jvmTest` 193, 0; `compileKotlin` for JS, WasmJs, MingwX64 and AndroidNativeX64
clean. The reproducer of the problem is
[`youndie/ktor-iconv-repro`](https://github.com/youndie/ktor-iconv-repro).
