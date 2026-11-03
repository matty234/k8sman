package server

import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"syscall"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// Error classes reported to the UI in the `reason` of error responses and
// watch ERROR frames, so it can explain *why* a list failed instead of
// showing an empty table. Kubernetes API errors keep their own StatusReason
// (Forbidden, NotFound, Unauthorized, …); these cover the rest.
const (
	ReasonUnreachable  = "Unreachable"
	ReasonUnauthorized = "Unauthorized"
	ReasonForbidden    = "Forbidden"
	ReasonNotFound     = "NotFound"
	ReasonTimeout      = "Timeout"
)

// errNotServed marks a resource type discovery no longer lists (e.g. its
// CRD was deleted).
var errNotServed = errors.New("resource type not served")

// errAnonymous marks a discovery request the API server refused with 403.
// Discovery is open to every authenticated user, so this means the
// credentials weren't accepted and the request ran as system:anonymous.
var errAnonymous = errors.New("the cluster did not accept your credentials (API discovery was refused, so requests are treated as anonymous)")

// discoveryErr rewrites a forbidden discovery error as [errAnonymous].
func discoveryErr(err error) error {
	if err != nil && apierrors.IsForbidden(err) && !errors.Is(err, errAnonymous) {
		return fmt.Errorf("%w: %v", errAnonymous, err)
	}
	return err
}

// classifyError maps an error from client-go to a reason and HTTP status.
// It returns ("", 0) when the error isn't one of the classified kinds.
func classifyError(err error) (reason string, code int) {
	if err == nil {
		return "", 0
	}
	switch {
	case errors.Is(err, errAnonymous):
		return ReasonUnauthorized, http.StatusUnauthorized
	case errors.Is(err, errNotServed):
		return ReasonNotFound, http.StatusNotFound
	case apierrors.IsUnauthorized(err):
		return ReasonUnauthorized, http.StatusUnauthorized
	case apierrors.IsForbidden(err):
		return ReasonForbidden, http.StatusForbidden
	case apierrors.IsNotFound(err):
		return ReasonNotFound, http.StatusNotFound
	case apierrors.IsTimeout(err) || apierrors.IsServerTimeout(err):
		return ReasonTimeout, http.StatusGatewayTimeout
	}
	var se apierrors.APIStatus
	if errors.As(err, &se) {
		return "", 0 // some other API error: keep its own reason
	}
	msg := err.Error()
	// Exec credential plugins (aws, gcloud, kubelogin, …) and expired tokens
	// fail before any request is sent.
	if strings.Contains(msg, "getting credentials") || strings.Contains(msg, "exec plugin") ||
		strings.Contains(msg, "token has expired") || strings.Contains(msg, "refresh token") {
		return ReasonUnauthorized, http.StatusUnauthorized
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, syscall.ETIMEDOUT) {
		return ReasonTimeout, http.StatusGatewayTimeout
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return ReasonTimeout, http.StatusGatewayTimeout
	}
	var dnsErr *net.DNSError
	var opErr *net.OpError
	var unknownCA x509.UnknownAuthorityError
	var hostErr x509.HostnameError
	var certErr x509.CertificateInvalidError
	if errors.As(err, &dnsErr) || errors.As(err, &opErr) || errors.Is(err, syscall.ECONNREFUSED) ||
		errors.Is(err, syscall.EHOSTUNREACH) || errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.ECONNRESET) ||
		errors.As(err, &unknownCA) || errors.As(err, &hostErr) || errors.As(err, &certErr) {
		return ReasonUnreachable, http.StatusBadGateway
	}
	// Fall back on message text: discovery wraps errors as strings.
	low := strings.ToLower(msg)
	switch {
	case strings.Contains(low, "timeout") || strings.Contains(low, "deadline exceeded") || strings.Contains(low, "timed out"):
		return ReasonTimeout, http.StatusGatewayTimeout
	case strings.Contains(low, "connection refused") || strings.Contains(low, "no such host") ||
		strings.Contains(low, "network is unreachable") || strings.Contains(low, "no route to host") ||
		strings.Contains(low, "connection reset") || strings.Contains(low, "x509:") || strings.Contains(low, "tls:") ||
		strings.HasSuffix(low, ": eof"):
		return ReasonUnreachable, http.StatusBadGateway
	case strings.Contains(low, "unauthorized") || strings.Contains(low, "must be logged in"):
		return ReasonUnauthorized, http.StatusUnauthorized
	case strings.Contains(low, "forbidden"):
		return ReasonForbidden, http.StatusForbidden
	}
	return "", 0
}
