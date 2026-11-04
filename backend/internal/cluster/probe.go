package cluster

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"
)

// Connecting to a context runs two probes before discovery, so the UI can say
// which step is slow and an unreachable server fails in seconds instead of
// leaving the user on a spinner:
//
//  1. ProbeReach: an unauthenticated GET /version with a short deadline. It
//     never runs an exec credential plugin, so a dead server fails fast even
//     for contexts whose login would open a browser.
//  2. ProbeAuth: the same request with the context's credentials. For exec
//     plugins (kubelogin, aws, gke-gcloud-auth-plugin, …) this is where an SSO
//     login happens, so it gets a long budget.

// ReachTimeout bounds ProbeReach: TCP connect, TLS handshake and the
// response to GET /version. Variables so tests can shorten them.
var ReachTimeout = 10 * time.Second

// AuthTimeout bounds ProbeAuth for static credentials (token, client cert).
var AuthTimeout = 30 * time.Second

// ExecAuthTimeout bounds ProbeAuth when credentials come from an exec plugin
// that may be waiting for the user to finish logging in in a browser.
var ExecAuthTimeout = 5 * time.Minute

// ErrUnreachable marks a failed ProbeReach: nothing answered at the server
// address (refused, DNS, no route, connect / TLS / response timeout).
var ErrUnreachable = errors.New("can't reach the API server")

// UsesExec reports whether the context's credentials come from an exec
// plugin or a legacy auth provider (both may block on an interactive login).
func (c *Clients) UsesExec() bool {
	return c.RESTConfig.ExecProvider != nil || c.RESTConfig.AuthProvider != nil
}

// ProbeReach checks the API server answers at all, without credentials.
// Any HTTP response (even 401/403) counts as reachable.
func (c *Clients) ProbeReach(ctx context.Context) error {
	cfg := rest.AnonymousClientConfig(c.RESTConfig)
	cfg.Timeout = ReachTimeout
	ctx, cancel := context.WithTimeout(ctx, ReachTimeout)
	defer cancel()
	err := getVersion(ctx, cfg, nil)
	if err == nil || isHTTPAnswer(err) {
		return nil
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		err = fmt.Errorf("no answer within %s (%w)", ReachTimeout, err)
	}
	return fmt.Errorf("%w at %s: %w", ErrUnreachable, c.RESTConfig.Host, err)
}

// ProbeAuth sends GET /version with the context's credentials, running its
// exec plugin if it has one. Only rejected credentials (401), plugin failures
// and network errors fail it: other API errors are left to discovery.
func (c *Clients) ProbeAuth(ctx context.Context) error {
	budget := AuthTimeout
	if c.UsesExec() {
		budget = ExecAuthTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	err := getVersion(ctx, c.RESTConfig, c.Typed.Discovery().RESTClient())
	if err == nil || (isHTTPAnswer(err) && !apierrors.IsUnauthorized(err)) {
		return nil
	}
	if ctx.Err() != nil && c.UsesExec() {
		return fmt.Errorf("timed out after %s waiting for the credential plugin to sign in: %w", budget, err)
	}
	return err
}

// getVersion GETs /version through rc, or a client built from cfg (its
// transport comes from client-go's TLS cache, so repeated probes share one
// connection pool).
func getVersion(ctx context.Context, cfg *rest.Config, rc rest.Interface) error {
	if rc == nil {
		dc, err := discovery.NewDiscoveryClientForConfig(cfg)
		if err != nil {
			return err
		}
		rc = dc.RESTClient()
	}
	_, err := rc.Get().AbsPath("/version").Do(ctx).Raw()
	return err
}

// isHTTPAnswer reports whether err means the server sent an HTTP response
// (or rejected our TLS handshake), i.e. the server itself is reachable.
func isHTTPAnswer(err error) bool {
	var st apierrors.APIStatus
	if errors.As(err, &st) {
		return true
	}
	// The server asked for a client certificate the anonymous probe lacks.
	return strings.Contains(err.Error(), "remote error: tls:")
}
