package plugins

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"
)

// Alerts are per-object rules evaluated on each overview poll, over the
// lists the overview reads from the watch cache (docs/PLUGINS.md §8). A
// hit becomes an issue in category plugin.<pluginId>.<alertId>. Alerts see
// the object only (no related objects or metrics), like columns.

// pluginAlertBudget bounds all alerts of one plugin in one poll.
const pluginAlertBudget = 500 * time.Millisecond

// AlertHit is one object an alert fired for.
type AlertHit struct {
	Plugin   string `json:"plugin"`
	ID       string `json:"id"`
	Category string `json:"category"`
	Label    string `json:"label"`
	Severity string `json:"severity"`
	Section  string `json:"section"`
	// Group, Kind, Namespace and Name are the object's.
	Group     string    `json:"group"`
	Kind      string    `json:"kind"`
	Namespace string    `json:"namespace,omitempty"`
	Name      string    `json:"name"`
	Message   string    `json:"message"`
	Since     time.Time `json:"since,omitzero"`
}

// AlertCategory is plugin pluginID's alert id as an overview category.
func AlertCategory(pluginID, id string) string { return "plugin." + pluginID + "." + id }

// HasAlerts reports whether any active plugin has alerts.
func (h *Host) HasAlerts() bool {
	for _, p := range h.active() {
		for _, k := range p.m.Kinds {
			if len(k.Alerts) > 0 {
				return true
			}
		}
	}
	return false
}

// AlertLister lists the objects of kind key (pinned to version when set)
// for the overview's scope: ErrNotServed when the cluster doesn't serve it.
type AlertLister func(kindKey, version string) ([]map[string]any, error)

// Alerts evaluates every active plugin's alerts over the objects list
// returns. A kind the cluster doesn't serve is skipped; other list errors
// and evaluation errors are returned with the hits found.
func (h *Host) Alerts(env Env, list AlertLister) ([]AlertHit, []error) {
	var hits []AlertHit
	var errs []error
	for _, p := range h.active() {
		ph, perrs := p.alerts(env, list)
		hits = append(hits, ph...)
		errs = append(errs, perrs...)
	}
	return hits, errs
}

// alerts evaluates p's alerts, within pluginAlertBudget.
func (p *Plugin) alerts(env Env, list AlertLister) ([]AlertHit, []error) {
	var hits []AlertHit
	var errs []error
	ctx, cancel := context.WithTimeout(context.Background(), pluginAlertBudget)
	defer cancel()
	for _, key := range p.m.KindOrder {
		k := p.m.Kinds[key]
		if key == "*" || len(k.Alerts) == 0 {
			continue
		}
		kp := p.kind(key)
		if kp == nil {
			continue
		}
		objs, err := list(key, k.Version)
		if err != nil {
			if !errors.Is(err, ErrNotServed) {
				errs = append(errs, fmt.Errorf("plugin %s: %s: %w", p.ID(), key, err))
			}
			continue
		}
		start := time.Now()
		h, e := kp.evalAlerts(ctx, p.ID(), objs, env)
		hits = append(hits, h...)
		var err2 error
		if len(e) > 0 {
			err2 = e[0]
			errs = append(errs, fmt.Errorf("plugin %s: %w", p.ID(), e[0]))
		}
		p.stats.record(statAlert, time.Since(start), err2)
		if ctx.Err() != nil {
			errs = append(errs, fmt.Errorf("plugin %s: operation interrupted: its alerts took longer than %s", p.ID(), pluginAlertBudget))
			break
		}
	}
	return hits, errs
}

// alertMemoBucket is how long an object's alert results are reused while
// it doesn't change (alerts reading `now` move on with the next bucket,
// as `now` columns do).
const alertMemoBucket = 30 * time.Second

// alertMemo keeps an object version's alert hits for the current bucket.
type alertMemo struct {
	mu     sync.Mutex
	bucket int64
	m      map[string][]AlertHit
}

func (am *alertMemo) get(bucket int64, key string) ([]AlertHit, bool) {
	am.mu.Lock()
	defer am.mu.Unlock()
	if am.bucket != bucket {
		am.bucket, am.m = bucket, map[string][]AlertHit{}
	}
	h, ok := am.m[key]
	return h, ok
}

func (am *alertMemo) put(bucket int64, key string, hits []AlertHit) {
	am.mu.Lock()
	defer am.mu.Unlock()
	if am.bucket == bucket {
		am.m[key] = hits
	}
}

// evalAlerts evaluates kp's alerts for each object. An object whose
// expression fails is skipped (the first errors are returned).
func (kp *kindProgs) evalAlerts(ctx context.Context, pluginID string, objs []map[string]any, env Env) ([]AlertHit, []error) {
	var hits []AlertHit
	var errs []error
	group, kind, _ := strings.Cut(kp.key, "/")
	now := env.now()
	bucket := now.UnixNano() / int64(alertMemoBucket)
	for _, obj := range objs {
		if ctx.Err() != nil {
			break
		}
		uid, _ := nestedString(obj, "metadata", "uid")
		rv, _ := nestedString(obj, "metadata", "resourceVersion")
		memoKey := ""
		if uid != "" && rv != "" {
			memoKey = env.Context + "\x00" + uid + "\x00" + rv
			if h, ok := kp.alertMemo.get(bucket, memoKey); ok {
				hits = append(hits, h...)
				continue
			}
		}
		before, objErr := len(hits), false
		r := &renderer{ctx: ctx, act: newActivation(kp, prepareObject(kp.key, obj), env.Context, now)}
		ns, _ := nestedString(obj, "metadata", "namespace")
		name, _ := nestedString(obj, "metadata", "name")
		for _, ap := range kp.alerts {
			if ap.when == nil {
				continue
			}
			fire, err := r.cond(ap.when)
			if err != nil {
				objErr = true
				if len(errs) < 3 {
					errs = append(errs, err)
				}
				continue
			}
			if !fire {
				continue
			}
			a := ap.a
			hit := AlertHit{Plugin: pluginID, ID: a.ID, Category: AlertCategory(pluginID, a.ID), Label: a.Label,
				Severity: normSeverity(orDefault(a.Severity, "warning")), Section: orDefault(a.Section, "custom"),
				Group: group, Kind: kind, Namespace: ns, Name: name, Message: a.Label}
			if v, err := r.eval(ap.message); err == nil && v != nil {
				hit.Message = fmt.Sprint(v)
			} else if err != nil {
				objErr = true
				if len(errs) < 3 {
					errs = append(errs, err)
				}
			}
			if v, err := r.eval(ap.since); err == nil && v != nil {
				if s, ok := v.(string); ok {
					if t, err := time.Parse(time.RFC3339, s); err == nil {
						hit.Since = t
					}
				}
			}
			hits = append(hits, hit)
		}
		if memoKey != "" && !objErr && ctx.Err() == nil {
			kp.alertMemo.put(bucket, memoKey, slices.Clone(hits[before:]))
		}
	}
	return hits, errs
}
