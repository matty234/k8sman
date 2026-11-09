package overview

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Real objects captured from the dev cluster (Envoy Gateway v1.2.8).
const gwFixtures = "../../../frontend/test/panels/gateway/fixtures"

func gwFixture(t *testing.T, name string) unstructured.Unstructured {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(gwFixtures, name+".json"))
	if err != nil {
		t.Fatalf("fixture %s: %v", name, err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return unstructured.Unstructured{Object: m}
}

func gwObj(kind, ns, name string, age time.Duration, spec, status map[string]any) unstructured.Unstructured {
	u := unstructured.Unstructured{Object: map[string]any{"spec": spec, "status": status}}
	u.SetAPIVersion("gateway.networking.k8s.io/v1")
	u.SetKind(kind)
	u.SetNamespace(ns)
	u.SetName(name)
	u.SetCreationTimestamp(ago(age))
	return u
}

func c(t, status, reason, msg string) map[string]any {
	return map[string]any{"type": t, "status": status, "reason": reason, "message": msg, "lastTransitionTime": now.Add(-10 * time.Minute).Format(time.RFC3339)}
}

func issuesFor(res *Result, kind, name string) []Issue {
	var out []Issue
	for _, is := range res.Issues {
		if is.Kind == kind && is.Name == name {
			out = append(out, is)
		}
	}
	return out
}

func TestGatewayAPIFixtures(t *testing.T) {
	// Fixtures are minutes old relative to their capture; analyse "later".
	in := Input{
		Now:      time.Now().Add(24 * time.Hour),
		Gateways: []unstructured.Unstructured{gwFixture(t, "gateway-demo-gw"), gwFixture(t, "gateway-legacy-gw"), gwFixture(t, "gateway-pending-gw")},
	}
	for _, n := range []string{"httproute-web-route", "httproute-shop", "httproute-cache-admin", "httproute-admin-api", "httproute-sneaky-admin", "httproute-ghost", "grpcroute-greeter", "tcproute-redis"} {
		in.Routes = append(in.Routes, gwFixture(t, n))
	}
	res := Analyze(in)

	if got := issuesFor(res, "Gateway", "demo-gw"); len(got) != 0 {
		t.Errorf("healthy demo-gw has issues: %+v", got)
	}
	pending := issuesFor(res, "Gateway", "pending-gw")
	if len(pending) != 1 || pending[0].Severity != Critical || pending[0].Category != "gatewayNotReady" ||
		!strings.Contains(pending[0].Message, "GatewayClass orphan") {
		t.Errorf("pending-gw: %+v", pending)
	}
	legacy := issuesFor(res, "Gateway", "legacy-gw")
	if len(legacy) != 1 || legacy[0].Category != "gatewayListener" || legacy[0].Severity != Warning ||
		legacy[0].Reason != "InvalidCertificateRef" || !strings.Contains(legacy[0].Message, "Listener secure") {
		t.Errorf("legacy-gw: %+v", legacy)
	}

	for _, ok := range []string{"web-route", "shop", "greeter", "redis"} {
		if got := issuesFor(res, "HTTPRoute", ok); len(got) != 0 {
			t.Errorf("%s should be healthy: %+v", ok, got)
		}
	}
	admin := issuesFor(res, "HTTPRoute", "admin-api")
	if len(admin) != 1 || admin[0].Severity != Critical || admin[0].Reason != "NoMatchingParent" || !strings.Contains(admin[0].Message, "listener admin-api") {
		t.Errorf("admin-api: %+v", admin)
	}
	sneaky := issuesFor(res, "HTTPRoute", "sneaky-admin")
	if len(sneaky) != 1 || sneaky[0].Reason != "NotAllowedByListeners" || sneaky[0].Severity != Critical {
		t.Errorf("sneaky-admin: %+v", sneaky)
	}
	cache := issuesFor(res, "HTTPRoute", "cache-admin")
	if len(cache) != 1 || cache[0].Category != "routeUnresolvedRefs" || cache[0].Severity != Warning || cache[0].Reason != "RefNotPermitted" {
		t.Errorf("cache-admin: %+v", cache)
	}
	ghost := issuesFor(res, "HTTPRoute", "ghost")
	if len(ghost) != 1 || ghost[0].Reason != "BackendNotFound" {
		t.Errorf("ghost: %+v", ghost)
	}

	g, r := res.Counts.Gateways, res.Counts.Routes
	if g == nil || g.Total != 3 || g.Programmed != 2 || g.Problem != 2 {
		t.Errorf("gateway counts: %+v", g)
	}
	if r == nil || r.Total != 8 || r.Accepted != 6 || r.Problem != 4 || r.Unresolved != 2 {
		t.Errorf("route counts: %+v", r)
	}
	// Categories carry the network section and the worst severity.
	cats := map[string]Category{}
	for _, c := range res.Categories {
		cats[c.ID] = c
	}
	if cats["routeNotAccepted"].Count != 2 || cats["routeNotAccepted"].Section != "network" || cats["gatewayNotReady"].Severity != Critical {
		t.Errorf("categories: %+v", res.Categories)
	}
}
