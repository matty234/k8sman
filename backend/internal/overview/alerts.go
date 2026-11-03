package overview

import (
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"

	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// Alert categories: firing Alertmanager alerts by severity.
const (
	catAlertCritical = "alertCritical"
	catAlertWarning  = "alertWarning"
	catAlertInfo     = "alertInfo"
)

// alertSeverity maps an alert's severity label onto issue severity.
// "none" (Watchdog, InfoInhibitor) is plumbing, not a problem: skipped.
func alertSeverity(label string) (sev, category string, ok bool) {
	switch strings.ToLower(label) {
	case "critical", "error", "page":
		return Critical, catAlertCritical, true
	case "warning", "warn":
		return Warning, catAlertWarning, true
	case "none":
		return "", "", false
	default:
		return Info, catAlertInfo, true
	}
}

// alerts turns firing alerts into issues, linked to the object their labels
// identify (pod, workload, node, PVC, ...) or, failing that, to the alert.
func (a *analyzer) alerts() {
	if len(a.in.Alerts) == 0 {
		return
	}
	pods := map[string]*corev1.Pod{}
	for i := range a.in.Pods {
		p := &a.in.Pods[i]
		pods[kube.Key(p.Namespace, p.Name)] = p
	}
	for _, al := range a.in.Alerts {
		if al.State != "" && al.State != prom.StateFiring {
			continue
		}
		sev, cat, ok := alertSeverity(al.Severity)
		if !ok {
			continue
		}
		is := Issue{
			Severity: sev,
			Category: cat,
			Kind:     "Alert",
			Name:     al.Name,
			Reason:   al.Name,
			Message:  firstAnnotation(al.Annotations, "summary", "description", "message"),
		}
		if t := al.Target; t != nil {
			is.Kind, is.Group, is.Namespace, is.Name = t.Kind, t.Group, t.Namespace, t.Name
			if t.Kind == "Pod" {
				if p := pods[kube.Key(t.Namespace, t.Name)]; p != nil {
					is.Owner = a.topOwner(p.Namespace, p.OwnerReferences)
				}
			}
		} else if ns := al.Labels["namespace"]; ns != "" {
			is.Namespace = ns
		}
		if t, err := time.Parse(time.RFC3339Nano, al.StartsAt); err == nil {
			is.since = t
		}
		a.add(is)
	}
}

func firstAnnotation(m map[string]string, keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(m[k]); v != "" {
			return v
		}
	}
	return ""
}

// FilterAlertsByNamespace keeps alerts whose namespace label is ns (for a
// namespaced overview). Cluster-scoped alerts (no namespace) are dropped.
func FilterAlertsByNamespace(alerts []prom.Alert, ns string) []prom.Alert {
	if ns == "" {
		return alerts
	}
	out := make([]prom.Alert, 0, len(alerts))
	for _, a := range alerts {
		if a.Labels["namespace"] == ns {
			out = append(out, a)
		}
	}
	return out
}
