#!/bin/bash
# ktor-io's own linuxX64 tests, on stock ktor-io, linked with and without the replacement, run where
# gconv is installed and in an image where it is not. Linux x86_64 with gcc and docker; builds Ktor,
# so it is heavy and not part of CI.
#
#     iconv/test/ktor-io-suite.sh [ktor-commit]     (default: the base of research/ktor-iconv)
#
# The tests of research/ktor-iconv are added to the suite: they pin iconv's behaviour on malformed,
# unmappable and truncated input. One of them never ends on stock ktor-io (an iconv EINVAL the encoder
# loop does not advance past) and is run apart, with a timeout; the replacement must hang the same way.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
PATCH=$HERE/../research/ktor-iconv/ktor-io-charsets-without-iconv.patch
COMMIT=${1:-702ff9fb57a899320b10186c7ef70775b5328e22}
WORK=${WORK:-/tmp/iconv-ktor-io}
HANG=CharsetErrorSemanticsTest.rejectsAnUnpairedSurrogateRatherThanSubstituting

[ -d "$WORK/.git" ] || git clone -q https://github.com/ktorio/ktor.git "$WORK"
cd "$WORK" && git fetch -q origin && git checkout -q --force "$COMMIT" && git clean -qfd ktor-io || exit 1
git apply --include='*/test/*' "$PATCH" || exit 1
mkdir -p build-iconv
gcc -O2 -fPIC -Wall -Wextra -Werror -c "$HERE/src/iconv_unicode.c" -o build-iconv/iconv_unicode.o || exit 1
cat >> ktor-io/build.gradle.kts <<KTS

providers.gradleProperty("iconvShim").orNull?.let { shim ->
    kotlin.targets.withType<org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget>()
        .matching { it.name == "linuxX64" }
        .configureEach { binaries.all { linkerOpts(shim, "--wrap=iconv_open", "--wrap=iconv", "--wrap=iconv_close") } }
}
KTS

export GRADLE_OPTS=-Dorg.gradle.daemon=false
for v in stock iconv; do
  arg=(); [ $v = iconv ] && arg=(-PiconvShim="$WORK/build-iconv/iconv_unicode.o")
  rm -rf ktor-io/build/bin/linuxX64/debugTest
  ./gradlew -q --console=plain :ktor-io:linkDebugTestLinuxX64 "${arg[@]}" > build-iconv/link-$v.log 2>&1 \
    || { echo "link $v failed, see $WORK/build-iconv/link-$v.log"; exit 1; }
  cp ktor-io/build/bin/linuxX64/debugTest/test.kexe build-iconv/test-$v.kexe
done
[ "$(nm build-iconv/test-iconv.kexe | grep -c ' T __wrap_iconv_open$')" = 1 ] || { echo "the replacement is not linked in"; exit 1; }

summary() { echo "passed $(grep -c '^\[       OK' "$1") failed $(grep -c '^\[  FAILED  \].*ms)' "$1"): $(grep '^\[  FAILED  \].*ms)' "$1" | sed 's/\[  FAILED  \] //; s/ (.*//' | tr '\n' ' ')"; }
nogconv() { docker run --rm --network none -v "$WORK/build-iconv:/k:ro" ubuntu:24.04 sh -c "rm -rf /usr/lib/x86_64-linux-gnu/gconv && $*"; }
for v in stock iconv; do
  timeout 600 build-iconv/test-$v.kexe --ktest_logger=GTEST "--ktest_filter=*-$HANG" > build-iconv/gconv-$v.log 2>&1
  echo "$v, gconv:    $(summary build-iconv/gconv-$v.log)"
  nogconv "timeout 600 /k/test-$v.kexe --ktest_logger=GTEST '--ktest_filter=*-$HANG'" > build-iconv/nogconv-$v.log 2>&1
  echo "$v, no gconv: $(summary build-iconv/nogconv-$v.log)"
  timeout 20 build-iconv/test-$v.kexe --ktest_filter=$HANG > /dev/null 2>&1; a=$?
  nogconv "timeout 20 /k/test-$v.kexe --ktest_filter=$HANG" > /dev/null 2>&1; b=$?
  echo "$v, $HANG: exit $a with gconv, $b without (124: still running after 20 s)"
done
