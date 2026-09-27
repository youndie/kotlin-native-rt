#!/usr/bin/env bash
# Link the smallest consumer against the stock distribution and against a patched one, from the same
# sources in the same build, and show what differs.
#
#   consumer-check/run.sh 2.4.20 2.4.20-yrt.1 file://$PWD/build/out   the patched build must differ
#   consumer-check/run.sh 2.4.20 2.4.20-yrt.0 file://$PWD/build/out   the control must not
#
# What it answers, in order: does the Kotlin Gradle plugin resolve a suffixed kotlin.native.version from
# the given repository and unpack it; does the compiler in it link; does the result run; and did the
# runtime change - the only module the distribution replaces is custom_alloc, so a binary identical to
# the stock one would mean the patched runtime never reached the link.
set -euo pipefail
STOCK=${1:?stock version}; RT=${2:?patched version}; REPO=${3:?repository URL holding the patched version}
cd "$(dirname "$0")"
mkdir -p out
build() {  # version [repository]
  rm -rf build
  ./gradlew --no-daemon -q --console=plain --no-build-cache --rerun-tasks \
    -Pkotlin.native.version="$1" ${2:+-Prt.repo="$2"} linkReleaseExecutableLinuxX64
  cp build/bin/linuxX64/releaseExecutable/consumer-check.kexe "out/$1.kexe"
}
echo "== $STOCK (stock, from Central or ~/.konan)"; build "$STOCK"
echo "== $RT (from $REPO)"; build "$RT" "$REPO"
for v in "$STOCK" "$RT"; do
  printf '%-16s md5 %s  FreeDetached symbols %s  run: %s\n' "$v" "$(md5sum < "out/$v.kexe" | cut -c1-8)" \
    "$(nm -C "out/$v.kexe" | grep -c FreeDetached || true)" "$(./out/$v.kexe)"
done
same=$([ "$(md5sum < "out/$STOCK.kexe")" = "$(md5sum < "out/$RT.kexe")" ] && echo yes || echo no)
case $RT in
  *-yrt.0) [ "$same" = yes ] && echo "CONTROL OK - the unpatched packaging links to the stock binary byte for byte" \
                             || { echo "CONTROL FAILED - packaging alone changes the binary"; exit 1; } ;;
  *)       [ "$same" = no ]  || { echo "IDENTICAL - the patched runtime did not reach the link"; exit 1; } ;;
esac
echo "unpacked to: $(ls -d "$HOME/.konan/kotlin-native-prebuilt-linux-x86_64-$RT" 2>&1)"
