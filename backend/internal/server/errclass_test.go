package server

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"syscall"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestClassifyError(t *testing.T) {
	pods := schema.GroupResource{Resource: "pods"}
	refused := &url.Error{Op: "Get", URL: "https://127.0.0.1:1/api", Err: &net.OpError{Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)}}
	cases := []struct {
		name   string
		err    error
		reason string
		code   int
	}{
		{"nil", nil, "", 0},
		{"unauthorized", apierrors.NewUnauthorized("token expired"), ReasonUnauthorized, 401},
		{"forbidden", apierrors.NewForbidden(pods, "", errors.New(`User "bob" cannot list`)), ReasonForbidden, 403},
		{"not found", apierrors.NewNotFound(pods, "x"), ReasonNotFound, 404},
		{"server timeout", apierrors.NewServerTimeout(pods, "list", 1), ReasonTimeout, 504},
		{"other API error keeps own reason", apierrors.NewConflict(pods, "x", errors.New("changed")), "", 0},
		{"connection refused", refused, ReasonUnreachable, 502},
		{"wrapped refused", fmt.Errorf("discovery: %w", refused), ReasonUnreachable, 502},
		{"dns", &url.Error{Op: "Get", URL: "https://nope.invalid", Err: &net.DNSError{Err: "no such host", Name: "nope.invalid", IsNotFound: true}}, ReasonUnreachable, 502},
		{"deadline", fmt.Errorf("list: %w", context.DeadlineExceeded), ReasonTimeout, 504},
		{"net timeout", &url.Error{Op: "Get", URL: "https://10.0.0.1", Err: timeoutErr{}}, ReasonTimeout, 504},
		{"unknown CA", &url.Error{Op: "Get", URL: "https://x", Err: x509.UnknownAuthorityError{}}, ReasonUnreachable, 502},
		{"exec plugin", errors.New(`Get "https://x/api": getting credentials: exec: executable aws failed with exit code 255`), ReasonUnauthorized, 401},
		{"string refused (discovery)", errors.New("unable to retrieve the complete list of server APIs: dial tcp 127.0.0.1:1: connect: connection refused"), ReasonUnreachable, 502},
		{"string unauthorized (discovery)", errors.New("unable to retrieve the complete list of server APIs: metrics.k8s.io/v1beta1: Unauthorized"), ReasonUnauthorized, 401},
		{"unclassified", errors.New("something else"), "", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, c := classifyError(tc.err)
			if r != tc.reason || c != tc.code {
				t.Fatalf("classifyError(%v) = %q, %d; want %q, %d", tc.err, r, c, tc.reason, tc.code)
			}
		})
	}
}

type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func TestErrorFrameKeepsLegacyFields(t *testing.T) {
	m := errorFrame(nil, apierrors.NewForbidden(schema.GroupResource{Resource: "secrets"}, "", errors.New("no")))
	if m.Type != "ERROR" || m.Error == "" || m.Reason != ReasonForbidden || m.Code != http.StatusForbidden {
		t.Fatalf("unexpected frame %+v", m)
	}
	// Unclassified API errors still carry their Kubernetes reason.
	m = errorFrame(nil, apierrors.NewConflict(schema.GroupResource{Resource: "pods"}, "x", errors.New("changed")))
	if m.Reason != "Conflict" || m.Code != 409 {
		t.Fatalf("unexpected frame %+v", m)
	}
}

func TestClassifyNotServed(t *testing.T) {
	err := fmt.Errorf("%w: %v", errNotServed, errors.New(`resource example.com/v1 "widgets" not found`))
	if r, c := classifyError(err); r != ReasonNotFound || c != 404 {
		t.Fatalf("got %q %d", r, c)
	}
}

func TestDiscoveryForbiddenMeansAnonymous(t *testing.T) {
	err := discoveryErr(apierrors.NewForbidden(schema.GroupResource{}, "", errors.New("unknown")))
	if r, c := classifyError(err); r != ReasonUnauthorized || c != 401 {
		t.Fatalf("got %q %d", r, c)
	}
	if discoveryErr(nil) != nil {
		t.Fatal("nil stays nil")
	}
	other := errors.New("x")
	if discoveryErr(other) != other {
		t.Fatal("non-forbidden errors pass through")
	}
}
