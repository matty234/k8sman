package plugins

import (
	"slices"
	"strings"

	"github.com/google/cel-go/common/ast"
	"github.com/google/cel-go/common/operators"
	"github.com/google/cel-go/common/types"
	"gopkg.in/yaml.v3"
)

// coreSections are the section ids of the app's compiled-in panels, by
// kind key, top to bottom (a section may not show for every object): the
// ids a plugin section's `after` names. The frontend wraps each section in
// a CoreSection with its id (frontend/lib/panels); keep this list, those
// ids and docs/PLUGINS.md §4 in step. It only serves validate's warnings:
// at runtime the UI places sections by the ids it draws, and an id it
// doesn't draw sends the section to the bottom.
var coreSections = func() map[string][]string {
	m := map[string][]string{
		"/Pod":                                  {"status", "containers", "volumes", "scheduling", "configuration", "history", "network", "gpus", "conditions"},
		"apps/Deployment":                       {"status", "pods", "usage", "history", "rollout-history", "strategy", "pod-template", "scheduling", "conditions", "selector"},
		"apps/DaemonSet":                        {"status", "pods", "usage", "history", "strategy", "scheduling", "pod-template", "conditions", "selector"},
		"apps/StatefulSet":                      {"status", "pods", "usage", "history", "volume-claims", "strategy", "pod-template", "scheduling", "conditions", "selector"},
		"apps/ReplicaSet":                       {"status", "pods", "pod-template", "scheduling", "conditions", "selector"},
		"autoscaling/HorizontalPodAutoscaler":   {"status", "metrics", "behavior", "conditions"},
		"policy/PodDisruptionBudget":            {"status", "pods", "conditions", "selector"},
		"batch/Job":                             {"status", "pods", "spec", "pod-template", "conditions"},
		"batch/CronJob":                         {"status", "jobs", "next-runs", "spec", "job-template"},
		"/Service":                              {"overview", "routed-by"},
		"networking.k8s.io/Ingress":             {"overview"},
		"networking.k8s.io/IngressClass":        {"class", "used-by"},
		"networking.k8s.io/NetworkPolicy":       {"overview"},
		"discovery.k8s.io/EndpointSlice":        {"status", "endpoints"},
		"/Endpoints":                            {"status"}, // then subset-0, subset-1, …
		"/ConfigMap":                            {"status", "data", "used-by", "binary-data"},
		"/Secret":                               {"status", "external-secret", "data", "used-by"},
		"/ServiceAccount":                       {"status", "used-by", "secrets", "permissions"},
		"/PersistentVolumeClaim":                {"status", "history", "mounted-by", "volume", "data-source", "conditions", "statefulset"},
		"/PersistentVolume":                     {"status", "source", "node-affinity", "mount-options"},
		"storage.k8s.io/StorageClass":           {"status", "used-by", "parameters", "allowed-topologies"},
		"/Node":                                 {"overview", "gpus", "capacity", "taints", "conditions", "system-info", "addresses", "images"},
		"/Namespace":                            {"overview", "quotas", "warnings"},
		"/Event":                                {"status", "other-events"},
		"events.k8s.io/Event":                   {"status", "other-events"},
		"/ResourceQuota":                        {"usage", "scopes"},
		"/LimitRange":                           {"limits"},
		"rbac.authorization.k8s.io/Role":        {"permission-matrix", "rules", "bound-by"},
		"rbac.authorization.k8s.io/ClusterRole": {"permission-matrix", "rules", "aggregation", "bound-by"},
		"rbac.authorization.k8s.io/RoleBinding": {"role-reference", "subjects", "granted-rules"},
		"rbac.authorization.k8s.io/ClusterRoleBinding":                  {"role-reference", "subjects", "granted-rules"},
		"admissionregistration.k8s.io/ValidatingAdmissionPolicy":        {"policy", "match-constraints", "match-conditions", "variables", "validations", "audit-annotations", "bindings", "status"},
		"admissionregistration.k8s.io/MutatingAdmissionPolicy":          {"policy", "match-constraints", "match-conditions", "variables", "mutations", "bindings", "status"},
		"admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding": {"binding", "parameters", "match-resources"},
		"admissionregistration.k8s.io/MutatingAdmissionPolicyBinding":   {"binding", "parameters", "match-resources"},
		"admissionregistration.k8s.io/ValidatingWebhookConfiguration":   {"webhooks"},
		"admissionregistration.k8s.io/MutatingWebhookConfiguration":     {"webhooks"},
		"apiextensions.k8s.io/CustomResourceDefinition":                 {"definition", "conditions", "versions", "instances", "schema"},
		// Integration modules' panels (while the module is on).
		"gateway.networking.k8s.io/GatewayClass":   {"class", "supported-features", "gateways"},
		"gateway.networking.k8s.io/Gateway":        {"overview"},
		"gateway.networking.k8s.io/ReferenceGrant": {"grant", "used-by"},
		"argoproj.io/AppProject":                   {"summary", "applications", "source-repositories", "destinations", "resource-kinds", "sync-windows", "roles", "orphaned-resources"},
		"argoproj.io/Application":                  {"status", "last-operation", "source", "destination", "managed-resources", "sync-history"},
		"argoproj.io/ApplicationSet":               {"status", "generated-applications", "generators", "template", "conditions"},
		"argoproj.io/CronWorkflow":                 {"schedule", "status", "conditions", "workflows", "workflow-spec"},
		"argoproj.io/WorkflowTemplate":             {"template", "parameters", "templates", "workflows"},
		"argoproj.io/ClusterWorkflowTemplate":      {"template", "parameters", "templates", "workflows"},
		"argoproj.io/Workflow":                     {"summary", "parameters", "steps", "conditions", "spec"},
		"monitoring.coreos.com/ServiceMonitor":     {"selects", "selected-by", "targets"},
		"monitoring.coreos.com/PodMonitor":         {"selects", "selected-by", "targets"},
		"monitoring.coreos.com/Probe":              {"overview", "selected-by", "targets"},
		"monitoring.coreos.com/ScrapeConfig":       {"overview", "selected-by", "targets"},
		"monitoring.coreos.com/Prometheus":         {"overview", "selects", "targets", "alerting", "conditions"},
		"monitoring.coreos.com/Alertmanager":       {"overview", "configuration", "routing", "alerts", "silences", "conditions"},
		"monitoring.coreos.com/AlertmanagerConfig": {"applies", "route", "receivers", "inhibit", "time-intervals"},
		"monitoring.coreos.com/PrometheusRule":     {"rules", "selected-by"},
	}
	for _, r := range []string{"HTTPRoute", "GRPCRoute", "TLSRoute", "TCPRoute", "UDPRoute"} {
		m["gateway.networking.k8s.io/"+r] = []string{"overview"}
	}
	return m
}()

// isCoreSection is whether id is a core section of any kind (for "*").
func isCoreSection(id string) bool {
	for _, ids := range coreSections {
		if slices.Contains(ids, id) {
			return true
		}
	}
	return false
}

// validatePlacement checks section s's placement and after (sn is its
// YAML) in kind entry key's panel or, with inTab, in a tab.
func validatePlacement(d *decoder, s *Section, sn *yaml.Node, key string, inTab bool) {
	if s.Placement == "" && s.After == "" {
		return
	}
	at := func(f string) *yaml.Node { return orNode(resolve(field(sn, f)), sn) }
	where := at("after")
	if s.After == "" {
		where = at("placement")
	}
	if s.Placement != "" && !slices.Contains(placements, s.Placement) {
		d.errAt(at("placement"), "placement must be top or bottom")
	}
	if s.Placement != "" && s.After != "" {
		d.errAt(at("after"), "a section takes placement or after, not both")
	}
	if inTab {
		d.warnAt(where, "placement and after place the Overview's sections; a tab's sections keep their order")
		return
	}
	if key == "*" {
		if s.After != "" && !isCoreSection(s.After) {
			d.warnAt(where, "after: %q is not a section of any compiled-in panel; the section goes at the bottom", s.After)
		}
		return
	}
	ids, ok := coreSections[key]
	switch {
	case !ok:
		d.warnAt(where, "%s has no compiled-in panel: plugin sections come first there, and placement and after are ignored", key)
	case s.After != "" && !slices.Contains(ids, s.After):
		d.warnAt(where, "after: %q is not a section of the %s panel (%s); the section goes at the bottom", s.After, key, strings.Join(ids, ", "))
	}
}

// checkSeverity warns about the severity names expression e can return
// (its literal results, through conditionals) that aren't canonical: an
// old alias, or no severity at all. CEL errors are compile's to report.
func checkSeverity(d *decoder, e Expr) {
	if !e.IsSet() {
		return
	}
	env, err := envs()
	if err != nil {
		return
	}
	a, iss := env.Parse(e.Src)
	if iss != nil && iss.Err() != nil {
		return
	}
	native := a.NativeRep()
	info := native.SourceInfo()
	var walk func(x ast.Expr)
	walk = func(x ast.Expr) {
		switch x.Kind() {
		case ast.CallKind:
			if c := x.AsCall(); c.FunctionName() == operators.Conditional && len(c.Args()) == 3 {
				walk(c.Args()[1])
				walk(c.Args()[2])
			}
		case ast.LiteralKind:
			s, ok := x.AsLiteral().(types.String)
			if !ok {
				return
			}
			name := string(s)
			msg := ""
			if canon, alias := severityAliases[name]; alias {
				msg = "severity " + `"` + name + `" is an old name: write "` + canon + `"`
			} else if !slices.Contains(severities, name) {
				msg = `"` + name + `" is not a severity (` + strings.Join(severities, ", ") + "); it is shown without one"
			}
			if msg != "" {
				loc := info.GetStartLocation(x.ID())
				line, col := loc.Line(), loc.Column()
				if line <= 0 {
					line, col = 1, 0
				}
				d.diags = append(d.diags, d.diagAt(d.exprPos(e, line, col), true, "%s", msg))
			}
		}
	}
	walk(native.Expr())
}

// severityName is evaluated severity v as a canonical name: aliases
// mapped, anything else "" (shown without one).
func severityName(v any) string {
	s, _ := v.(string)
	if canon, ok := severityAliases[s]; ok {
		return canon
	}
	if slices.Contains(severities, s) {
		return s
	}
	return ""
}
