package overview

import (
	"fmt"
	"strings"
	"time"

	"github.com/matty234/k8sman/backend/internal/kube"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// GatewayGroup is the Gateway API group.
const GatewayGroup = "gateway.networking.k8s.io"

// GatewayRouteResources are the route kinds analysed, by plural resource.
var GatewayRouteResources = []string{"httproutes", "grpcroutes", "tlsroutes", "tcproutes", "udproutes"}

// gatewayGrace hides brand-new Gateway API objects that a controller has not
// had time to reconcile yet.
const gatewayGrace = time.Minute

// GatewayCounts tallies Gateways (present only when the CRDs are served).
type GatewayCounts struct {
	Total      int `json:"total"`
	Programmed int `json:"programmed"`
	Problem    int `json:"problem"`
}

// RouteCounts tallies Gateway API routes of every kind.
type RouteCounts struct {
	Total      int `json:"total"`
	Accepted   int `json:"accepted"`
	Problem    int `json:"problem"`
	Unresolved int `json:"unresolved"`
}

func cond(conds []any, t string) map[string]any {
	for _, c := range conds {
		if m, ok := c.(map[string]any); ok && m["type"] == t {
			return m
		}
	}
	return nil
}

func condTime(c map[string]any) time.Time {
	t, _ := time.Parse(time.RFC3339, kube.Str(c, "lastTransitionTime"))
	if t.Year() <= 1970 {
		return time.Time{}
	}
	return t
}

func describeCond(c map[string]any, fallback string) string {
	if c == nil {
		return fallback
	}
	if m := kube.Str(c, "message"); m != "" {
		return m
	}
	return nonEmpty(kube.Str(c, "reason"), fallback)
}

func (a *analyzer) fresh(o *unstructured.Unstructured) bool {
	return !a.older(o.GetCreationTimestamp(), gatewayGrace)
}

func (a *analyzer) gateways() {
	if a.in.Gateways == nil {
		return
	}
	c := &GatewayCounts{}
	a.res.Counts.Gateways = c
	for i := range a.in.Gateways {
		g := &a.in.Gateways[i]
		c.Total++
		conds, _, _ := unstructured.NestedSlice(g.Object, "status", "conditions")
		accepted, programmed := cond(conds, "Accepted"), cond(conds, "Programmed")
		base := Issue{Kind: "Gateway", Group: GatewayGroup, Namespace: g.GetNamespace(), Name: g.GetName()}
		bad := false
		if !a.fresh(g) {
			for _, cc := range []struct {
				t string
				c map[string]any
			}{{"Accepted", accepted}, {"Programmed", programmed}} {
				if kube.Str(cc.c, "status") == "True" {
					continue
				}
				is := base
				is.Severity, is.Category = Critical, "gatewayNotReady"
				is.Reason = nonEmpty(kube.Str(cc.c, "reason"), "Not"+cc.t)
				if is.Reason == "Pending" {
					is.Reason = "Not" + cc.t
				}
				is.Message = fmt.Sprintf("Not %s: %s", strings.ToLower(cc.t), describeCond(cc.c, "no status from any controller"))
				if kube.Str(cc.c, "reason") == "Pending" || cc.c == nil {
					class, _, _ := unstructured.NestedString(g.Object, "spec", "gatewayClassName")
					is.Message = fmt.Sprintf("No controller has reconciled it; is the controller for GatewayClass %s running?", class)
				}
				is.since = firstNonZero(condTime(cc.c), g.GetCreationTimestamp().Time)
				a.add(is)
				bad = true
				break // one issue per Gateway: Accepted explains Programmed
			}
		}
		listeners, _, _ := unstructured.NestedSlice(g.Object, "status", "listeners")
		for _, l := range listeners {
			lm, _ := l.(map[string]any)
			lconds, _ := lm["conditions"].([]any)
			name := kube.Str(lm, "name")
			var problem map[string]any
			if c := cond(lconds, "Conflicted"); kube.Str(c, "status") == "True" {
				problem = c
			} else if c := cond(lconds, "ResolvedRefs"); kube.Str(c, "status") == "False" {
				problem = c
			} else if c := cond(lconds, "Accepted"); kube.Str(c, "status") == "False" {
				problem = c
			} else if c := cond(lconds, "Programmed"); kube.Str(c, "status") == "False" {
				problem = c
			}
			if problem == nil {
				continue
			}
			is := base
			is.Severity, is.Category = Warning, "gatewayListener"
			is.Reason = nonEmpty(kube.Str(problem, "reason"), kube.Str(problem, "type"))
			is.Message = fmt.Sprintf("Listener %s: %s", name, describeCond(problem, kube.Str(problem, "type")))
			is.since = firstNonZero(condTime(problem), g.GetCreationTimestamp().Time)
			a.add(is)
			bad = true
		}
		if bad {
			c.Problem++
		}
		if kube.Str(programmed, "status") == "True" {
			c.Programmed++
		}
	}
}

func (a *analyzer) routes() {
	if a.in.Routes == nil {
		return
	}
	c := &RouteCounts{}
	a.res.Counts.Routes = c
	for i := range a.in.Routes {
		r := &a.in.Routes[i]
		c.Total++
		parentRefs, _, _ := unstructured.NestedSlice(r.Object, "spec", "parentRefs")
		parents, _, _ := unstructured.NestedSlice(r.Object, "status", "parents")
		accepted, notAccepted := 0, 0
		var firstBad, firstUnresolved map[string]any
		var badParent, unresolvedParent string
		for _, p := range parents {
			pm, _ := p.(map[string]any)
			pconds, _ := pm["conditions"].([]any)
			ref, _ := pm["parentRef"].(map[string]any)
			if ac := cond(pconds, "Accepted"); kube.Str(ac, "status") == "True" {
				accepted++
			} else {
				notAccepted++
				if firstBad == nil {
					firstBad, badParent = ac, parentName(ref, r.GetNamespace())
				}
			}
			if rc := cond(pconds, "ResolvedRefs"); kube.Str(rc, "status") == "False" && firstUnresolved == nil {
				firstUnresolved, unresolvedParent = rc, parentName(ref, r.GetNamespace())
			}
		}
		if accepted > 0 {
			c.Accepted++
		}
		if firstUnresolved != nil {
			c.Unresolved++
		}
		if a.fresh(r) {
			continue
		}
		base := Issue{Kind: r.GetKind(), Group: GatewayGroup, Namespace: r.GetNamespace(), Name: r.GetName()}
		problem := false
		switch {
		case accepted == 0 && len(parentRefs) > 0:
			is := base
			is.Severity, is.Category = Critical, "routeNotAccepted"
			if firstBad == nil {
				is.Reason = "NoStatus"
				is.Message = fmt.Sprintf("No parent has accepted it (no status from any controller for %s)", parentName(asMap(parentRefs[0]), r.GetNamespace()))
				is.since = r.GetCreationTimestamp().Time
			} else {
				is.Reason = nonEmpty(kube.Str(firstBad, "reason"), "NotAccepted")
				is.Message = fmt.Sprintf("Not accepted by %s: %s", badParent, describeCond(firstBad, "not accepted"))
				is.since = firstNonZero(condTime(firstBad), r.GetCreationTimestamp().Time)
			}
			a.add(is)
			problem = true
		case notAccepted > 0:
			is := base
			is.Severity, is.Category = Warning, "routeNotAccepted"
			is.Reason = nonEmpty(kube.Str(firstBad, "reason"), "NotAccepted")
			is.Message = fmt.Sprintf("Accepted by %d of %d parents; %s: %s", accepted, accepted+notAccepted, badParent, describeCond(firstBad, "not accepted"))
			is.since = firstNonZero(condTime(firstBad), r.GetCreationTimestamp().Time)
			a.add(is)
			problem = true
		}
		if firstUnresolved != nil {
			is := base
			is.Severity, is.Category = Warning, "routeUnresolvedRefs"
			is.Reason = nonEmpty(kube.Str(firstUnresolved, "reason"), "ResolvedRefs")
			is.Message = strings.TrimSuffix(describeCond(firstUnresolved, "unresolved references"), ".") + " (via " + unresolvedParent + ")"
			is.since = firstNonZero(condTime(firstUnresolved), r.GetCreationTimestamp().Time)
			a.add(is)
			problem = true
		}
		if problem {
			c.Problem++
		}
	}
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

// parentName renders a parentRef as "Gateway ns/name" (plus the listener).
func parentName(ref map[string]any, routeNS string) string {
	kind := nonEmpty(kube.Str(ref, "kind"), "Gateway")
	ns := nonEmpty(kube.Str(ref, "namespace"), routeNS)
	s := fmt.Sprintf("%s %s/%s", kind, ns, kube.Str(ref, "name"))
	if sec := kube.Str(ref, "sectionName"); sec != "" {
		s += " listener " + sec
	}
	return s
}
