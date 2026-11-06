// Package httpx holds the JSON response helpers shared by the HTTP
// handlers. Each handler package keeps its own error body and status
// mapping; this is only the common mechanics.
package httpx

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// Router is where handlers are mounted: an *http.ServeMux, or a wrapper
// around one (the server gates each integration module's routes).
type Router interface {
	HandleFunc(pattern string, handler func(http.ResponseWriter, *http.Request))
}

// WriteJSON writes v as a JSON response with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// ErrBadRequest marks errors that should be answered with 400.
var ErrBadRequest = errors.New("bad request")

// BadRequest returns an ErrBadRequest-wrapped error: "bad request: <msg>".
func BadRequest(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrBadRequest, fmt.Sprintf(format, a...))
}

// KubeStatus reports whether err carries a Kubernetes API Status, and if so
// its HTTP status (fallback when the Status code is below 400) and reason.
func KubeStatus(err error, fallback int) (status int, reason string, ok bool) {
	var se apierrors.APIStatus
	if !errors.As(err, &se) {
		return fallback, "", false
	}
	status = fallback
	if c := int(se.Status().Code); c >= 400 {
		status = c
	}
	return status, string(se.Status().Reason), true
}
