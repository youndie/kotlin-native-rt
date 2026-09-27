#!/usr/bin/env bash
# Build a patched Kotlin/Native distribution for linux-x86_64 and lay it out as the artifact the
# Kotlin Gradle plugin resolves: org.jetbrains.kotlin:kotlin-native-prebuilt:<version>:linux-x86_64@tar.gz
#
#   scripts/build-dist.sh 2.4.20 1        ->  build/out/.../kotlin-native-prebuilt-2.4.20-yrt.1-linux-x86_64.tar.gz
#   scripts/build-dist.sh 2.4.20 0        ->  the CONTROL: the stock runtime packaged the same way, never
#                                              published. A consumer linked against it must come out byte
#                                              for byte the same as against stock (consumer-check/run.sh),
#                                              which is what shows a patched build differs because of the
#                                              patches and not because of the packaging or the version.
#
# Runs on a Linux x86_64 host that has:
#   - the STOCK distribution of that version in ~/.konan (a Gradle build on that version provisions it),
#     with its dependencies (the dev LLVM bundle and the gcc toolchain the runtime is compiled with);
#   - a clean checkout of JetBrains/kotlin at tag v<version> in $KOTLIN_SRC (default ~/kotlin-src);
#     a sparse checkout of kotlin-native/runtime, kotlin-native/backend.native and kotlin-native/build-tools
#     is enough.
#
# Nothing is published here; scripts/publish.sh does that from build/out.
set -euo pipefail

KV=${1:?kotlin version, e.g. 2.4.20}
N=${2:?rt number, e.g. 1}
VER="$KV-yrt.$N"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${KOTLIN_SRC:-$HOME/kotlin-src}
STOCK=$HOME/.konan/kotlin-native-prebuilt-linux-x86_64-$KV
SERIES=$ROOT/patches/kotlin-native/$KV
WORK=${WORK:-$ROOT/build}
OUT=$WORK/out/org/jetbrains/kotlin/kotlin-native-prebuilt/$VER

[ -d "$STOCK" ] || { echo "no stock distribution at $STOCK"; exit 1; }
[ -f "$SERIES/series" ] || { echo "no patch series for $KV at $SERIES"; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain)" ] || { echo "$SRC is not clean"; exit 1; }
want=$(git -C "$SRC" rev-parse "v$KV^{commit}") ; have=$(git -C "$SRC" rev-parse HEAD)
[ "$want" = "$have" ] || { echo "$SRC is at $have, not v$KV ($want)"; exit 1; }

rebuild() {  # out-dir -> prints the summary line
  rm -rf "$1"; mkdir -p "$(dirname "$1")"
  KOTLIN_SRC=$SRC KONAN_DIST=$STOCK OUT=$1 python3 "$ROOT/scripts/rebuild_runtime.py" | tee "$1.log" | grep -E '^(identical|DIFF)'
}
restore() { git -C "$SRC" checkout -q -- . ; }
trap restore EXIT

# 1. THE CONTROL: the stock sources must rebuild into exactly the shipped modules. If they do not,
#    the toolchain or the recipe has drifted, and a patched module would differ for a second reason.
echo "== control: stock sources"
rebuild "$WORK/stock"
grep -q '^identical [0-9]*, different 0,' "$WORK/stock.log" || { echo "CONTROL FAILED: the stock rebuild differs from the distribution"; exit 2; }

# 2. The series, in order, then the rebuild; only the modules the series touches may differ.
#    Number 0 is the control and skips this step: the stock modules are packaged unchanged.
if [ "$N" = 0 ]; then
changed=""
echo "== control build: no patches applied"
else
echo "== patched: $(tr '\n' ' ' < "$SERIES/series")"
while read -r p; do [ -n "$p" ] && git -C "$SRC" apply "$SERIES/$p"; done < "$SERIES/series"
rebuild "$WORK/patched"
restore
changed=$(grep '^DIFF' "$WORK/patched.log" | awk '{print $2}' | sort | tr '\n' ' ')
echo "modules that differ from stock: ${changed:-none}"
[ -n "$changed" ] || { echo "the series changed no module - refusing to package a copy of stock"; exit 3; }
expected=$(cat "$SERIES/modules" 2>/dev/null | sort | tr '\n' ' ')
[ "$changed" = "$expected" ] || { echo "expected exactly: $expected"; exit 4; }
fi

# 3. The distribution: stock, minus what the compiler builds on demand from the runtime it has
#    (klib/cache - those caches would carry the stock runtime) and the plugin's provisioning marker,
#    with the changed modules swapped in. The top directory is named as the plugin names it on disk.
NAME=kotlin-native-prebuilt-linux-x86_64-$VER
rm -rf "$WORK/dist" && mkdir -p "$WORK/dist" "$OUT"
rsync -a --exclude klib/cache --exclude provisioned.ok "$STOCK/" "$WORK/dist/$NAME/"
for m in $changed; do cp "$WORK/patched/$m.bc" "$WORK/dist/$NAME/konan/targets/linux_x64/native/$m.bc"; done
tar -czf "$OUT/kotlin-native-prebuilt-$VER-linux-x86_64.tar.gz" -C "$WORK/dist" "$NAME"

# 4. A POM, because a Maven repository without one is not resolvable by default.
cat > "$OUT/kotlin-native-prebuilt-$VER.pom" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>org.jetbrains.kotlin</groupId>
  <artifactId>kotlin-native-prebuilt</artifactId>
  <version>$VER</version>
  <packaging>pom</packaging>
  <description>Kotlin/Native $KV with the patch series in kotlin-native-rt (patches/kotlin-native/$KV). Not a JetBrains build.</description>
</project>
POM
( cd "$OUT" && for f in *; do sha256sum "$f" > "$f.sha256"; done )
echo "built $VER:"; ls -la "$OUT"
