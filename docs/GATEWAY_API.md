# Gateway API support

k8sman understands the [Gateway API](https://gateway-api.sigs.k8s.io)
(`gateway.networking.k8s.io`): dedicated detail panels, table columns, a nav
group, a "Routed by" cross-link on Services and health issues on the
Overview. Everything appears only when the CRDs are served, so clusters
without the Gateway API look exactly as they did before.

## What's supported

| Kind | Panel (`frontend/lib/panels/gateway/`) |
|---|---|
| GatewayClass | controller, Accepted (with an "Install Envoy Gateway" add-on hook when no controller claims the class), parametersRef link, supported features, Gateways using the class |
| Gateway | Accepted/Programmed with a plain-English "why not", copyable addresses, listeners (protocol, port, hostname, TLS mode, certificateRefs with missing-Secret flags, allowedRoutes namespaces and kinds, attachedRoutes, Conflicted/ResolvedRefs/Programmed problems), attached routes of every kind grouped by listener with their acceptance, a Gateway → listener → route → backend topology tree, infrastructure labels and annotations |
| HTTPRoute, GRPCRoute, TLSRoute, TCPRoute, UDPRoute | one shared panel: hostnames, per-parent Accepted/ResolvedRefs with the controller and explanations (e.g. "Listener 'admin-api' not found on Gateway gateway-demo/demo-gw", "backendRef to Service demo/redis requires a ReferenceGrant in demo", "Listener 'admin' only accepts routes from its own namespace"), rules (matches, readable filters, backends with weight %, missing-Service and needs-ReferenceGrant flags, mirrors, timeouts) and a copyable `curl`/`grpcurl` per rule |
| ReferenceGrant | a one-sentence summary per `from`, the from/to tables, routes and Gateways that rely on it, and references from the same namespaces that it does *not* cover |
| Service (existing panel) | "Routed by": routes whose backendRefs or mirrors target the Service, with weight share and acceptance |

Other integration:

- **Columns** (`backend/internal/columns/builtin.go`): GatewayClass (Controller, Accepted), Gateway (Class, Addresses, Listeners, Programmed), every route kind (Hostnames, Parents, Accepted aggregated over parents, Backends), ReferenceGrant (From, To). Status cells read `True`, `False: <reason>`, `Unknown: <reason>` or `Warning: …` (for example a route that is accepted but has unresolved refs), so they colour correctly.
- **Nav**: a "Gateway API" group (`frontend/lib/ui/resource_nav.dart`).
- **Overview** (`backend/internal/overview/gateway.go`), in a new `network` section, only when the CRDs are served:
  - `gatewayNotReady` (critical): a Gateway that isn't Accepted or Programmed, including "no controller has reconciled it"
  - `gatewayListener` (warning): a listener that is Conflicted, or has ResolvedRefs, Accepted or Programmed set to False
  - `routeNotAccepted`: critical when no parent accepts the route (or none has reported status), a warning when only some do
  - `routeUnresolvedRefs` (warning): ResolvedRefs=False, e.g. RefNotPermitted or BackendNotFound

  Objects younger than a minute get a grace period, and `counts.gateways` and `counts.routes` appear in the response.
- Actions: the generic Edit YAML and Delete work as for any CR.

BackendTLSPolicy and other policy attachments aren't on the standard
channel in v1.2, so they fall back to the generic CR panel.

## Dev cluster setup (kind-k8sman-dev)

The kind node runs Kubernetes 1.25, so the versions below are the newest
pair that installs cleanly there:

- **Gateway API v1.2.1 CRDs**, server-side applied. The standard channel provides GatewayClass, Gateway, HTTPRoute, GRPCRoute and ReferenceGrant. TLSRoute, TCPRoute and UDPRoute come from the experimental channel (only those three CRDs).
- **Envoy Gateway v1.2.8** (`oci://docker.io/envoyproxy/gateway-helm`, release `eg` in `envoy-gateway-system`), installed with `--skip-crds` after applying the chart's own `crds/generated` CRDs, so it doesn't overwrite the standard-channel Gateway API CRDs with experimental ones.

```sh
export KUBECONFIG=.kubeconfig-dev
M=$(go env GOMODCACHE)/sigs.k8s.io/gateway-api@v1.2.1/config/crd   # go mod download sigs.k8s.io/gateway-api@v1.2.1
kubectl apply --server-side -f $M/standard/gateway.networking.k8s.io_{gatewayclasses,gateways,httproutes,grpcroutes,referencegrants}.yaml
kubectl apply --server-side -f $M/experimental/gateway.networking.k8s.io_{tlsroutes,tcproutes,udproutes}.yaml
helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.2.8 --untar
kubectl apply --server-side -f gateway-helm/crds/generated/
helm install eg ./gateway-helm -n envoy-gateway-system --create-namespace --skip-crds --wait
kubectl apply --server-side -f dev/gateway-demo.yaml
openssl req -x509 -newkey rsa:2048 -nodes -keyout tls.key -out tls.crt -days 3650 \
  -subj "/CN=*.example.com" -addext "subjectAltName=DNS:*.example.com"
kubectl -n gateway-demo create secret tls demo-tls --cert=tls.crt --key=tls.key
```

### Sample resources (`dev/gateway-demo.yaml`)

| Object | Shows |
|---|---|
| GatewayClass `eg` | Accepted; parametersRef → EnvoyProxy `envoy-gateway-system/clusterip-proxy` (ClusterIP proxy Service, because kind has no LoadBalancer) |
| GatewayClass `orphan` | no controller (Accepted=Unknown/Pending): the add-on hook |
| Gateway `gateway-demo/demo-gw` | healthy. Listeners: `http` :80 (all namespaces), `https` :443 `*.example.com` with Secret `demo-tls` (namespaces labelled `gateway-access=true`), `admin` :8080 `admin.example.com` (same namespace, HTTPRoute only) and `redis` TCP :6379 |
| Gateway `demo/legacy-gw` | listener `secure` references a missing Secret (ResolvedRefs=False / InvalidCertificateRef) |
| Gateway `gateway-demo/pending-gw` | class `orphan`, so it's never Accepted or Programmed |
| ReferenceGrant `demo/allow-gateway-demo-to-web` | HTTPRoutes and GRPCRoutes in gateway-demo may reference Service `demo/web` (only) |
| HTTPRoute `demo/web-route` | 90/10 weighted split, header and path matches, RequestHeaderModifier, RequestRedirect, URLRewrite, RequestMirror, query/method match, a timeout |
| HTTPRoute `gateway-demo/shop` | cross-namespace backend allowed by the grant, on the HTTPS listener |
| HTTPRoute `gateway-demo/cache-admin` | backend `demo/redis` that no grant covers: RefNotPermitted |
| HTTPRoute `gateway-demo/admin-api` | `sectionName: admin-api` doesn't exist: NotAccepted / NoMatchingParent |
| HTTPRoute `demo/sneaky-admin` | the `admin` listener only allows its own namespace: NotAllowedByListeners |
| HTTPRoute `demo/ghost` | backend Service doesn't exist: BackendNotFound |
| GRPCRoute `gateway-demo/greeter` | method and header match |
| TCPRoute `demo/redis` | TCP listener attachment |

Try them:

```sh
kubectl -n envoy-gateway-system port-forward svc/$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=demo-gw -o name | cut -d/ -f2) 18080:80 18443:443
curl -H 'Host: app.example.com' localhost:18080/          # 200
curl -i -H 'Host: app.example.com' localhost:18080/old    # 301 → /new
curl -H 'Host: ghost.example.com' localhost:18080/        # 500 (BackendNotFound)
curl -H 'Host: cache.example.com' localhost:18080/        # 500 (RefNotPermitted)
curl -k --resolve shop.example.com:18443:127.0.0.1 https://shop.example.com:18443/   # 200
```

The panels' "Try" commands use the Gateway's ClusterIP address, so run them
from inside the cluster, or substitute the port-forward as above.

Panel tests use objects captured from these samples
(`frontend/test/panels/gateway/fixtures/`); the backend overview and column
tests read the same fixtures.

## Next steps

- **Policy attachment**: a generic `targetRefs`-aware view for BackendTLSPolicy (standard from v1.4), BackendLBPolicy and implementation policies (Envoy Gateway's ClientTrafficPolicy, BackendTrafficPolicy and SecurityPolicy), and showing the policies attached to each Gateway, listener and route.
- **GAMMA / mesh**: routes whose parentRef is a Service (east-west); the panels already show such parents as plain links, but they need mesh-specific status and a "Routed by" in reverse.
- **Multi-cluster**: ServiceImport backends (MCS API) and cross-cluster Gateways.
- An Envoy Gateway add-on install path (the catalog entry exists; pin it to chart v1.2.8 for 1.25-era clusters) and a "Create ReferenceGrant" quick fix from the RefNotPermitted callout.
- Live data-plane checks (port-forward to the Envoy Service and probe each rule's example request).
