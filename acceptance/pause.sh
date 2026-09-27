#!/usr/bin/env bash
# The collector's pauses of a service built on a patched distribution against the same service built
# on stock, on one host. Both binaries must be built with the GC log (-Xruntime-logs=gc=info).
#
#   acceptance/pause.sh <stock-binary> <patched-binary> "<service args>" <url> [rounds]
#   env: RATE (100), DURATION (150s), PORT (18401), READY (<url of the readiness probe>)
#
# Starts are alternated, one process resident at a time. Only collections that begin after the load
# starts are counted, and the log is read once, from a copy taken when the load ends - a live log
# read twice counts collections that ran after it. Prints per start: pause #1 and #2 (p50, p99, max),
# collections, threads and RSS at the end of the load, requests served, CPU per request (utime +
# stime over the load, from /proc/<pid>/stat), and k6's latency.
set -euo pipefail
STOCK=${1:?stock binary}; PATCHED=${2:?patched binary}; ARGS=${3:?service args}; URL=${4:?url}; ROUNDS=${5:-3}
RATE=${RATE:-100}; DURATION=${DURATION:-150s}; READY=${READY:-${URL%/*}/health/ready}
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d)
one() {  # label binary
  # shellcheck disable=SC2086
  "$2" $ARGS > "$W/log" 2>&1 & local pid=$!
  for _ in $(seq 1 240); do curl -sf -m 2 -o /dev/null "$READY" && break; sleep 1; done
  local mark; mark=$(wc -l < "$W/log")
  local cpu0; cpu0=$(awk '{print $14 + $15}' /proc/$pid/stat)
  k6 run --no-color --summary-trend-stats='med,p(99),max' -e URL="$URL" -e RATE="$RATE" -e DURATION="$DURATION" "$HERE/get.js" > "$W/k6" 2>&1
  local thr rss cpu1; thr=$(awk '/^Threads/{print $2}' /proc/$pid/status); rss=$(awk '/^VmRSS/{print int($2/1024)}' /proc/$pid/status)
  cpu1=$(awk '{print $14 + $15}' /proc/$pid/stat); echo "$((cpu1 - cpu0))" > "$W/cpu"
  tail -n +"$mark" "$W/log" > "$W/snap"
  kill "$pid"; wait "$pid" 2>/dev/null || true
  python3 - "$1" "$thr" "$rss" "$W/snap" "$W/k6" "$(cat "$W/cpu")" "$(getconf CLK_TCK)" <<'PY'
import re, sys
label, thr, rss, snap, k6, ticks, hz = sys.argv[1:]
p = {1: {}, 2: {}}
for l in open(snap):
    m = re.search(r"Epoch #(\d+): Mutators pause time #([12]): (\d+)", l)
    if m: p[int(m[2])][m[1]] = int(m[3])
def q(v, x): v = sorted(v); return v[min(len(v) - 1, int(len(v) * x))] / 1000 if v else float("nan")
k = open(k6).read()
req = (re.search(r"^\s*http_reqs\.*:\s*(\d+)", k, re.M) or [0, "?"])[1]
lat = re.search(r"http_req_duration\.*:\s*(.*)", k)
print(f"{label:8} collections {len(p[2]):3}  pause#1 p99 {q(p[1].values(), .99):6.2f}  "
      f"pause#2 p50 {q(p[2].values(), .5):6.2f} p99 {q(p[2].values(), .99):6.2f} max {q(p[2].values(), 1):6.2f} ms  "
      f"threads {thr} rss {rss} MB  requests {req}  cpu {int(ticks) * 1e6 / int(hz) / max(int(req), 1) if req != '?' else float('nan'):6.0f} us/req  latency {lat[1].strip() if lat else '?'}")
PY
}
echo "# stock $(md5sum < "$STOCK" | cut -c1-8), patched $(md5sum < "$PATCHED" | cut -c1-8); args: $ARGS; $RATE req/s for $DURATION; $(nproc) cores"
for r in $(seq 1 "$ROUNDS"); do echo "# round $r"; one stock "$STOCK"; one patched "$PATCHED"; done
rm -rf "$W"
