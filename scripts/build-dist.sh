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
#   - in ~/.konan/dependencies, the dev LLVM bundle and the gcc toolchain the runtime is compiled with
#     (consumer-check with -Prt.llvmVariant=dev provisions both);
#   - a clean checkout of JetBrains/kotlin at tag v<version> in $KOTLIN_SRC (default ~/kotlin-src);
#     a sparse checkout of kotlin-native/runtime and native/utils/src is enough;
#   - a JDK, when the series has compiler patches (the `compiler` manifest).
#
# Nothing is published here; scripts/publish.sh does that from build/out.
set -euo pipefail

KV=${1:?kotlin version, e.g. 2.4.20}
N=${2:?rt number, e.g. 1}
VER="$KV-yrt.$N"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC=${KOTLIN_SRC:-$HOME/kotlin-src}
SERIES=$ROOT/patches/kotlin-native/$KV
WORK=${WORK:-$ROOT/build}
OUT=$WORK/out/org/jetbrains/kotlin/kotlin-native-prebuilt/$VER

# 0. THE STOCK DISTRIBUTION AS JETBRAINS PUBLISHED IT, from Maven Central and checked against its
#    digest - not the unpacked copy in ~/.konan, which the Gradle plugin and the compiler have added to
#    (klib/commonized, klib/cache, generated files in konan/nativelib, markers). Packaged from that
#    copy, the tarball depended on the machine: 264 MB on one host, 210 MB on another.
CENTRAL=${CENTRAL:-https://repo1.maven.org/maven2}
URL=$CENTRAL/org/jetbrains/kotlin/kotlin-native-prebuilt/$KV/kotlin-native-prebuilt-$KV-linux-x86_64.tar.gz
STGZ=$WORK/stock-$KV.tar.gz
mkdir -p "$WORK"
[ -f "$STGZ" ] || curl -sfL -o "$STGZ" "$URL"
[ "$(sha1sum < "$STGZ" | cut -d' ' -f1)" = "$(curl -sfL "$URL.sha1")" ] || { echo "the stock tarball does not match its digest on Central"; rm -f "$STGZ"; exit 1; }
rm -rf "$WORK/stock-dist" && mkdir -p "$WORK/stock-dist" && tar -xzf "$STGZ" -C "$WORK/stock-dist"
STOCK=$WORK/stock-dist/kotlin-native-prebuilt-linux-x86_64-$KV
[ -d "$STOCK" ] || { echo "the stock tarball has no $STOCK"; exit 1; }
DEV=$(sed -n 's/^llvm.linux_x64.dev=//p' "$STOCK/konan/konan.properties")
[ -d "$HOME/.konan/dependencies/$DEV" ] || { echo "no $DEV in ~/.konan/dependencies - provision it (README, Building)"; exit 1; }
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

# COMPILER PATCHES. `$SERIES/compiler` names Kotlin sources of the compiler that the series changes, one
# per line: `<path in the Kotlin repository> <jar in the distribution> <Kotlin module name>`. Each is
# recompiled with the kotlinc of the same release, with the options that reproduce the class set
# JetBrains' build made from it (friend paths for the module's internals, lambdas as classes, JVM 8),
# and its classes replace that file's classes in the jar. The control build recompiles the same files
# unchanged, so the control covers the recompilation as well as the packaging.
KOTLINC=$WORK/kotlinc-$KV/kotlinc/bin/kotlinc
compile_compiler_sources() {  # -> $WORK/compiler-classes/<line number>
  [ -s "$SERIES/compiler" ] || return 0
  if [ ! -x "$KOTLINC" ]; then
    local zip=$WORK/kotlin-compiler-$KV.zip rel=https://github.com/JetBrains/kotlin/releases/download/v$KV/kotlin-compiler-$KV.zip
    curl -sfL -o "$zip" "$rel"
    [ "$(sha256sum < "$zip" | cut -d' ' -f1)" = "$(curl -sfL "$rel.sha256" | cut -c1-64)" ] || { echo "kotlinc $KV does not match its digest"; exit 6; }
    rm -rf "$WORK/kotlinc-$KV" && mkdir -p "$WORK/kotlinc-$KV" && (cd "$WORK/kotlinc-$KV" && unzip -q "$zip")
  fi
  rm -rf "$WORK/compiler-classes"
  local n=0 src jar module
  while read -r src jar module; do
    [ -n "$src" ] || continue; n=$((n + 1))
    "$KOTLINC" "$SRC/$src" -cp "$STOCK/$jar" -Xfriend-paths="$STOCK/$jar" -Xlambdas=class -jvm-target 1.8 \
      -module-name "$module" -nowarn -d "$WORK/compiler-classes/$n" 2>&1 | grep -v '^warning' || true
    [ -n "$(find "$WORK/compiler-classes/$n" -name '*.class' 2>/dev/null)" ] || { echo "kotlinc produced nothing for $src"; exit 6; }
  done < "$SERIES/compiler"
}
swap_compiler_classes() {  # dist-dir
  [ -s "$SERIES/compiler" ] || return 0
  local n=0 src jar module rel
  while read -r src jar module; do
    [ -n "$src" ] || continue; n=$((n + 1)); rel=${src#*/src/}
    python3 "$ROOT/scripts/swap_classes.py" "$1/$jar" "$WORK/compiler-classes/$n" "$(basename "$src")" "$(dirname "$rel")/" || exit 7
  done < "$SERIES/compiler"
}

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
compile_compiler_sources
else
echo "== patched: $(tr '\n' ' ' < "$SERIES/series")"
while read -r p; do [ -n "$p" ] && git -C "$SRC" apply "$SERIES/$p"; done < "$SERIES/series"
rebuild "$WORK/patched"
# The runtime's own tests for the allocator, on the patched sources (scripts/alloc_tests.py builds the
# custom_alloc_test group the way JetBrains' build does). The series carries a test of its own
# (HeapFreesEmptyPagesAfterThePause), because the stock tests pass with the frees removed altogether.
echo "== the allocator's tests on the patched sources"
KOTLIN_SRC=$SRC KONAN_DIST=$STOCK OUT=$WORK/tests python3 "$ROOT/scripts/alloc_tests.py" \
  || { echo "the allocator's tests fail on the patched sources"; exit 5; }
compile_compiler_sources
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
# rsync copies hard files, so rewriting a jar here never touches the stock tree.
swap_compiler_classes "$WORK/dist/$NAME"
# A deterministic archive: sorted, zero mtimes and owners, normalised modes, gzip without a timestamp.
# The same version built on two hosts is then the same bytes, which is checkable.
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
  -cf - -C "$WORK/dist" "$NAME" | gzip -n > "$OUT/kotlin-native-prebuilt-$VER-linux-x86_64.tar.gz"

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
echo "built $VER:"; ls -la "$OUT"; cat "$OUT/kotlin-native-prebuilt-$VER-linux-x86_64.tar.gz.sha256"
