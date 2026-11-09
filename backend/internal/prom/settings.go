package prom

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
)

// Settings are the prometheus module's per-context settings
// (settings.json's moduleSettings.prometheus).
type Settings struct {
	// Prometheus and Alertmanager name an instance by hand, for setups
	// discovery doesn't recognise (e.g. Mimir or Thanos query-frontend under
	// /prometheus). When set it is the default instance of its kind; the
	// discovered ones stay listed. Empty = discover as usual.
	Prometheus   *Endpoint `json:"prometheus,omitempty"`
	Alertmanager *Endpoint `json:"alertmanager,omitempty"`
	// DefaultRange is the history charts' first range (one of
	// ChartRanges); empty = 1h. Read by the UI.
	DefaultRange string `json:"defaultRange,omitempty"`
}

// Endpoint is a Service reached through the API server's service proxy.
type Endpoint struct {
	Namespace string `json:"namespace"`
	Service   string `json:"service"`
	// Port is the Service port, a number or a name (default 9090 / 9093).
	Port string `json:"port,omitempty"`
	// PathPrefix is where the API is served, e.g. /prometheus.
	PathPrefix string `json:"pathPrefix,omitempty"`
}

// ChartRanges are the values DefaultRange accepts.
var ChartRanges = []string{"10m", "15m", "1h", "6h", "1d", "1w"}

func (e *Endpoint) empty() bool {
	return e == nil || (e.Namespace == "" && e.Service == "" && e.Port == "" && e.PathPrefix == "")
}

func (s Settings) endpoint(kind string) *Endpoint {
	if kind == KindAlertmanager {
		return s.Alertmanager
	}
	return s.Prometheus
}

// Validate checks settings before they are saved.
func (s Settings) Validate() error {
	for _, kind := range []string{KindPrometheus, KindAlertmanager} {
		e := s.endpoint(kind)
		if !e.empty() && (e.Namespace == "" || e.Service == "") {
			return fmt.Errorf("%s: namespace and service are required", kind)
		}
	}
	if s.DefaultRange != "" && !slices.Contains(ChartRanges, s.DefaultRange) {
		return fmt.Errorf("defaultRange must be one of %s", strings.Join(ChartRanges, ", "))
	}
	return nil
}

// instance is the Instance an endpoint stands for.
func (e *Endpoint) instance(kind string) *Instance {
	port := e.Port
	if port == "" {
		port = fmt.Sprint(defaultPorts[kind])
	}
	scheme := "http"
	if port == "443" || port == "https" {
		scheme = "https"
	}
	prefix := ""
	if p := strings.Trim(e.PathPrefix, "/"); p != "" {
		prefix = "/" + p
	}
	return &Instance{
		ID: e.Namespace + "/" + e.Service, Kind: kind, Namespace: e.Namespace, Name: e.Service,
		Source: "settings", Service: e.Service, Port: port, Scheme: scheme, PathPrefix: prefix,
	}
}

// SettingsSource returns the module settings of a kube context. The server
// sets it; nil = none.
var SettingsSource func(kubeContext string) Settings

// ValidateSettings checks a PUT body (unknown fields refused).
func ValidateSettings(raw json.RawMessage) error {
	var s Settings
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return err
	}
	return s.Validate()
}
