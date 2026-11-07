package hubble

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// Settings are the hubble module's per-context settings (settings.json's
// moduleSettings.hubble), for clusters where discovery guesses wrong.
type Settings struct {
	// Relay is the relay Service as namespace/name[:port] (port number or
	// name). Empty = discover it.
	Relay string `json:"relay,omitempty"`
	// TLS is "on" or "off" to override what the relay's config says.
	TLS string `json:"tls,omitempty"`
	// ServerName is the name to verify the relay's TLS certificate against
	// (default ui.hubble-relay.cilium.io, which Cilium's relay certificates
	// cover).
	ServerName string `json:"tlsServerName,omitempty"`
	// ReverseDNS looks up PTR records for public world addresses on the
	// map (default on). Cluster objects name addresses regardless.
	ReverseDNS *bool `json:"reverseDNS,omitempty"`
}

// RDNS is whether to look up reverse DNS (default true).
func (s Settings) RDNS() bool { return s.ReverseDNS == nil || *s.ReverseDNS }

// Validate checks settings before they are saved.
func (s Settings) Validate() error {
	if s.Relay != "" {
		if _, _, _, err := splitRelay(s.Relay); err != nil {
			return err
		}
	}
	switch s.TLS {
	case "", "on", "off":
	default:
		return fmt.Errorf("tls must be on or off")
	}
	return nil
}

func splitRelay(s string) (ns, name, port string, err error) {
	ns, rest, ok := strings.Cut(s, "/")
	if !ok || ns == "" || rest == "" {
		return "", "", "", fmt.Errorf("relay must be namespace/name[:port], not %q", s)
	}
	name, port, _ = strings.Cut(rest, ":")
	return ns, name, port, nil
}

// Relay is where Hubble Relay was found.
type Relay struct {
	Namespace string `json:"namespace"`
	Service   string `json:"service"`
	// Port is the Service port (number or name).
	Port string `json:"port"`
	TLS  bool   `json:"tls"`
	// FromSettings is true when the user's settings named it.
	FromSettings bool `json:"fromSettings,omitempty"`
}

// Discovery is what was found on the cluster, before connecting.
type Discovery struct {
	// Cilium is true when a cilium-config ConfigMap was found.
	Cilium bool `json:"cilium"`
	// HubbleEnabled is cilium-config's enable-hubble (nil = unknown).
	HubbleEnabled *bool  `json:"hubbleEnabled,omitempty"`
	Relay         *Relay `json:"relay,omitempty"`
	// Errors are lookups that failed (e.g. forbidden), by what was looked up.
	Errors map[string]string `json:"errors,omitempty"`
}

// Namespaces Cilium is usually installed in, checked when a cluster-wide
// list is forbidden.
var ciliumNamespaces = []string{"kube-system", "cilium"}

// Discover finds Cilium and Hubble Relay. With s.Relay set it only reads
// that Service.
func Discover(ctx context.Context, cs kubernetes.Interface, s Settings) Discovery {
	d := Discovery{Errors: map[string]string{}}
	var svc *corev1.Service
	port := ""
	if s.Relay != "" {
		ns, name, p, _ := splitRelay(s.Relay)
		got, err := cs.CoreV1().Services(ns).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			d.Errors["relay"] = err.Error()
		} else {
			svc, port = got, p
		}
	} else {
		svc = findRelayService(ctx, cs, d.Errors)
	}

	// cilium-config: the relay's namespace first, then the usual ones.
	nss := ciliumNamespaces
	if svc != nil {
		nss = append([]string{svc.Namespace}, nss...)
	}
	for _, ns := range uniq(nss) {
		cm, err := cs.CoreV1().ConfigMaps(ns).Get(ctx, "cilium-config", metav1.GetOptions{})
		if err != nil {
			if !apierrors.IsNotFound(err) {
				d.Errors["cilium-config"] = err.Error()
			}
			continue
		}
		d.Cilium = true
		if v, ok := cm.Data["enable-hubble"]; ok {
			on := v == "true"
			d.HubbleEnabled = &on
		}
		break
	}
	if svc == nil {
		if len(d.Errors) == 0 {
			d.Errors = nil
		}
		return d
	}

	r := &Relay{Namespace: svc.Namespace, Service: svc.Name, Port: port, FromSettings: s.Relay != ""}
	if r.Port == "" {
		r.Port = servicePort(svc)
	}
	r.TLS = relayTLS(ctx, cs, svc)
	switch s.TLS {
	case "on":
		r.TLS = true
	case "off":
		r.TLS = false
	}
	d.Relay = r
	if len(d.Errors) == 0 {
		d.Errors = nil
	}
	return d
}

// findRelayService looks for the relay by its chart labels across the
// cluster, then by name in the usual namespaces.
func findRelayService(ctx context.Context, cs kubernetes.Interface, errs map[string]string) *corev1.Service {
	for _, sel := range []string{"k8s-app=hubble-relay", "app.kubernetes.io/name=hubble-relay"} {
		l, err := cs.CoreV1().Services("").List(ctx, metav1.ListOptions{LabelSelector: sel})
		if err != nil {
			errs["services"] = err.Error()
			break
		}
		if len(l.Items) > 0 {
			return &l.Items[0]
		}
	}
	for _, ns := range ciliumNamespaces {
		svc, err := cs.CoreV1().Services(ns).Get(ctx, "hubble-relay", metav1.GetOptions{})
		if err == nil {
			delete(errs, "services")
			return svc
		}
		if !apierrors.IsNotFound(err) {
			errs["relay"] = err.Error()
		}
	}
	return nil
}

// servicePort is the port named grpc, else the first.
func servicePort(svc *corev1.Service) string {
	for _, p := range svc.Spec.Ports {
		if p.Name == "grpc" {
			return strconv.Itoa(int(p.Port))
		}
	}
	if len(svc.Spec.Ports) > 0 {
		return strconv.Itoa(int(svc.Spec.Ports[0].Port))
	}
	return "80"
}

// relayTLS reads the relay's own config (hubble-relay-config): its server
// TLS is on unless disable-server-tls is true. Without the ConfigMap, a
// Service on 443 is taken as TLS.
func relayTLS(ctx context.Context, cs kubernetes.Interface, svc *corev1.Service) bool {
	cm, err := cs.CoreV1().ConfigMaps(svc.Namespace).Get(ctx, "hubble-relay-config", metav1.GetOptions{})
	if err == nil {
		cfg := cm.Data["config.yaml"]
		if v, ok := yamlValue(cfg, "disable-server-tls"); ok {
			return v != "true"
		}
		_, hasCert := yamlValue(cfg, "tls-relay-server-cert-file")
		return hasCert
	}
	return servicePort(svc) == "443"
}

// yamlValue reads a top-level "key: value" line of a flat YAML document
// (the relay's config is one).
func yamlValue(doc, key string) (string, bool) {
	for _, line := range strings.Split(doc, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if ok && strings.TrimSpace(k) == key {
			return strings.Trim(strings.TrimSpace(v), `"'`), true
		}
	}
	return "", false
}

func uniq(s []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, x := range s {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	return out
}
