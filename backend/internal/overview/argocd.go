package overview

import (
	"fmt"
	"strings"
	"time"
)

// ArgoCounts tallies Argo CD Applications (only when the CRD is served).
type ArgoCounts struct {
	Total     int `json:"total"`
	Synced    int `json:"synced"`
	OutOfSync int `json:"outOfSync"`
	Healthy   int `json:"healthy"`
	Degraded  int `json:"degraded"`
	Missing   int `json:"missing"`
	Failed    int `json:"failed"`
}

func str(m map[string]any, path ...string) string {
	var cur any = m
	for _, p := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return ""
		}
		cur = mm[p]
	}
	s, _ := cur.(string)
	return s
}

func obj(m map[string]any, path ...string) map[string]any {
	var cur any = m
	for _, p := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[p]
	}
	mm, _ := cur.(map[string]any)
	return mm
}

func list(m map[string]any, path ...string) []map[string]any {
	var cur any = m
	for _, p := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[p]
	}
	l, _ := cur.([]any)
	var out []map[string]any
	for _, e := range l {
		if mm, ok := e.(map[string]any); ok {
			out = append(out, mm)
		}
	}
	return out
}

func parseTS(s string) time.Time {
	t, _ := time.Parse(time.RFC3339, s)
	return t
}

// argoApps reports each Argo CD Application in its worst state, once:
// failed last sync or an error condition (critical), Degraded (critical),
// Missing (warning), OutOfSync (warning).
func (a *analyzer) argoApps() {
	if a.in.ArgoApps == nil {
		return
	}
	c := &ArgoCounts{}
	a.res.Counts.ArgoApps = c
	for _, app := range a.in.ArgoApps {
		c.Total++
		name := str(app, "metadata", "name")
		ns := str(app, "metadata", "namespace")
		sync := str(app, "status", "sync", "status")
		health := str(app, "status", "health", "status")
		healthSince := parseTS(str(app, "status", "health", "lastTransitionTime"))
		op := obj(app, "status", "operationState")
		phase := str(op, "phase")
		failedOp := phase == "Failed" || phase == "Error"

		var errConds []string
		var condSince time.Time
		for _, cond := range list(app, "status", "conditions") {
			t := str(cond, "type")
			if strings.HasSuffix(t, "Error") {
				errConds = append(errConds, t+": "+str(cond, "message"))
				if ts := parseTS(str(cond, "lastTransitionTime")); ts.After(condSince) {
					condSince = ts
				}
			}
		}

		switch sync {
		case "Synced":
			c.Synced++
		case "OutOfSync":
			c.OutOfSync++
		}
		switch health {
		case "Healthy":
			c.Healthy++
		case "Degraded":
			c.Degraded++
		case "Missing":
			c.Missing++
		}
		if failedOp {
			c.Failed++
		}

		state := fmt.Sprintf("sync %s, health %s", orUnknown(sync), orUnknown(health))
		is := Issue{Kind: "Application", Group: "argoproj.io", Namespace: ns, Name: name}
		switch {
		case failedOp || len(errConds) > 0:
			is.Severity, is.Category = Critical, "argoSyncFailed"
			msg := ""
			if failedOp {
				is.Reason = "Sync" + phase
				msg = str(op, "message")
				is.since = parseTS(str(op, "finishedAt"))
			}
			if len(errConds) > 0 {
				if is.Reason == "" {
					is.Reason = strings.SplitN(errConds[0], ":", 2)[0]
					is.since = condSince
					msg = errConds[0]
				} else if !strings.Contains(errConds[0], msg) {
					msg += "; " + errConds[0]
				}
			}
			is.Message = msg + " (" + state + ")"
		case health == "Degraded":
			is.Severity, is.Category, is.Reason = Critical, "argoDegraded", "Degraded"
			is.Message = firstNonEmpty(str(app, "status", "health", "message"), "One or more resources are degraded") + " (" + state + ")"
			is.since = healthSince
		case health == "Missing":
			is.Severity, is.Category, is.Reason = Warning, "argoMissing", "Missing"
			is.Message = "Resources have not been created (" + state + ")"
			is.since = healthSince
		case sync == "OutOfSync":
			is.Severity, is.Category, is.Reason = Warning, "argoOutOfSync", "OutOfSync"
			n := 0
			for _, r := range list(app, "status", "resources") {
				if str(r, "status") != "Synced" {
					n++
				}
			}
			auto := "manual sync"
			if obj(app, "spec", "syncPolicy", "automated") != nil {
				auto = "auto-sync"
			}
			is.Message = fmt.Sprintf("%d resource(s) differ from git (%s, health %s)", n, auto, orUnknown(health))
			is.since = parseTS(str(app, "status", "reconciledAt"))
		default:
			continue
		}
		a.add(is)
	}
}

func orUnknown(s string) string {
	if s == "" {
		return "Unknown"
	}
	return s
}

func firstNonEmpty(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}
