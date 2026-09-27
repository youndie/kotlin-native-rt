#!/usr/bin/env bash
# Upload what scripts/build-dist.sh left in build/out to reposilite, under the coordinate the Kotlin
# Gradle plugin resolves: org.jetbrains.kotlin:kotlin-native-prebuilt:<version>:linux-x86_64@tar.gz
#
#   REPOSILITE_USER=... REPOSILITE_SECRET=... scripts/publish.sh 2.4.20-yrt.1
#
# The token comes from the infra repository's reposilite-token workflow, which writes it into this
# repository's secrets - it is meant to run in CI, not to be typed on a laptop. Its route must cover
# /org/jetbrains/kotlin/kotlin-native-prebuilt/ in the target repository, or every PUT answers 403.
# A version that is already there answers 409: versions are never overwritten, take the next number.
set -euo pipefail

VER=${1:?version, e.g. 2.4.20-yrt.1}
BASE=${REPOSILITE_URL:-https://reposilite.kotlin.website/snapshots}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/build/out/org/jetbrains/kotlin/kotlin-native-prebuilt/$VER
[ -d "$DIR" ] || { echo "nothing built for $VER in $DIR"; exit 1; }
: "${REPOSILITE_USER:?}" "${REPOSILITE_SECRET:?}"

for f in "$DIR"/*; do
  path=org/jetbrains/kotlin/kotlin-native-prebuilt/$VER/$(basename "$f")
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$REPOSILITE_USER:$REPOSILITE_SECRET" -T "$f" "$BASE/$path")
  echo "$code $path"
  case $code in 2??) ;; *) echo "upload failed"; exit 1 ;; esac
done

# Read it back through the same URL a consumer uses, and compare digests: an upload that returned 2xx
# is not yet an artifact anybody can resolve.
tgz=kotlin-native-prebuilt-$VER-linux-x86_64.tar.gz
got=$(curl -sfL "$BASE/org/jetbrains/kotlin/kotlin-native-prebuilt/$VER/$tgz" | sha256sum | cut -d' ' -f1)
want=$(cut -d' ' -f1 < "$DIR/$tgz.sha256")
[ "$got" = "$want" ] && echo "resolvable: $tgz $want" || { echo "read-back digest $got != $want"; exit 1; }
