#!/usr/bin/env bash
# Memory benchmark (docs/PERFORMANCE.md, "Memory"): build one variant.
#
#   tools/membench/build.sh <label>
#
# Builds, from the current checkout, a release app that talks to an external
# backend on 127.0.0.1:7461 (so run.sh can start the backend itself, with
# --pprof and a known token) and runs the scenario driver
# (bench_scenario.dart), plus a release backend binary. Results go to
# $MEMBENCH_DIR (default /tmp/k8sman-membench): <label>.app, server-<label>.
# The driver is copied into frontend/lib and hooked into main.dart only for
# the build; both are restored afterwards. MODE=profile builds a profile app
# instead (for Dart VM service heap snapshots).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=${MEMBENCH_DIR:-/tmp/k8sman-membench}
label=$1
mkdir -p "$out"
[ -f "$out/token" ] || openssl rand -hex 24 > "$out/token"
tok=$(cat "$out/token")

(cd "$root/backend" && CGO_ENABLED=0 GOTOOLCHAIN=local go build -trimpath -ldflags "-s -w" -o "$out/server-$label" ./cmd/k8sman-server)

f="$root/frontend"
cp "$f/lib/main.dart" "$out/main.dart.orig"
restore() { cp "$out/main.dart.orig" "$f/lib/main.dart"; rm -f "$f/lib/bench_scenario.dart"; }
trap restore EXIT
cp "$root/tools/membench/bench_scenario.dart" "$f/lib/bench_scenario.dart"
python3 - "$f/lib/main.dart" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("import 'api/client.dart';", "import 'api/client.dart';\nimport 'bench_scenario.dart';", 1)
s = s.replace("  backend.start();\n", "  backend.start();\n  runBenchScenario(app, api);\n", 1)
assert "runBenchScenario" in s, "main.dart changed; update tools/membench/build.sh"
open(p, "w").write(s)
PY
mode=${MODE:-release}
(cd "$f" && flutter build macos "--$mode" --dart-define=K8SMAN_BACKEND=http://127.0.0.1:7461 "--dart-define=K8SMAN_TOKEN=$tok" > "$out/build-$label.log" 2>&1)
prod=Release; [ "$mode" = profile ] && prod=Profile
rm -rf "$out/$label.app"
cp -R "$f/build/macos/Build/Products/$prod/k8sman.app" "$out/$label.app"
echo "built $out/$label.app"
