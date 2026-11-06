#!/usr/bin/env bash
# Load a realistic bulk of objects into the dev kind cluster, for the memory
# benchmark (docs/PERFORMANCE.md, "Memory"). Run after `make cluster`:
#
#   KUBECONFIG=$PWD/.kubeconfig-dev dev/bulk.sh            # load
#   KUBECONFIG=$PWD/.kubeconfig-dev dev/bulk.sh delete     # remove it again
#
# What it creates, in namespaces bulk-0..bulk-2:
#   900 ConfigMaps (300 per namespace, ~2 KB of data each)
#   200 Deployments at 0 replicas, labelled, ~4 KB pod templates
#   150 running pause pods (5 Deployments x 30 replicas)
#   500 Secrets and 300 Services
# Everything goes through client-side `kubectl apply`, so objects carry the
# kubectl.kubernetes.io/last-applied-configuration annotation and
# managedFields, as on a real cluster.
#
# KIND_CLUSTER (default k8sman-dev) names the kind node to raise the kubelet's
# maxPods on (kind's default of 110 is too few for the pods). Set
# KIND_CLUSTER= to skip that, e.g. on a non-kind cluster.
set -euo pipefail

: "${KUBECONFIG:?set KUBECONFIG to the dev kubeconfig, .kubeconfig-dev}"
export KUBECONFIG
KIND_CLUSTER=${KIND_CLUSTER-k8sman-dev}
NS=(bulk-0 bulk-1 bulk-2)
PAUSE_IMAGE=${PAUSE_IMAGE:-registry.k8s.io/pause:3.7} # preloaded on kind nodes

if [[ "${1:-}" == "delete" ]]; then
  kubectl delete ns "${NS[@]}" --ignore-not-found --wait=false
  exit 0
fi

ctx=$(kubectl config current-context)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to load bulk objects into non-kind context '$ctx'" >&2; exit 1 ;;
esac

if [[ -n "$KIND_CLUSTER" ]]; then
  node="$KIND_CLUSTER-control-plane"
  if ! docker exec "$node" grep -q '^maxPods:' /var/lib/kubelet/config.yaml; then
    echo "raising maxPods on $node to 250"
    docker exec "$node" sh -c 'echo "maxPods: 250" >> /var/lib/kubelet/config.yaml && systemctl restart kubelet'
    sleep 10
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" "$PAUSE_IMAGE" "${NS[@]}" <<'PY'
import json, os, random, string, sys

out, image, namespaces = sys.argv[1], sys.argv[2], sys.argv[3:]
rnd = random.Random(42)

def blob(n):
    return "".join(rnd.choice(string.ascii_letters + string.digits) for _ in range(n))

def write(name, docs):
    with open(os.path.join(out, name), "w") as f:
        for d in docs:
            f.write("---\n" + json.dumps(d) + "\n")  # leading --- makes kubectl read it as YAML

write("00-ns.yaml", [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}} for ns in namespaces])

cms, secrets, svcs, deps, pods = [], [], [], [], []
for ni, ns in enumerate(namespaces):
    for i in range(300):
        cms.append({"apiVersion": "v1", "kind": "ConfigMap",
                    "metadata": {"name": f"cfg-{i:03d}", "namespace": ns, "labels": {"app": f"svc-{i % 40}", "tier": "bulk"}},
                    "data": {"app.properties": "\n".join(f"key.{k}={blob(40)}" for k in range(40)), "id": str(i)}})
for i in range(500):
    ns = namespaces[i % len(namespaces)]
    secrets.append({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                    "metadata": {"name": f"sec-{i:03d}", "namespace": ns, "labels": {"app": f"svc-{i % 40}"}},
                    "stringData": {"username": f"user{i}", "password": blob(32), "token": blob(200)}})
for i in range(300):
    ns = namespaces[i % len(namespaces)]
    svcs.append({"apiVersion": "v1", "kind": "Service",
                 "metadata": {"name": f"svc-{i:03d}", "namespace": ns, "labels": {"app": f"svc-{i}", "tier": "bulk"}},
                 "spec": {"selector": {"app": f"svc-{i}"}, "ports": [{"name": "http", "port": 80, "targetPort": 8080}]}})

def deployment(name, ns, replicas, labels, containers):
    return {"apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"name": name, "namespace": ns, "labels": labels},
            "spec": {"replicas": replicas, "selector": {"matchLabels": {"app": name}},
                     "template": {"metadata": {"labels": {**labels, "app": name}}, "spec": {"containers": containers}}}}

for i in range(200):
    ns = namespaces[i % len(namespaces)]
    name = f"dep-{i:03d}"
    labels = {"app.kubernetes.io/name": name, "app.kubernetes.io/part-of": f"system-{i % 10}",
              "app.kubernetes.io/version": f"1.{i % 7}.0", "team": f"team-{i % 5}", "tier": "bulk"}
    env = [{"name": f"SETTING_{k}", "value": blob(48)} for k in range(30)]
    c = {"name": "app", "image": f"example.com/{name}:1.{i % 7}.0", "env": env,
         "ports": [{"containerPort": 8080, "name": "http"}],
         "resources": {"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": {"memory": "128Mi"}},
         "readinessProbe": {"httpGet": {"path": "/healthz", "port": 8080}}}
    deps.append(deployment(name, ns, 0, labels, [c]))
for i in range(5):
    ns = namespaces[i % len(namespaces)]
    name = f"pods-{i}"
    pods.append(deployment(name, ns, 30, {"tier": "bulk-pods"},
                           [{"name": "pause", "image": image, "imagePullPolicy": "IfNotPresent",
                             "resources": {"requests": {"cpu": "1m", "memory": "4Mi"}}}]))

write("10-configmaps.yaml", cms)
write("20-secrets.yaml", secrets)
write("30-services.yaml", svcs)
write("40-deployments.yaml", deps)
write("50-pods.yaml", pods)
PY

for f in "$tmp"/*.yaml; do
  echo "applying $(basename "$f")"
  kubectl apply -f "$f" >/dev/null
done
echo "waiting for the pause pods"
kubectl wait --for=condition=Available deploy -l tier=bulk-pods -A --timeout=300s >/dev/null
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c
