package plugins

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// A plugin's status line is its row's summary in Settings ▸ Integrations,
// as modules have one: for each kind with a `status`, how many objects
// there are across the cluster and how many match each count
// ("ExternalSecrets: 12 · not synced: 2"), coloured by the most severe
// count that isn't zero. Counts see the object only, like alerts, and run
// with the alerts' budgets (100,000 per expression, 500 ms per plugin)
// over the same watch-cache lists.

// StatusOut is one plugin's status line (GET /api/plugins/status).
type StatusOut struct {
	Plugin string `json:"plugin"`
	// Text is the line, e.g. "ExternalSecrets: 12 · not synced: 2".
	Text string `json:"text"`
	// Severity is the most severe count that isn't zero (critical,
	// warning or info), "" when every count is zero.
	Severity string       `json:"severity,omitempty"`
	Kinds    []StatusKind `json:"kinds"`
	Errors   []string     `json:"errors,omitempty"`
}

// StatusKind is one kind's part of the line.
type StatusKind struct {
	Key    string           `json:"key"`
	Label  string           `json:"label"`
	Total  int              `json:"total"`
	Counts []StatusCountOut `json:"counts"`
}

// StatusCountOut is one count.
type StatusCountOut struct {
	Label    string `json:"label"`
	Severity string `json:"severity"`
	Count    int    `json:"count"`
}

var severityRank = map[string]int{"info": 1, "warning": 2, "critical": 3}

// Status is the status line of every active plugin that has one and whose
// kinds (with a status) the cluster serves, by plugin id.
func (h *Host) Status(env Env, list AlertLister) map[string]StatusOut {
	out := map[string]StatusOut{}
	for _, p := range h.active() {
		if s, ok := p.status(env, list); ok {
			out[p.ID()] = s
		}
	}
	return out
}

// status is p's line, within pluginAlertBudget; ok is false when it has
// none here (no kind with a status, or none served).
func (p *Plugin) status(env Env, list AlertLister) (StatusOut, bool) {
	out := StatusOut{Plugin: p.ID(), Kinds: []StatusKind{}}
	ctx, cancel := context.WithTimeout(context.Background(), pluginAlertBudget)
	defer cancel()
	for _, key := range p.m.KindOrder {
		k := p.m.Kinds[key]
		if key == "*" || k.Status == nil {
			continue
		}
		kp := p.kind(key)
		if kp == nil {
			out.Errors = append(out.Errors, key+": the plugin's entry for this kind has errors")
			continue
		}
		objs, err := list(key, k.Version)
		if err != nil {
			if !errors.Is(err, ErrNotServed) {
				out.Errors = append(out.Errors, fmt.Sprintf("%s: %v", key, err))
			}
			continue
		}
		start := time.Now()
		sk, errs := kp.evalStatus(ctx, objs, env)
		var first error
		if len(errs) > 0 {
			first = errs[0]
			out.Errors = append(out.Errors, errs[0].Error())
		}
		p.stats.record(statAlert, time.Since(start), first)
		out.Kinds = append(out.Kinds, sk)
		if ctx.Err() != nil {
			out.Errors = append(out.Errors, fmt.Sprintf("operation interrupted: the status took longer than %s", pluginAlertBudget))
			break
		}
	}
	if len(out.Kinds) == 0 && len(out.Errors) == 0 {
		return out, false
	}
	out.Text, out.Severity = statusLine(out.Kinds)
	return out, true
}

// statusLine is the kinds' text and most severe non-zero count.
func statusLine(kinds []StatusKind) (string, string) {
	var parts []string
	sev := ""
	for _, k := range kinds {
		parts = append(parts, k.Label+": "+strconv.Itoa(k.Total))
		for _, c := range k.Counts {
			parts = append(parts, c.Label+": "+strconv.Itoa(c.Count))
			if c.Count > 0 && severityRank[c.Severity] > severityRank[sev] {
				sev = c.Severity
			}
		}
	}
	return strings.Join(parts, " · "), sev
}

// evalStatus counts objs and those matching each of kp's counts. An
// object whose expression fails isn't counted (the first errors are
// returned).
func (kp *kindProgs) evalStatus(ctx context.Context, objs []map[string]any, env Env) (StatusKind, []error) {
	st := kp.kind.Status
	out := StatusKind{Key: kp.key, Label: st.Label, Total: len(objs), Counts: make([]StatusCountOut, len(kp.status))}
	for i, sp := range kp.status {
		out.Counts[i] = StatusCountOut{Label: sp.c.Label, Severity: orDefault(sp.c.Severity, "warning")}
	}
	var errs []error
	now := env.now()
	for _, obj := range objs {
		if ctx.Err() != nil {
			break
		}
		r := &renderer{ctx: ctx, act: newActivation(kp, prepareObject(kp.key, obj), env.Context, now)}
		for i, sp := range kp.status {
			if sp.when == nil {
				continue
			}
			ok, err := r.cond(sp.when)
			if err != nil {
				if len(errs) < 3 {
					errs = append(errs, err)
				}
				continue
			}
			if ok {
				out.Counts[i].Count++
			}
		}
	}
	return out, errs
}
