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

// ErrorBody is the JSON error shape every handler package answers with.
// Optional fields are omitted when empty; each package fills only the
// ones it uses.
type ErrorBody struct {
	Error string `json:"error"`
	Code  int    `json:"code"`
	// Reason is a machine-readable cause (a Kubernetes StatusReason such as
	// Conflict or Invalid, or a package-specific one such as NotFound).
	Reason string              `json:"reason,omitempty"`
	Causes []map[string]string `json:"causes,omitempty"`
	// LocalPortInUse (creating a port-forward): the forward holding the port
	// (empty when another process has it) and a free port to use instead.
	UsedBy        string `json:"usedBy,omitempty"`
	SuggestedPort int    `json:"suggestedPort,omitempty"`
	// State and Group are set when a metrics API is unusable.
	State string `json:"state,omitempty"`
	Group string `json:"group,omitempty"`
}

// WriteError writes an ErrorBody with the given status, reason (may be
// empty) and message.
func WriteError(w http.ResponseWriter, status int, reason, msg string) {
	WriteJSON(w, status, ErrorBody{Error: msg, Code: status, Reason: reason})
}

// DecodeJSON decodes the request body into a T, limited to maxBytes (0 for
// no limit). On failure it writes the 400 itself and returns false.
func DecodeJSON[T any](w http.ResponseWriter, r *http.Request, maxBytes int64) (T, bool) {
	var v T
	body := r.Body
	if maxBytes > 0 {
		body = http.MaxBytesReader(w, r.Body, maxBytes)
	}
	if err := json.NewDecoder(body).Decode(&v); err != nil {
		WriteError(w, http.StatusBadRequest, "", BadRequest("invalid body: %v", err).Error())
		return v, false
	}
	return v, true
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
