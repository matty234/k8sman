package server

import (
	"encoding/json"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/overview"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// promModule is the Prometheus stack integration: discovery, Alertmanager
// alerts and silences, rules, targets and PromQL (/api/prom/*), and firing
// alerts in the health overview.
//
// Other code also queries Prometheus in-process (GPU stats, PVC usage);
// that stays on whether or not this module is enabled.
type promModule struct{}

func (m *promModule) Name() string { return "prometheus" }

// Routes mounts /api/prom/*. Silences are refused only with --read-only
// (they change Alertmanager, not the cluster).
func (m *promModule) Routes(r httpx.Router, d Deps) {
	prom.Register(r, d.Mgr, d.ReadOnlyFlag)
	prom.SettingsSource = func(kubeContext string) prom.Settings {
		var s prom.Settings
		_, _ = d.Settings.ModuleSettings(m.Name(), kubeContext, &s)
		return s
	}
}

// ValidateSettings implements Configurable.
func (m *promModule) ValidateSettings(raw json.RawMessage) error { return prom.ValidateSettings(raw) }

// OverviewInputs adds firing Alertmanager alerts in the namespace.
func (m *promModule) OverviewInputs(l *OverviewLists) {
	l.Go("alerts", func() (func(*overview.Input), error) {
		a, err := prom.ActiveAlerts(l.Ctx, l.Clients)
		alerts := overview.FilterAlertsByNamespace(a, l.Namespace)
		return func(in *overview.Input) { in.Alerts = alerts }, err
	})
}
