#!/usr/bin/env bash
# Run the backend benchmark suite against the dev kind cluster.
#
#   tools/perf/run.sh <k8sman-server binary> [label]
#
# Env: RTT=150ms   put a latency proxy between the backend and the API server
#      PORT=7574   backend port (pprof on PORT+1, proxy on PORT+16)
#      QUICK=1     skip the slow sections (typical use, fan-out, cold start)
#      EXTRA_ARGS  extra k8sman-server flags
# Needs `tools/perf/load.sh up` first. Writes scratch files to $OUT (default a
# temp dir); never touches ~/.kube/config or ~/.config/k8sman.
set -euo pipefail
BIN=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
LABEL=${2:-run}
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-7574}
PPROF=127.0.0.1:$((PORT + 1))
PROXY=127.0.0.1:$((PORT + 16))
OUT=${OUT:-$(mktemp -d)}
KC_DEV=${KUBECONFIG_DEV:-$(cd "$HERE/../.." && pwd)/.kubeconfig-dev}
[ -f "$KC_DEV" ] || KC_DEV=/Users/matthew/workspace/k8sman/.kubeconfig-dev
CTX=kind-k8sman-dev
mkdir -p "$OUT"
PERF="$OUT/perf"
(cd "$HERE" && go build -o "$PERF" .)

# Scratch kubeconfig: the dev cluster under two context names (for the
# context-switch test), optionally pointed at the latency proxy.
KC="$OUT/kubeconfig"
cp "$KC_DEV" "$KC"
kubectl --kubeconfig "$KC" config set-context "$CTX-b" --cluster="$CTX" --user="$CTX" >/dev/null
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
if [ -n "${RTT:-}" ]; then
  upstream=$(kubectl --kubeconfig "$KC_DEV" config view --raw -o jsonpath="{.clusters[?(@.name=='$CTX')].cluster.server}" | sed 's#https://##')
  "$PERF" proxy -listen "$PROXY" -upstream "$upstream" -rtt "$RTT" >/dev/null &
  PIDS+=($!)
  kubectl --kubeconfig "$KC" config set-cluster "$CTX" --server="https://$PROXY" >/dev/null
  LABEL="$LABEL, +$RTT RTT"
fi

server_args=(--kubeconfig "$KC" --context "$CTX" --columns "$OUT/columns.json" --portforwards "$OUT/pf.json"
  --settings "$OUT/settings.json" --icon-cache "$OUT/icons" --no-remote-icons ${EXTRA_ARGS:-})
HAS_CACHE=
if "$BIN" -h 2>&1 | grep -q -- -cache-dir; then
  HAS_CACHE=1
  server_args+=(--cache-dir "$OUT/cache")
fi

echo "## $LABEL ($(date '+%Y-%m-%d %H:%M'))"
"$BIN" "${server_args[@]}" --addr "127.0.0.1:$PORT" --pprof "$PPROF" >"$OUT/server.out" 2>"$OUT/server.log" &
SPID=$!
PIDS+=($SPID)
for _ in $(seq 100); do grep -q K8SMAN_LISTENING "$OUT/server.out" 2>/dev/null && break; sleep 0.1; done
BASE=http://127.0.0.1:$PORT

echo; echo "### Endpoint latency (no watch open)"
"$PERF" latency -base "$BASE" -n "${N:-10}"
echo; echo "### Endpoint latency (table watches open on configmaps + pods)"
"$PERF" latency -base "$BASE" -n "${N:-10}" -warm
echo; echo "### Memory/CPU"
"$PERF" idle -pid "$SPID" -dur 20s
if [ -z "${QUICK:-}" ]; then
  "$PERF" typical -base "$BASE" -pid "$SPID" -dur 60s
  for n in 1 10; do
    "$PERF" churn -kubeconfig "$KC_DEV" -rate 20 -dur 30s >/dev/null &
    CH=$!
    "$PERF" fanout -base "$BASE" -pid "$SPID" -n "$n" -kubeconfig "$KC_DEV" -context "$CTX" -hold 25s
    wait $CH
  done
fi
echo; echo "### Goroutine leak check"
"$PERF" leak -base "$BASE" -pprof "$PPROF" -n 100
echo; echo "### Context switch"
"$PERF" ctxswitch -base "$BASE" -contexts "$CTX-b,$CTX" -n 6
kill "$SPID" 2>/dev/null || true
wait "$SPID" 2>/dev/null || true

if [ -z "${QUICK:-}" ]; then
  echo; echo "### Cold start"
  "$PERF" coldstart -bin "$BIN" -runs 3 -label "(empty disk cache)" -before-each "rm -rf '$OUT/cache'" -- "${server_args[@]}" --addr 127.0.0.1:0
  if [ -n "$HAS_CACHE" ]; then
    "$PERF" coldstart -bin "$BIN" -runs 3 -label "(warm disk cache)" -- "${server_args[@]}" --addr 127.0.0.1:0
  fi
fi
echo; echo "(scratch: $OUT)"
