package overview

import (
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"

	"github.com/bargrove/k8sman/backend/internal/prom"
)

func alert(name, severity, state string, labels map[string]string, summary string, started time.Duration) prom.Alert {
	l := map[string]string{"alertname": name, "severity": severity}
	for k, v := range labels {
		l[k] = v
	}
	return prom.Alert{
		Name: name, Severity: severity, State: state, Labels: l,
		Annotations: map[string]string{"summary": summary},
		StartsAt:    now.Add(-started).Format(time.RFC3339), Target: prom.TargetFor(l),
	}
}

func TestFiringAlertsBecomeIssues(t *testing.T) {
	rs := appsv1.ReplicaSet{ObjectMeta: meta("demo", "web-abc", time.Hour, ownedBy("apps/v1", "Deployment", "web"))}
	pod := runningPod("demo", "web-abc-1", time.Hour, ownedBy("apps/v1", "ReplicaSet", "web-abc"))
	in := Input{
		Now:         now,
		Pods:        []corev1.Pod{pod},
		ReplicaSets: []appsv1.ReplicaSet{rs},
		Alerts: []prom.Alert{
			alert("HighErrorRate", "critical", prom.StateFiring, map[string]string{"namespace": "demo", "pod": "web-abc-1"}, "5% of requests fail", 10*time.Minute),
			alert("NodeFilesystemAlmostFull", "warning", prom.StateFiring, map[string]string{"node": "node-1", "instance": "10.0.0.1:9100"}, "Disk is filling up", time.Hour),
			alert("CPUThrottlingHigh", "info", prom.StateFiring, map[string]string{"namespace": "demo", "deployment": "web"}, "", 2*time.Hour),
			alert("ClusterWide", "page", prom.StateFiring, nil, "Something cluster-wide", time.Minute),
			alert("Watchdog", "none", prom.StateFiring, nil, "heartbeat", time.Hour),
			alert("Silenced", "critical", prom.StateSilenced, map[string]string{"namespace": "demo"}, "muted", time.Hour),
		},
	}
	res := Analyze(in)

	crit := issuesBy(res, catAlertCritical)
	if len(crit) != 2 {
		t.Fatalf("critical alert issues = %+v", crit)
	}
	// Sorted by recency within a severity: ClusterWide (1m) before HighErrorRate (10m).
	cw, her := crit[0], crit[1]
	if cw.Kind != "Alert" || cw.Name != "ClusterWide" || cw.Namespace != "" || cw.Severity != Critical {
		t.Errorf("unlinked alert = %+v", cw)
	}
	if her.Kind != "Pod" || her.Name != "web-abc-1" || her.Namespace != "demo" || her.Reason != "HighErrorRate" || her.Message != "5% of requests fail" {
		t.Errorf("pod alert = %+v", her)
	}
	if her.Owner == nil || her.Owner.Kind != "Deployment" || her.Owner.Name != "web" {
		t.Errorf("pod alert owner = %+v", her.Owner)
	}
	if her.Since != now.Add(-10*time.Minute).Format(time.RFC3339) {
		t.Errorf("since = %s", her.Since)
	}

	warn := issuesBy(res, catAlertWarning)
	if len(warn) != 1 || warn[0].Kind != "Node" || warn[0].Name != "node-1" || warn[0].Namespace != "" {
		t.Errorf("node alert = %+v", warn)
	}
	info := issuesBy(res, catAlertInfo)
	if len(info) != 1 || info[0].Kind != "Deployment" || info[0].Group != "apps" {
		t.Errorf("info alert = %+v", info)
	}
	for _, is := range res.Issues {
		if is.Reason == "Watchdog" || is.Reason == "Silenced" {
			t.Errorf("%s should not be an issue", is.Reason)
		}
	}
	var cats []string
	for _, c := range res.Categories {
		if c.Section == "alerts" {
			cats = append(cats, c.ID+":"+c.Severity)
		}
	}
	if len(cats) != 3 || cats[0] != "alertCritical:critical" {
		t.Errorf("alert categories = %v", cats)
	}
}

func TestFilterAlertsByNamespace(t *testing.T) {
	alerts := []prom.Alert{
		alert("A", "warning", prom.StateFiring, map[string]string{"namespace": "demo"}, "", 0),
		alert("B", "warning", prom.StateFiring, map[string]string{"namespace": "other"}, "", 0),
		alert("C", "warning", prom.StateFiring, map[string]string{"node": "n1"}, "", 0),
	}
	if got := FilterAlertsByNamespace(alerts, ""); len(got) != 3 {
		t.Errorf("no filter: %d", len(got))
	}
	got := FilterAlertsByNamespace(alerts, "demo")
	if len(got) != 1 || got[0].Name != "A" {
		t.Errorf("demo: %+v", got)
	}
}

func TestNoAlertsNoAlertCategories(t *testing.T) {
	res := Analyze(Input{Now: now})
	for _, c := range res.Categories {
		if c.Section == "alerts" {
			t.Errorf("unexpected %+v", c)
		}
	}
}
