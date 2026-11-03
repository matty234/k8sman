// Package argoapi talks to the Argo CD API server (argocd-server) for what
// the Application CR doesn't carry, starting with per-resource diffs.
//
// argocd-server is reached through the Kubernetes API server's service
// proxy with the active kube credentials, like the Prometheus integration
// (internal/prom), so no port-forward is needed:
//
//	/api/v1/namespaces/<ns>/services/<scheme>:argocd-server:<port>/proxy/<rootpath>/api/v1/...
//
// The API server strips the Authorization header once it has authenticated
// a request, so the Argo token is sent as Argo's own `argocd.token` cookie,
// which argocd-server accepts too.
//
// See docs/ARGOCD.md and API.md (/api/argocd/*).
package argoapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	serverLabel       = "app.kubernetes.io/name=argocd-server"
	defaultArgoNs     = "argocd"
	paramsConfigMap   = "argocd-cmd-params-cm"
	initialAdminName  = "argocd-initial-admin-secret"
	tokenCookie       = "argocd.token"
	probeTimeout      = 5 * time.Second
	requestTimeout    = 30 * time.Second
	discoveryTTL      = 30 * time.Second
	failedDiscoveryTT = 10 * time.Second
)

// Server is a discovered argocd-server Service.
type Server struct {
	Namespace string `json:"namespace"`
	Service   string `json:"service"`
	Port      int32  `json:"port"`
	// Scheme is https unless argocd-cmd-params-cm sets server.insecure.
	Scheme string `json:"scheme"`
	// RootPath is server.rootpath ("" = served at /).
	RootPath string `json:"rootPath,omitempty"`
	Version  string `json:"version,omitempty"`
}

// ProxyPath is the API server path that reaches p on argocd-server.
func (s *Server) ProxyPath(p string) string {
	return fmt.Sprintf("/api/v1/namespaces/%s/services/%s:%s:%d/proxy%s%s", s.Namespace, s.Scheme, s.Service, s.Port, s.RootPath, p)
}

// Error is a failed Argo CD request, with a Reason the UI can act on.
type Error struct {
	Status  int
	Reason  string
	Message string
	// Kube marks errors from the Kubernetes API server itself (the service
	// proxy), not from Argo CD.
	Kube bool
}

func (e *Error) Error() string { return e.Message }

// Reasons.
const (
	ReasonNotFound     = "NotFound"     // no argocd-server Service
	ReasonUnreachable  = "Unreachable"  // the Service doesn't answer
	ReasonNoToken      = "NoToken"      // no token or session for this context
	ReasonUnauthorized = "Unauthorized" // Argo rejected the token (401)
	ReasonForbidden    = "Forbidden"    // Argo RBAC denied it (403)
	ReasonNoAdmin      = "NoInitialAdmin"
)

// requester performs one proxied request. Tests point it at httptest.
type requester interface {
	do(ctx context.Context, method string, s *Server, p string, q url.Values, body []byte, token string) ([]byte, error)
}

type restRequester struct{ rc rest.Interface }

func (r restRequester) do(ctx context.Context, method string, s *Server, p string, q url.Values, body []byte, token string) ([]byte, error) {
	req := r.rc.Verb(method).AbsPath(s.ProxyPath(p))
	for k, vs := range q {
		for _, v := range vs {
			req = req.Param(k, v)
		}
	}
	if token != "" {
		req = req.SetHeader("Cookie", tokenCookie+"="+token)
	}
	if body != nil {
		req = req.SetHeader("Content-Type", "application/json").Body(body)
	}
	var code int
	raw, err := req.Do(ctx).StatusCode(&code).Raw()
	if err == nil {
		return raw, nil
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil, &Error{Status: 504, Reason: ReasonUnreachable, Message: "argocd-server did not answer in time"}
	}
	return nil, upstreamErr(code, raw, err)
}

// upstreamErr tells an Argo CD error ({"error","code","message"}) from one
// of the API server's own (a v1 Status: proxy forbidden, no endpoints...).
func upstreamErr(code int, raw []byte, err error) error {
	var se apierrors.APIStatus
	if code == 0 && errors.As(err, &se) {
		code = int(se.Status().Code)
	}
	var kube metav1.Status
	if json.Unmarshal(raw, &kube) == nil && kube.Kind == "Status" {
		reason := "Kube" + string(kube.Reason)
		if code == 503 || code == 502 {
			reason = ReasonUnreachable
		}
		return &Error{Status: code, Reason: reason, Kube: true, Message: "Kubernetes API: " + firstNonEmpty(kube.Message, string(kube.Reason))}
	}
	var argo struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	msg := ""
	if len(raw) > 0 && json.Unmarshal(raw, &argo) == nil {
		msg = firstNonEmpty(argo.Message, argo.Error)
	}
	if msg == "" && len(raw) > 0 && len(raw) < 512 && !strings.HasPrefix(strings.TrimSpace(string(raw)), "<") {
		msg = strings.TrimSpace(string(raw))
	}
	if msg == "" && errors.As(err, &se) {
		if d := se.Status().Details; d != nil {
			for _, c := range d.Causes {
				if c.Type == metav1.CauseTypeUnexpectedServerResponse && c.Message != "" {
					return upstreamErr(code, []byte(c.Message), nil)
				}
			}
		}
		msg = se.Status().Message
	}
	if msg == "" && err != nil {
		msg = err.Error()
	}
	e := &Error{Status: code, Message: "Argo CD: " + firstNonEmpty(msg, "request failed")}
	switch code {
	case 401:
		e.Reason = ReasonUnauthorized
	case 403:
		e.Reason = ReasonForbidden
	case 502, 503, 0:
		e.Reason = ReasonUnreachable
		if e.Status == 0 {
			e.Status = 502
		}
	}
	return e
}

func firstNonEmpty(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}

// env is what one request needs from the active kube context.
type env struct {
	context string
	typed   kubernetes.Interface
	req     requester
}

// discovery is a cached argocd-server lookup.
type discovery struct {
	server       *Server
	reachable    bool
	initialAdmin bool
	err          string
	at           time.Time
	ttl          time.Duration
}

type discoverer struct {
	mu    sync.Mutex
	cache map[string]*discovery
	now   func() time.Time
}

func newDiscoverer() *discoverer { return &discoverer{cache: map[string]*discovery{}, now: time.Now} }

func (d *discoverer) get(ctx context.Context, e env, appNs string, refresh bool) *discovery {
	key := e.context + "\x00" + appNs
	d.mu.Lock()
	c := d.cache[key]
	d.mu.Unlock()
	if c != nil && !refresh && d.now().Sub(c.at) < c.ttl {
		return c
	}
	dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 12*time.Second)
	defer cancel()
	c = discover(dctx, e, appNs)
	c.at = d.now()
	c.ttl = discoveryTTL
	if c.server == nil || !c.reachable {
		c.ttl = failedDiscoveryTT
	}
	d.mu.Lock()
	d.cache[key] = c
	d.mu.Unlock()
	return c
}

func (d *discoverer) forget(contextName string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for k := range d.cache {
		if strings.HasPrefix(k, contextName+"\x00") {
			delete(d.cache, k)
		}
	}
}

// findService looks for the argocd-server Service in the app's namespace,
// then cluster-wide, then in "argocd" (when listing all namespaces is
// forbidden).
func findService(ctx context.Context, typed kubernetes.Interface, appNs string) (*corev1.Service, error) {
	list := func(ns string) ([]corev1.Service, error) {
		l, err := typed.CoreV1().Services(ns).List(ctx, metav1.ListOptions{LabelSelector: serverLabel})
		if err != nil {
			return nil, err
		}
		return l.Items, nil
	}
	var firstErr error
	try := func(ns string) *corev1.Service {
		items, err := list(ns)
		if err != nil {
			if firstErr == nil && !apierrors.IsForbidden(err) {
				firstErr = err
			}
			return nil
		}
		sort.Slice(items, func(i, j int) bool {
			ri, rj := items[i].Namespace == defaultArgoNs, items[j].Namespace == defaultArgoNs
			if ri != rj {
				return ri
			}
			return items[i].Namespace+"/"+items[i].Name < items[j].Namespace+"/"+items[j].Name
		})
		// Prefer the plain "argocd-server" over e.g. argocd-server-metrics.
		for i := range items {
			if items[i].Name == "argocd-server" {
				return &items[i]
			}
		}
		for i := range items {
			if !strings.Contains(items[i].Name, "metrics") {
				return &items[i]
			}
		}
		return nil
	}
	if appNs != "" {
		if s := try(appNs); s != nil {
			return s, nil
		}
	}
	if s := try(""); s != nil {
		return s, nil
	}
	if appNs != defaultArgoNs {
		if s := try(defaultArgoNs); s != nil {
			return s, nil
		}
	}
	return nil, firstErr
}

// pickPort chooses the port and scheme: https unless server.insecure.
func pickPort(svc *corev1.Service, insecure bool) (int32, string) {
	want, wantPort := "https", int32(443)
	if insecure {
		want, wantPort = "http", 80
	}
	for _, p := range svc.Spec.Ports {
		if p.Name == want {
			return p.Port, want
		}
	}
	for _, p := range svc.Spec.Ports {
		if p.Port == wantPort {
			return p.Port, want
		}
	}
	if len(svc.Spec.Ports) > 0 {
		return svc.Spec.Ports[0].Port, want
	}
	return wantPort, want
}

func discover(ctx context.Context, e env, appNs string) *discovery {
	svc, err := findService(ctx, e.typed, appNs)
	if svc == nil {
		msg := "argocd-server was not found (no Service labelled " + serverLabel + ")"
		if err != nil {
			msg += ": " + err.Error()
		}
		return &discovery{err: msg}
	}
	insecure, rootPath, paramsRead := false, "", false
	if cm, err := e.typed.CoreV1().ConfigMaps(svc.Namespace).Get(ctx, paramsConfigMap, metav1.GetOptions{}); err == nil {
		paramsRead = true
		insecure, _ = strconv.ParseBool(cm.Data["server.insecure"])
		if rp := strings.Trim(cm.Data["server.rootpath"], "/"); rp != "" {
			rootPath = "/" + rp
		}
	}
	port, scheme := pickPort(svc, insecure)
	s := &Server{Namespace: svc.Namespace, Service: svc.Name, Port: port, Scheme: scheme, RootPath: rootPath}
	d := &discovery{server: s}
	probe := func(s *Server) error {
		pctx, cancel := context.WithTimeout(ctx, probeTimeout)
		defer cancel()
		raw, err := e.req.do(pctx, "GET", s, "/api/version", nil, nil, "")
		if err != nil {
			return err
		}
		var v struct {
			Version string `json:"Version"`
		}
		if json.Unmarshal(raw, &v) != nil || v.Version == "" {
			return &Error{Status: 502, Reason: ReasonUnreachable, Message: "argocd-server answered /api/version unexpectedly"}
		}
		s.Version = v.Version
		return nil
	}
	err = probe(s)
	if err != nil && !paramsRead {
		// We couldn't read server.insecure: try the other scheme.
		alt := *s
		alt.Port, alt.Scheme = pickPort(svc, scheme == "https")
		if probe(&alt) == nil {
			s, err = &alt, nil
			d.server = s
		}
	}
	if err != nil {
		d.err = err.Error()
	} else {
		d.reachable = true
	}
	if sec, err := e.typed.CoreV1().Secrets(svc.Namespace).Get(ctx, initialAdminName, metav1.GetOptions{}); err == nil && len(sec.Data["password"]) > 0 {
		d.initialAdmin = true
	}
	return d
}
