#!/usr/bin/env bash
# Memory benchmark (docs/PERFORMANCE.md, "Memory"): one run of a variant
# built by build.sh, against the dev kind cluster loaded with dev/bulk.sh.
#
#   tools/membench/run.sh <label> <run>      # e.g. run.sh before 1
#
# Starts the backend (test cluster only: --kubeconfig .kubeconfig-dev) and
# the app in the background (open -g: it never takes focus), with HOME
# pointed at $MEMBENCH_DIR/home so your settings and kubeconfig choice are
# not used or changed. Measures the app's phys_footprint (median of 5
# one-second samples) and the backend's footprint, RSS and Go heap after
# launch, after the scenario and after IDLE seconds (default 120), then the
# peaks. Results: $MEMBENCH_DIR/results/<label>-<run>.txt.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=${MEMBENCH_DIR:-/tmp/k8sman-membench}
dev=${DEV_KUBECONFIG:-$root/.kubeconfig-dev}
ctx=${CONTEXT:-kind-${KIND_CLUSTER:-k8sman-dev}}
label=$1; n=$2
idle=${IDLE:-120}
tok=$(cat "$out/token")
h="$out/home"; mkdir -p "$h" "$out/results"
res="$out/results/$label-$n"
: > "$res.txt"; : > "$res.samples"
log() { echo "$*" | tee -a "$res.txt"; }

env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin HOME="$h" KUBECONFIG="$dev" K8SMAN_AUTH_TOKEN="$tok" ${BACKEND_ENV:-} \
  "$out/server-$label" --addr 127.0.0.1:7461 --kubeconfig "$dev" --context "$ctx" \
  --settings "$h/settings.json" --columns "$h/columns.json" --portforwards "$h/pf.json" \
  --cache-dir "$h/cache" --icon-cache "$h/icons" --no-remote-icons --pprof 127.0.0.1:6061 \
  > "$res.backend.log" 2>&1 &
bpid=$!
apid=""
cleanup() { [ -n "$apid" ] && kill "$apid" 2>/dev/null; kill "$bpid" 2>/dev/null; [ -n "${spid:-}" ] && kill "$spid" 2>/dev/null; }
trap cleanup EXIT
api() { curl -fsS -H "Authorization: Bearer $tok" "http://127.0.0.1:7461$1"; }
for _ in $(seq 1 50); do api /api/health >/dev/null 2>&1 && break; sleep 0.2; done
case "$(api /api/health)" in *"\"context\":\"$ctx\""*) ;; *) echo "backend is not on $ctx" >&2; exit 1 ;; esac

app="$out/$label.app"
applog="$res.app.log"; : > "$applog"
open -g -n --stdout "$applog" --stderr "$applog" --env HOME="$h" --env CFFIXED_USER_HOME="$h" --env KUBECONFIG="$dev" "$app"
for _ in $(seq 1 50); do apid=$(pgrep -f "^$app/Contents/MacOS/k8sman" | head -1); [ -n "$apid" ] && break; sleep 0.2; done
[ -n "$apid" ] || { echo "app did not start" >&2; exit 1; }

fp() { footprint "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1 | awk '{v=$1; if($2=="KB")v/=1024; if($2=="GB")v*=1024; printf "%.1f", v}'; }
fp5() { for _ in 1 2 3 4 5; do fp "$1"; echo; sleep 1; done | sort -n | sed -n 3p; }
rss() { ps -o rss= -p "$1" | awk '{printf "%.1f", $1/1024}'; }
heap() { curl -fsS -H "Authorization: Bearer $tok" "http://127.0.0.1:6061/debug/pprof/heap?debug=1$1" | awk '/^# HeapInuse/{hi=$4} /^# HeapAlloc/{ha=$4} END{printf "alloc=%.1f inuse=%.1f", ha/1048576, hi/1048576}'; }
measure() {
  log "$1 app_footprint_MB=$(fp5 "$apid") backend_footprint_MB=$(fp "$bpid") backend_rss_MB=$(rss "$bpid") backend_heap_MiB[$(heap "")] backend_heap_after_gc_MiB[$(heap "&gc=1")]"
}
( while kill -0 "$apid" 2>/dev/null; do echo "$(date +%s) $(fp "$apid") $(fp "$bpid")" >> "$res.samples"; sleep 1; done ) &
spid=$!

sleep 13 # the driver starts 20s after launch
measure launch
until grep -q "BENCH done\|BENCH error" "$applog"; do kill -0 "$apid" 2>/dev/null || exit 1; sleep 1; done
measure scenario
sleep "$idle"
measure idle
peak() { vmmap -summary "$1" 2>/dev/null | sed -n 's/Physical footprint (peak): *//p'; }
log "peak app_footprint_peak=$(peak "$apid") backend_footprint_peak=$(peak "$bpid")"
log "cpu backend_cputime=$(ps -o time= -p "$bpid" | tr -d ' ') app_cputime=$(ps -o time= -p "$apid" | tr -d ' ')"
