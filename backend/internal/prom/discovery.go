package prom

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

// Operator resources.
var (
	PrometheusGVR      = schema.GroupVersionResource{Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheuses"}
	AlertmanagerGVR    = schema.GroupVersionResource{Group: "monitoring.coreos.com", Version: "v1", Resource: "alertmanagers"}
	PrometheusRuleGVR  = schema.GroupVersionResource{Group: "monitoring.coreos.com", Version: "v1", Resource: "prometheusrules"}
	ServiceMonitorGVR  = schema.GroupVersionResource{Group: "monitoring.coreos.com", Version: "v1", Resource: "servicemonitors"}
	PodMonitorGVR      = schema.GroupVersionResource{Group: "monitoring.coreos.com", Version: "v1", Resource: "podmonitors"}
	discoveryCacheTTL  = 30 * time.Second
	failedDiscoveryTTL = 10 * time.Second
)

// wellKnown are Service names checked when the operator CRDs are absent
// (plain prometheus / alertmanager charts, kube-prometheus manifests).
var wellKnown = map[string][]string{
	KindPrometheus:   {"prometheus-operated", "prometheus-k8s", "prometheus-server", "prometheus"},
	KindAlertmanager: {"alertmanager-operated", "alertmanager-main", "prometheus-alertmanager", "alertmanager"},
}

var defaultPorts = map[string]int32{KindPrometheus: 9090, KindAlertmanager: 9093}

// Status is the GET /api/prom/status payload.
type Status struct {
	Prometheus   []*Instance `json:"prometheus"`
	Alertmanager []*Instance `json:"alertmanager"`
	// OperatorCRDs is true when the monitoring.coreos.com CRDs are served.
	OperatorCRDs bool      `json:"operatorCRDs"`
	CheckedAt    time.Time `json:"checkedAt"`
	// Errors lists discovery failures, e.g. RBAC forbidding a list.
	Errors map[string]string `json:"errors,omitempty"`
}

// Default returns the default instance of a kind, or the one with the given
// ID ("<namespace>/<name>"). Nil when none matches.
func (s *Status) Default(kind, id string) *Instance {
	list := s.Prometheus
	if kind == KindAlertmanager {
		list = s.Alertmanager
	}
	for _, in := range list {
		if id != "" && (in.ID == id || in.Name == id) {
			return in
		}
	}
	if id != "" {
		return nil
	}
	for _, in := range list {
		if in.Default {
			return in
		}
	}
	return nil
}

// env is everything discovery and requests need from the active context.
type env struct {
	key   string // cache key: the kube context
	dyn   dynamic.Interface
	typed kubernetes.Interface
	req   requester
	// settings are the user's manual instances (see Settings).
	settings Settings
}

// discoverer caches discovery per kube context.
type discoverer struct {
	mu    sync.Mutex
	cache map[string]*cacheEntry
	now   func() time.Time
}

type cacheEntry struct {
	at     time.Time
	ttl    time.Duration
	status *Status
	wait   chan struct{}
}

func newDiscoverer() *discoverer {
	return &discoverer{cache: map[string]*cacheEntry{}, now: time.Now}
}

// get returns cached discovery for e, running it when stale (or refresh).
// Concurrent callers share one discovery run.
func (d *discoverer) get(ctx context.Context, e env, refresh bool) *Status {
	d.mu.Lock()
	ce := d.cache[e.key]
	if ce != nil && ce.wait != nil {
		w := ce.wait
		d.mu.Unlock()
		select {
		case <-w:
		case <-ctx.Done():
			return &Status{Errors: map[string]string{"discovery": ctx.Err().Error()}}
		}
		d.mu.Lock()
		ce = d.cache[e.key]
	}
	if ce != nil && ce.status != nil && !refresh && d.now().Sub(ce.at) < ce.ttl {
		s := ce.status
		d.mu.Unlock()
		return s
	}
	wait := make(chan struct{})
	d.cache[e.key] = &cacheEntry{wait: wait}
	d.mu.Unlock()

	// Detach from the request so a cancelled caller doesn't poison the cache.
	dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 12*time.Second)
	s := discover(dctx, e)
	cancel()

	ttl := discoveryCacheTTL
	if len(s.Prometheus)+len(s.Alertmanager) == 0 || len(s.Errors) > 0 {
		ttl = failedDiscoveryTTL
	}
	d.mu.Lock()
	d.cache[e.key] = &cacheEntry{at: d.now(), ttl: ttl, status: s}
	d.mu.Unlock()
	close(wait)
	return s
}

// discover finds instances via the operator CRDs, falling back to
// well-known Service names, then probes each one for reachability.
func discover(ctx context.Context, e env) *Status {
	s := &Status{CheckedAt: time.Now().UTC(), Prometheus: []*Instance{}, Alertmanager: []*Instance{}}
	errs := map[string]string{}

	services, err := e.typed.CoreV1().Services("").List(ctx, metav1.ListOptions{ResourceVersion: "0"})
	if err != nil {
		errs["services"] = err.Error()
		services = &corev1.ServiceList{}
	}

	for _, kind := range []string{KindPrometheus, KindAlertmanager} {
		gvr := PrometheusGVR
		if kind == KindAlertmanager {
			gvr = AlertmanagerGVR
		}
		list, err := e.dyn.Resource(gvr).List(ctx, metav1.ListOptions{})
		var found []*Instance
		switch {
		case err == nil:
			s.OperatorCRDs = true
			for i := range list.Items {
				if in := fromCR(kind, &list.Items[i], services.Items); in != nil {
					found = append(found, in)
				}
			}
		case isNotFound(err):
			// CRD not installed: fall through to well-known services.
		default:
			errs[gvr.Resource] = err.Error()
		}
		if len(found) == 0 {
			found = fromServices(kind, services.Items)
		}
		sortInstances(found)
		if ep := e.settings.endpoint(kind); !ep.empty() {
			// The manual instance leads and is the default.
			manual := ep.instance(kind)
			found = append([]*Instance{manual}, slices.DeleteFunc(found, func(in *Instance) bool { return in.ID == manual.ID })...)
		}
		if kind == KindPrometheus {
			s.Prometheus = found
		} else {
			s.Alertmanager = found
		}
	}

	var wg sync.WaitGroup
	for _, in := range append(append([]*Instance{}, s.Prometheus...), s.Alertmanager...) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			probe(ctx, e.req, in)
		}()
	}
	wg.Wait()
	pickDefault(s.Prometheus)
	pickDefault(s.Alertmanager)
	if len(errs) > 0 {
		s.Errors = errs
	}
	return s
}

func isNotFound(err error) bool {
	return apierrors.IsNotFound(err) || (err != nil && strings.Contains(err.Error(), "could not find the requested resource"))
}

// podLabels synthesizes the labels the operator puts on an instance's pods,
// so we can tell which Services select them without listing pods.
func podLabels(kind, name string) map[string]string {
	l := map[string]string{
		"app.kubernetes.io/name":       kind,
		"app.kubernetes.io/instance":   name,
		"app.kubernetes.io/managed-by": "prometheus-operator",
		"operator.prometheus.io/name":  name,
		kind:                           name, // prometheus=<name> / alertmanager=<name>
	}
	return l
}

// instanceSpecific are selector keys that single out one instance (as opposed
// to the governing prometheus-operated Service, which selects all of them).
var instanceSpecific = []string{"operator.prometheus.io/name", "app.kubernetes.io/instance", KindPrometheus, KindAlertmanager}

func fromCR(kind string, u *unstructured.Unstructured, services []corev1.Service) *Instance {
	ns, name := u.GetNamespace(), u.GetName()
	labels := podLabels(kind, name)
	var best *corev1.Service
	bestScore := 0
	for i := range services {
		svc := &services[i]
		if svc.Namespace != ns || len(svc.Spec.Selector) == 0 || webPort(kind, svc) == "" {
			continue
		}
		match := true
		for k, v := range svc.Spec.Selector {
			if labels[k] != v {
				match = false
				break
			}
		}
		if !match {
			continue
		}
		score := 1
		for _, k := range instanceSpecific {
			if _, ok := svc.Spec.Selector[k]; ok {
				score = 3
			}
		}
		if svc.Name == kind+"-operated" && score == 1 {
			score = 2 // governing service: fine when this is the only instance
		}
		if score > bestScore || (score == bestScore && best != nil && svc.Name < best.Name) {
			best, bestScore = svc, score
		}
	}
	in := &Instance{
		ID:        ns + "/" + name,
		Kind:      kind,
		Namespace: ns,
		Name:      name,
		Source:    "crd",
		Scheme:    "http",
	}
	if best != nil {
		in.Service, in.Port = best.Name, webPort(kind, best)
	} else {
		// The governing service may be filtered by RBAC; assume its shape.
		in.Service, in.Port = kind+"-operated", "web"
	}
	spec, _, _ := unstructured.NestedMap(u.Object, "spec")
	if v, ok := spec["version"].(string); ok {
		in.Version = v
	}
	in.ExternalURL, _ = spec["externalUrl"].(string)
	in.PathPrefix = routePrefix(spec)
	if tls, ok, _ := unstructured.NestedMap(spec, "web", "tlsConfig"); ok && len(tls) > 0 {
		in.Scheme = "https"
	}
	if r, ok, _ := unstructured.NestedInt64(u.Object, "spec", "replicas"); ok {
		in.Replicas = &r
	} else {
		one := int64(1)
		in.Replicas = &one
	}
	if a, ok, _ := unstructured.NestedInt64(u.Object, "status", "availableReplicas"); ok {
		in.Available = &a
	}
	return in
}

// routePrefix mirrors the operator: spec.routePrefix if set, else "/" (the
// operator always passes --web.route-prefix, so externalUrl's path doesn't
// move the routes).
func routePrefix(spec map[string]any) string {
	if p, ok := spec["routePrefix"].(string); ok && p != "" && p != "/" {
		return "/" + strings.Trim(p, "/")
	}
	return ""
}

// webPort picks the HTTP port of a Prometheus/Alertmanager Service.
func webPort(kind string, svc *corev1.Service) string {
	for _, p := range svc.Spec.Ports {
		if p.Protocol != "" && p.Protocol != corev1.ProtocolTCP {
			continue
		}
		switch p.Name {
		case "web", "http-web", "http":
			return p.Name
		}
	}
	for _, p := range svc.Spec.Ports {
		if p.Port == defaultPorts[kind] || (p.TargetPort.IntVal == defaultPorts[kind]) {
			if p.Name != "" {
				return p.Name
			}
			return strconv.Itoa(int(p.Port))
		}
	}
	if len(svc.Spec.Ports) == 1 && (svc.Spec.Ports[0].Port == 80 || svc.Spec.Ports[0].Port == 443) {
		return strconv.Itoa(int(svc.Spec.Ports[0].Port))
	}
	return ""
}

func fromServices(kind string, services []corev1.Service) []*Instance {
	var out []*Instance
	for _, name := range wellKnown[kind] {
		for i := range services {
			svc := &services[i]
			if svc.Name != name {
				continue
			}
			port := webPort(kind, svc)
			if port == "" {
				continue
			}
			scheme := "http"
			if port == "443" || port == "https" {
				scheme = "https"
			}
			out = append(out, &Instance{
				ID: svc.Namespace + "/" + svc.Name, Kind: kind, Namespace: svc.Namespace, Name: svc.Name,
				Source: "service", Service: svc.Name, Port: port, Scheme: scheme,
			})
		}
		if len(out) > 0 {
			// Several well-known names often front the same instance
			// (prometheus-operated + prometheus-k8s): keep the first that exists.
			break
		}
	}
	return out
}

func sortInstances(l []*Instance) {
	sort.SliceStable(l, func(i, j int) bool { return l[i].ID < l[j].ID })
}

// pickDefault marks the first reachable instance, preferring the
// "monitoring" namespace, as the default.
func pickDefault(l []*Instance) {
	if len(l) == 0 {
		return
	}
	rank := func(in *Instance) int {
		r := 0
		if !in.Reachable {
			r += 2
		}
		if in.Namespace != "monitoring" {
			r++
		}
		return r
	}
	if l[0].Source == "settings" {
		l[0].Default = true
		return
	}
	best := l[0]
	for _, in := range l[1:] {
		if rank(in) < rank(best) {
			best = in
		}
	}
	best.Default = true
}

// probe checks reachability and reads the running version.
func probe(ctx context.Context, r requester, in *Instance) {
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	var err error
	switch in.Kind {
	case KindPrometheus:
		var data json.RawMessage
		data, _, err = promGet(ctx, r, in, "/api/v1/status/buildinfo", url.Values{})
		if err != nil && in.Source == "settings" {
			// Mimir and friends may not serve buildinfo: any answer to a
			// trivial query shows the address works.
			if _, _, qerr := promGet(ctx, r, in, "/api/v1/query", url.Values{"query": {"vector(1)"}}); qerr == nil {
				err, data = nil, nil
			}
		}
		if err == nil {
			var bi struct {
				Version string `json:"version"`
			}
			if json.Unmarshal(data, &bi) == nil && bi.Version != "" {
				in.Version = bi.Version
			}
		}
	case KindAlertmanager:
		var st struct {
			VersionInfo struct {
				Version string `json:"version"`
			} `json:"versionInfo"`
		}
		err = getJSON(ctx, r, in, "/api/v2/status", nil, &st)
		if err == nil && st.VersionInfo.Version != "" {
			in.Version = st.VersionInfo.Version
		}
	}
	in.Reachable = err == nil
	if err != nil {
		in.Error = fmt.Sprint(err)
	}
}
