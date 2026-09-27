#!/bin/bash
# ktor-io in a static executable, in an empty image: with iconv-unicode the three charsets it covers
# work and the rest fail as before; without it (the control) all of them fail. Linux x86_64, docker.
#
#     check/check.sh [kotlin-native-version]      (default 2.4.20-yrt.2; needs 0003-static-executable)
set -euo pipefail
cd "$(dirname "$0")"
KNV=${1:-2.4.20-yrt.2}
REPO=${RT_REPO:-https://reposilite.kotlin.website/snapshots}

for v in control iconv; do
  flag=(); [ "$v" = iconv ] && flag=(-Piconv=true)
  ./gradlew -q --console=plain linkReleaseExecutableLinuxX64 \
    -Pkotlin.native.version="$KNV" -Prt.repo="$REPO" "${flag[@]}"
  cp build/bin/linuxX64/releaseExecutable/iconv-check.kexe "build/probe-$v"
done

for v in control iconv; do
  b=build/probe-$v
  interp=$(readelf -l "$b" | grep -c INTERP || true)
  needed=$(readelf -d "$b" | grep -c NEEDED || true)
  wrap=$(nm "$b" | grep -c ' T __wrap_iconv_open$' || true)
  echo "$v: $(stat -c %s "$b") bytes, interpreter $interp, NEEDED $needed, __wrap_iconv_open defined $wrap"
  [ "$interp" = 0 ] && [ "$needed" = 0 ] || { echo "FAIL: $v is not a static executable"; exit 1; }
done
[ "$(nm build/probe-control | grep -c __wrap_iconv || true)" = 0 ] || { echo "FAIL: the control carries the replacement"; exit 1; }
[ "$(nm build/probe-iconv | grep -c ' T __wrap_iconv_open$' || true)" = 1 ] || { echo "FAIL: the replacement is not linked in"; exit 1; }

# an image with nothing in it: no gconv, no libc, no /etc
docker image inspect iconv-check-empty >/dev/null 2>&1 || tar -cf - --files-from /dev/null | docker import - iconv-check-empty >/dev/null
run() { docker run --rm --network none -v "$PWD/build/probe-$1:/probe:ro" iconv-check-empty /probe; }

echo "== control, empty image"; run control | tee build/out-control
echo "== iconv-unicode, empty image"; run iconv | tee build/out-iconv

cat > build/expected-iconv <<'OUT'
UTF-8 -> ok, 9 bytes
ISO-8859-1 -> ok, 8 bytes
US-ASCII -> ok, 8 bytes
UTF-16 -> IllegalArgumentException: Failed to open iconv for charset UTF-16 with error code 22
windows-1251 -> IllegalArgumentException: Failed to open iconv for charset windows-1251 with error code 22
malformed UTF-8 -> MalformedInputException
OUT
diff -u build/expected-iconv build/out-iconv || { echo "FAIL: iconv-unicode output differs"; exit 1; }
# the control has to fail on the three the replacement covers, or this check proves nothing
[ "$(head -3 build/out-control | grep -c 'error code 22')" = 3 ] || { echo "FAIL: the control did not fail; the image is not what this check assumes"; exit 1; }
echo "ICONV CHECK OK"
