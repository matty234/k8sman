#!/usr/bin/env bash
# Create or delete the perf load namespace in the dev kind cluster.
#   tools/perf/load.sh up    # 1,500 ConfigMaps, a 300-replica pause Deployment, 200 CRs
#   tools/perf/load.sh down
# Only ever targets the dev kind cluster.
set -euo pipefail
KUBECONFIG_DEV=${KUBECONFIG_DEV:-$(cd "$(dirname "$0")/../.." && pwd)/.kubeconfig-dev}
# The worktree may not have its own copy; fall back to the main checkout's.
[ -f "$KUBECONFIG_DEV" ] || KUBECONFIG_DEV=/Users/matthew/workspace/k8sman/.kubeconfig-dev
CTX=${CTX:-kind-k8sman-dev}
NS=${NS:-perf-load}
CMS=${CMS:-1500}
PODS=${PODS:-300}
CRS=${CRS:-200}
k() { kubectl --kubeconfig "$KUBECONFIG_DEV" --context "$CTX" "$@"; }

case "${1:-}" in
up)
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f -
  cat <<EOF | k apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.perf.k8sman.dev
spec:
  group: perf.k8sman.dev
  scope: Namespaced
  names: {plural: widgets, singular: widget, kind: Widget}
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
    additionalPrinterColumns:
    - {name: Size, type: integer, jsonPath: .spec.size}
    - {name: Colour, type: string, jsonPath: .spec.colour}
EOF
  k wait --for=condition=Established crd/widgets.perf.k8sman.dev --timeout=60s
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  for ((i = 0; i < CMS; i++)); do
    printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: perf-cm-%d\n  labels: {app: perf, shard: "s%d"}\ndata:\n  key: "value-%d"\n  config.yaml: |\n    replicas: 3\n    image: example/app:%d\n    env: [a, b, c]\n' "$i" $((i % 10)) "$i" "$i"
  done >"$tmp/cms.yaml"
  for ((i = 0; i < CRS; i++)); do
    printf -- '---\napiVersion: perf.k8sman.dev/v1\nkind: Widget\nmetadata:\n  name: widget-%d\nspec:\n  size: %d\n  colour: blue\n' "$i" "$i"
  done >"$tmp/crs.yaml"
  k -n "$NS" apply --server-side -f "$tmp/cms.yaml" >/dev/null
  k -n "$NS" apply --server-side -f "$tmp/crs.yaml" >/dev/null
  cat <<EOF | k -n "$NS" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: perf-pause
spec:
  replicas: $PODS
  selector: {matchLabels: {app: perf-pause}}
  template:
    metadata: {labels: {app: perf-pause}}
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.7
        imagePullPolicy: IfNotPresent
        resources: {requests: {cpu: 1m, memory: 4Mi}}
---
apiVersion: v1
kind: Pod
metadata:
  name: perf-logger
spec:
  terminationGracePeriodSeconds: 0
  containers:
  - name: logger
    image: busybox:1.36
    imagePullPolicy: IfNotPresent
    command: [sh, -c, 'i=0; while true; do echo "line \$i"; i=\$((i+1)); sleep 1; done']
EOF
  echo "load namespace $NS: $CMS ConfigMaps, $PODS pods (kind caps a node at 110 running; the rest stay Pending), $CRS Widgets"
  ;;
down)
  k delete namespace "$NS" --ignore-not-found --wait=true
  k delete crd widgets.perf.k8sman.dev --ignore-not-found
  ;;
*)
  echo "usage: $0 up|down" >&2
  exit 2
  ;;
esac
