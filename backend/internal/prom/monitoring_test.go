package prom

import (
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

// TestObjectMonitoring covers the inspector's Monitoring tab: which targets
// scrape a pod and from which monitor, why a monitor misses it, and that
// Alertmanager's config is shown without its secrets.
func TestObjectMonitoring(t *testing.T) {
	pod := &subject{
		Kind: "Pod", Namespace: "shop", Name: "api-7d9-abc", Pods: map[string]bool{"api-7d9-abc": true},
		PodLabels: map[string]string{"app": "api", "tier": "web"},
		Ports:     []corev1.ContainerPort{{Name: "http", ContainerPort: 8080}},
		Services: []corev1.Service{{ObjectMeta: metav1.ObjectMeta{Name: "api", Namespace: "shop", Labels: map[string]string{"app": "api"}},
			Spec: corev1.ServiceSpec{Ports: []corev1.ServicePort{{Name: "http", Port: 80, TargetPort: intstr.FromString("http")}}}}},
	}

	t.Run("targets and scrape pools", func(t *testing.T) {
		raw := []promTarget{
			// Matched on the discovered labels even when relabelling renamed them.
			{ScrapePool: "serviceMonitor/shop/api/0", Health: "up", ScrapeURL: "http://10.0.0.1:8080/metrics",
				DiscoveredLabels: map[string]string{"__meta_kubernetes_namespace": "shop", "__meta_kubernetes_pod_name": "api-7d9-abc"},
				Labels:           map[string]string{"job": "api", "exported_pod": "x"}},
			{ScrapePool: "kubernetes-pods", Health: "down", Labels: map[string]string{"namespace": "shop", "pod": "api-7d9-abc", "job": "kubernetes-pods"}},
			{ScrapePool: "serviceMonitor/shop/api/0", Health: "up", Labels: map[string]string{"namespace": "shop", "pod": "api-7d9-zzz"}},
			{ScrapePool: "podMonitor/other/api/0", Health: "up", Labels: map[string]string{"namespace": "other", "pod": "api-7d9-abc"}},
		}
		var res ScrapeResult
		MatchTargets(raw, pod, &res)
		if res.Total != 2 || res.Up != 1 || res.Down != 1 || len(res.Targets) != 2 {
			t.Fatalf("matched = %+v", res)
		}
		if res.Targets[0].Health != "down" || res.Targets[0].Monitor != nil || res.Targets[0].Job != "kubernetes-pods" {
			t.Errorf("down static target first = %+v", res.Targets[0])
		}
		if m := res.Targets[1].Monitor; m == nil || m.Kind != "ServiceMonitor" || m.Namespace != "shop" || m.Name != "api" {
			t.Errorf("monitor = %+v", m)
		}
		if strings.Join(res.Jobs, ",") != "api,kubernetes-pods" {
			t.Errorf("jobs = %v", res.Jobs)
		}
		if m := MonitorForPool("podMonitor/ns/name/3"); m == nil || m.Kind != "PodMonitor" || m.Endpoint != 3 {
			t.Errorf("podMonitor pool = %+v", m)
		}
		if m := MonitorForPool("scrapeConfig/ns/name"); m == nil || m.Kind != "ScrapeConfig" {
			t.Errorf("scrapeConfig pool = %+v", m)
		}
	})

	t.Run("monitor checks explain a miss", func(t *testing.T) {
		in := monitorInputs{
			ServiceMonitors: []crObject{
				{Kind: "ServiceMonitor", Namespace: "shop", Name: "api", Labels: map[string]string{"team": "a"},
					Spec: map[string]any{"selector": map[string]any{"matchLabels": map[string]any{"app": "api"}}, "endpoints": []any{map[string]any{"port": "metrics"}}}},
				{Kind: "ServiceMonitor", Namespace: "shop", Name: "unrelated", Spec: map[string]any{"selector": map[string]any{"matchLabels": map[string]any{"app": "db"}}}},
			},
			PodMonitors: []crObject{
				{Kind: "PodMonitor", Namespace: "shop", Name: "web", Labels: map[string]string{"team": "b"},
					Spec: map[string]any{"selector": map[string]any{"matchLabels": map[string]any{"tier": "web"}}, "podMetricsEndpoints": []any{map[string]any{"port": "http"}}}},
			},
			Prometheuses: []crObject{{Kind: "Prometheus", Namespace: "mon", Name: "k8s", Spec: map[string]any{
				"serviceMonitorSelector": map[string]any{}, "serviceMonitorNamespaceSelector": map[string]any{},
				"podMonitorSelector": map[string]any{"matchLabels": map[string]any{"team": "a"}}, "podMonitorNamespaceSelector": map[string]any{},
			}}},
			NSLabels: func(ns string) map[string]string { return map[string]string{"kubernetes.io/metadata.name": ns} },
		}
		got := CheckMonitors(in, pod, map[string]bool{})
		if len(got) != 2 {
			t.Fatalf("checks = %+v", got)
		}
		failed := func(c MonitorCheck) string {
			var f []string
			for _, ch := range c.Checks {
				if !ch.OK {
					f = append(f, ch.Name+": "+ch.Detail)
				}
			}
			return strings.Join(f, "; ")
		}
		for _, c := range got {
			switch c.Kind + "/" + c.Name {
			case "ServiceMonitor/api":
				if c.Matches || c.Via == nil || c.Via.Name != "api" || failed(c) != `port: wants port "metrics"; Service api has http` {
					t.Errorf("servicemonitor = %+v (%s)", c, failed(c))
				}
			case "PodMonitor/web":
				if c.Matches || failed(c) != "prometheus: not selected: mon/k8s: podMonitorSelector wants team=a (has b)" {
					t.Errorf("podmonitor = %+v (%s)", c, failed(c))
				}
			default:
				t.Errorf("unexpected %s/%s", c.Kind, c.Name)
			}
		}
	})

	t.Run("alertmanager config is redacted", func(t *testing.T) {
		st, err := ParseAMConfig(`
global:
  slack_api_url: https://hooks.example.test/services/T000/B000/XXXX
  smtp_auth_password: hunter2
route:
  receiver: default
  routes:
    - receiver: shop/pager/oncall
      matchers: ['namespace="shop"']
      match_re: {severity: "critical|warning"}
receivers:
  - name: default
  - name: shop/pager/oncall
    pagerduty_configs: [{routing_key: abc123, url: "https://events.example.test/v2/enqueue?token=s3cr3t"}]
    webhook_configs:
      - url: https://user:pw@hooks.example.test/hook
        http_config:
          authorization: {type: Bearer, credentials: tok-1}
          http_headers: {X-Api: {values: [v-1]}}
inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [namespace]
`)
		if err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{"hunter2", "abc123", "s3cr3t", "T000", "tok-1", "v-1", "user:pw", "test/hook", "/v2/enqueue"} {
			if strings.Contains(st.Config, secret) {
				t.Errorf("config leaks %q:\n%s", secret, st.Config)
			}
		}
		if !strings.Contains(st.Config, "https://events.example.test/<redacted>") {
			t.Errorf("url host should stay:\n%s", st.Config)
		}
		r := st.Route.Routes[0]
		if r.Source == nil || r.Source.Name != "pager" || strings.Join(r.Matchers, " ") != `namespace="shop" severity=~"critical|warning"` {
			t.Errorf("route = %+v", r)
		}
		if rc := st.Receivers[1]; len(rc.Integrations) != 2 || rc.Integrations[0].Type != "pagerduty" || rc.Integrations[1].Type != "webhook" {
			t.Errorf("receiver = %+v", rc)
		}
		if len(st.InhibitRules) != 1 || st.InhibitRules[0].Equal[0] != "namespace" {
			t.Errorf("inhibit = %+v", st.InhibitRules)
		}
	})
}
