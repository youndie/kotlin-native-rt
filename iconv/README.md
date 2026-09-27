# iconv-unicode

`iconv` for UTF-8, UTF-16LE, UTF-16BE, ISO-8859-1 and US-ASCII without glibc's gconv modules, so a
statically linked Kotlin/Native executable that uses Ktor runs in an empty (`FROM scratch`) image.

## Why

glibc's `iconv` has no converters inside libc: it `dlopen`s them from
`/usr/lib/x86_64-linux-gnu/gconv`. `ktor-io` on Linux converts every charset through UTF-16 -
`iconv_open(charset, "UTF-16LE")` and back - so even UTF-8 needs `UTF-16.so`. In an image without
that directory the first conversion throws:

```
IllegalArgumentException: Failed to open iconv for charset UTF-8 with error code 22
```

and nothing says so at link time or at start-up: a service serves static files and answers `401`,
then fails on the first page that URL-encodes a parameter. The alternative was to copy the gconv tree
into the image - with `libc.so.6`, the loader and `ld.so.cache`, since `dlopen` from a static
executable needs them - which is what a static executable was meant to avoid.

## How

[`src/iconv_unicode.c`](src/iconv_unicode.c) defines `__wrap_iconv_open`, `__wrap_iconv` and
`__wrap_iconv_close`, and the executable is linked with

```
--wrap=iconv_open --wrap=iconv --wrap=iconv_close
```

so its calls land there, while glibc's own functions stay reachable as `__real_*`. A conversion
between two of the five charsets is done in the file; any other charset, or a name with a suffix such
as `//TRANSLIT`, goes to glibc unchanged - it works where gconv is installed and fails as before where
it is not. Nothing in Ktor is patched, and the Ktor version does not matter.

The conversions are glibc's, not the standard's, where the two differ, because the point is that
nothing observable changes: glibc reads the original five- and six-byte UTF-8 forms, drops the Unicode
language tags (U+E0000-U+E007F) when writing ISO-8859-1 or ASCII, and reports a full output buffer
before an unmappable character. Every return value, `errno`, buffer advance and output byte is held
against glibc by [`test/differential.c`](test/differential.c).

## Using it

A dependency of the executable's `linuxX64Main`; the klib carries both the compiled file and the
linker options, so nothing else is configured:

```kotlin
implementation("io.github.youndie.kotlin-native-rt:iconv-unicode:<version>")
```

For a static executable that is the whole story, together with `0003-static-executable` from this
repository ([`check/`](check/) is a complete consumer). It works in a dynamically linked executable
too, where the five charsets stop needing gconv as well.

Not covered, and passed to glibc like any other charset: `UTF-16` and `UTF-32` without a byte order
(they read and write a byte-order mark and keep state between calls), `UCS-2`, and every single-byte
code page besides ISO-8859-1. In an image without gconv they fail as they did before, with error 22.

The file is compiled by the host's C compiler into a static library inside the klib, not written
after `---` in the cinterop definition: code there becomes part of the program's bitcode, and the
optimiser makes the `__wrap_*` functions local - the link then fails with `undefined symbol:
__wrap_iconv_open`.

## Checks

| check | result, 2026-09-27 | where |
|---|---|---|
| [`test/differential.c`](test/differential.c) - the replacement against glibc's iconv, call for call: every input up to three bytes, the five- and six-byte UTF-8 forms, UTF-16 surrogates, random text with random output sizes | 155 155 917 cases, 0 differences | Ubuntu 24.04, glibc 2.39 |
| [`test/ktor-io-suite.sh`](test/ktor-io-suite.sh) - ktor-io's own `linuxX64Test` on stock ktor-io, with the tests of [`research/ktor-iconv`](../research/ktor-iconv/) added | see below | the same, and `ubuntu:24.04` without `/usr/lib/x86_64-linux-gnu/gconv` |
| [`check/check.sh`](check/check.sh) - a static executable with ktor-io in an empty image | with the library UTF-8, ISO-8859-1 and US-ASCII round-trip and malformed UTF-8 still throws `MalformedInputException`; without it all fail with error 22; 1 326 928 bytes against 1 324 240 | docker |

ktor-io's suite, 147 tests (one more is run apart, below):

| ktor-io | gconv installed | no gconv |
|---|---|---|
| stock | 145 pass, 2 fail | 116 pass, 31 fail |
| linked with iconv-unicode | 145 pass, the same 2 fail | 142 pass, 5 fail |

The two that fail everywhere are the byte-budget tests of `CharsetErrorSemanticsTest`, which fail on
glibc's iconv by design (their comments say why). The three more without gconv read `UTF-16` with a
byte-order mark, which this library leaves to glibc. `rejectsAnUnpairedSurrogateRatherThanSubstituting`
never ends on stock ktor-io with glibc's iconv, and never ends with the replacement either, which is
the point of reproducing glibc: nothing observable changes, bugs included. The input that hangs is a
string ending in an unpaired high surrogate - `Charsets.UTF_8.newEncoder().encodeToByteArray("\uD83D", 0, 1)`
on ktor-io 3.5.2 was still running after 10 s, while `"a\uD800b"`, `"a\uDC00b"` and `"x\uDE00"`
throw `MalformedInputException`. glibc answers that input with `EINVAL`, incomplete input, and
ktor-io's `checkIconvResult` treats `EINVAL` as "too few input bytes, call again"; that this is the
loop is read from the code, not traced.

```bash
gcc -O2 -Wall -o differential test/differential.c src/iconv_unicode.c \
    -Wl,--wrap=iconv_open,--wrap=iconv,--wrap=iconv_close && ./differential
check/check.sh
test/ktor-io-suite.sh
```

CI runs the first two on every push ([`.github/workflows/iconv.yml`](../.github/workflows/iconv.yml)).
