#!/usr/bin/env bash
# `-linker-option -static` on stock and on a patched build, against the host's glibc (-Prt.static).
#
#   consumer-check/static.sh 2.4.20 2.4.20-yrt.1 file://$PWD/build/out
#
# Stock is the positive control: its link emits a dynamic interpreter and a `-Bdynamic` after the
# user's flags, so the "static" binary keeps an interpreter and shared libraries. The patched build
# must come out with neither, with `sched_yield` defined (libstdc++ reaches it only weakly, and a weak
# reference does not pull it from a static libc), and the program - which collects twice - must run.
set -euo pipefail
STOCK=${1:?stock version}; RT=${2:?patched version}; REPO=${3:?repository URL holding the patched version}
cd "$(dirname "$0")"
mkdir -p out
build() {  # version [repository]
  rm -rf build
  ./gradlew --no-daemon -q --console=plain --no-build-cache --rerun-tasks -Prt.static=true \
    -Pkotlin.native.version="$1" ${2:+-Prt.repo="$2"} linkReleaseExecutableLinuxX64
  cp build/bin/linuxX64/releaseExecutable/consumer-check.kexe "out/$1-static.kexe"
}
report() {  # binary -> "interp needed weak-sched_yield"
  echo "$(readelf -l "$1" | grep -c INTERP || true) $(readelf -d "$1" 2>/dev/null | grep -c NEEDED || true) $(nm "$1" | grep -c ' w sched_yield$' || true)"
}
build "$STOCK"; build "$RT" "$REPO"
read -r si sn sw <<< "$(report "out/$STOCK-static.kexe")"
read -r pi pn pw <<< "$(report "out/$RT-static.kexe")"
echo "$STOCK -static: interpreter $si, NEEDED $sn"
echo "$RT -static: interpreter $pi, NEEDED $pn, weak sched_yield $pw, run: $(./out/$RT-static.kexe)"
[ "$si" -gt 0 ] || [ "$sn" -gt 0 ] || { echo "CONTROL FAILED - stock already links a static executable, so this check cannot tell"; exit 1; }
[ "$pi" = 0 ] && [ "$pn" = 0 ] && [ "$pw" = 0 ] || { echo "NOT STATIC - the patched build left an interpreter, a shared library or a null sched_yield"; exit 1; }
echo "STATIC OK"
