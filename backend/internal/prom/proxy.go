// Package prom gives k8sman first-class access to the Prometheus stack
// (Prometheus Operator, Prometheus, Alertmanager) running in the cluster.
//
// Instances are discovered through the operator's CRDs (or well-known
// Service names without them) and reached through the Kubernetes API
// server's service proxy, so no port-forward is needed:
//
//	/api/v1/namespaces/<ns>/services/<scheme>:<svc>:<port>/proxy/<routePrefix>/<path>
//
// See docs/PROMETHEUS.md for the endpoints served under /api/prom.
package prom

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"strings"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

// Request timeouts. Discovery probes are short so a missing or wedged
// instance doesn't stall the UI; queries get longer.
const (
	probeTimeout = 4 * time.Second
	readTimeout  = 15 * time.Second
	queryTimeout = 30 * time.Second
)

// Kinds of instance.
const (
	KindPrometheus   = "prometheus"
	KindAlertmanager = "alertmanager"
)

// Instance is one discovered Prometheus or Alertmanager.
type Instance struct {
	// ID is "<namespace>/<name>", used as the ?instance= value.
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Namespace string `json:"namespace"`
	// Name is the custom resource name (or the Service name when found
	// without the operator).
	Name string `json:"name"`
	// Source is "crd" (operator custom resource) or "service" (well-known
	// Service name fallback).
	Source  string `json:"source"`
	Service string `json:"service"`
	Port    string `json:"port"`
	Scheme  string `json:"scheme"`
	// PathPrefix is the instance's route prefix ("" or "/" = root).
	PathPrefix string `json:"pathPrefix,omitempty"`
	// Version is reported by the instance itself when reachable, else the
	// CR's spec.version.
	Version   string `json:"version,omitempty"`
	Replicas  *int64 `json:"replicas,omitempty"`
	Available *int64 `json:"availableReplicas,omitempty"`
	Reachable bool   `json:"reachable"`
	Error     string `json:"error,omitempty"`
	Default   bool   `json:"default"`
	// ExternalURL is spec.externalUrl, for "open in browser" links.
	ExternalURL string `json:"externalUrl,omitempty"`
}

// ProxyPath is the API server path that reaches p on the instance.
func (in *Instance) ProxyPath(p string) string {
	scheme := in.Scheme
	if scheme == "" {
		scheme = "http"
	}
	full := path.Join("/", in.PathPrefix, p)
	if strings.HasSuffix(p, "/") && !strings.HasSuffix(full, "/") {
		full += "/"
	}
	return fmt.Sprintf("/api/v1/namespaces/%s/services/%s:%s:%s/proxy%s", in.Namespace, scheme, in.Service, in.Port, full)
}

// UpstreamError is a non-2xx answer from Prometheus/Alertmanager (or from
// the API server proxy in front of it).
type UpstreamError struct {
	Status  int
	Message string
	// NoInstance is set when discovery found no matching instance.
	NoInstance bool
}

func (e *UpstreamError) Error() string {
	if e.Status == 0 || e.NoInstance {
		return e.Message
	}
	return fmt.Sprintf("%s (HTTP %d)", e.Message, e.Status)
}

// requester performs one proxied request. It is an interface so tests can
// point it at an httptest server.
type requester interface {
	do(ctx context.Context, method string, in *Instance, p string, q url.Values, body []byte) ([]byte, error)
}

// restRequester proxies through the API server with the active REST client.
type restRequester struct{ rc rest.Interface }

func (r restRequester) do(ctx context.Context, method string, in *Instance, p string, q url.Values, body []byte) ([]byte, error) {
	if in == nil {
		return nil, errNoInstance
	}
	req := r.rc.Verb(method).AbsPath(in.ProxyPath(p))
	for k, vs := range q {
		for _, v := range vs {
			req = req.Param(k, v)
		}
	}
	if body != nil {
		req = req.SetHeader("Content-Type", "application/json").Body(body)
	}
	var code int
	res := req.Do(ctx).StatusCode(&code)
	raw, err := res.Raw()
	if err == nil {
		return raw, nil
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil, &UpstreamError{Status: 504, Message: fmt.Sprintf("%s %s/%s timed out", in.Kind, in.Namespace, in.Name)}
	}
	return nil, upstreamErr(code, raw, err)
}

var errNoInstance = &UpstreamError{Status: 404, Message: "no instance found", NoInstance: true}

// upstreamErr extracts the most useful message from a failed response:
// Prometheus' {"error": ...}, Alertmanager's plain text or {"message": ...},
// or the API server's Status.
func upstreamErr(code int, raw []byte, err error) error {
	var se apierrors.APIStatus
	if code == 0 && errors.As(err, &se) {
		code = int(se.Status().Code)
	}
	msg := ""
	var j struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if len(raw) > 0 && json.Unmarshal(raw, &j) == nil {
		msg = firstNonEmpty(j.Error, j.Message)
	}
	if msg == "" && len(raw) > 0 && len(raw) < 512 && !strings.HasPrefix(strings.TrimSpace(string(raw)), "<") {
		msg = strings.TrimSpace(string(raw))
	}
	// client-go folds non-Status error bodies into a StatusError cause.
	if msg == "" && errors.As(err, &se) {
		if d := se.Status().Details; d != nil {
			for _, c := range d.Causes {
				if c.Type == metav1.CauseTypeUnexpectedServerResponse && c.Message != "" {
					return upstreamErr(code, []byte(c.Message), nil)
				}
			}
		}
	}
	if msg == "" && err != nil {
		msg = err.Error()
	}
	if msg == "" {
		msg = "request failed"
	}
	return &UpstreamError{Status: code, Message: msg}
}

func firstNonEmpty(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}

// getJSON GETs p from in and decodes the body into out.
func getJSON(ctx context.Context, r requester, in *Instance, p string, q url.Values, out any) error {
	raw, err := r.do(ctx, "GET", in, p, q, nil)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return &UpstreamError{Status: 502, Message: fmt.Sprintf("decode %s response: %v", in.Kind, err)}
	}
	return nil
}

// promEnvelope is Prometheus' HTTP API response wrapper.
type promEnvelope struct {
	Status    string          `json:"status"`
	Data      json.RawMessage `json:"data"`
	ErrorType string          `json:"errorType,omitempty"`
	Error     string          `json:"error,omitempty"`
	Warnings  []string        `json:"warnings,omitempty"`
}

// promGet calls a Prometheus /api/v1 endpoint and returns its data.
func promGet(ctx context.Context, r requester, in *Instance, p string, q url.Values) (json.RawMessage, []string, error) {
	var env promEnvelope
	if err := getJSON(ctx, r, in, p, q, &env); err != nil {
		return nil, nil, err
	}
	if env.Status != "success" {
		return nil, env.Warnings, &UpstreamError{Status: 422, Message: firstNonEmpty(env.Error, "prometheus returned status "+env.Status)}
	}
	return env.Data, env.Warnings, nil
}
