package server

import (
	"encoding/json"
	"net/http"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Read-only mode stops edits, deletes, scaling, Helm changes, exec and debug
// containers. It applies when the backend runs with --read-only, or per
// kube context: the user's choice (settings.ReadOnlyContexts), else
// automatically for contexts whose names look like production.

// Why the current context is read-only ("" = it isn't).
const (
	readOnlyFlag    = "flag"    // --read-only
	readOnlyChosen  = "context" // the user marked the context read-only
	readOnlyAutoPrd = "auto"    // no choice made; the name looks like production
)

func (s *Server) readOnlyReason() string {
	if s.readOnly {
		return readOnlyFlag
	}
	c := s.mgr.Clients()
	if c == nil {
		return ""
	}
	return contextReadOnlyReason(s.settings, c.Context)
}

func contextReadOnlyReason(st *settings.Store, context string) string {
	if st != nil {
		if ro, chosen := st.ContextReadOnly(context); chosen {
			if ro {
				return readOnlyChosen
			}
			return ""
		}
	}
	if settings.AutoReadOnly(context) {
		return readOnlyAutoPrd
	}
	return ""
}

func (s *Server) isReadOnly() bool { return s.readOnlyReason() != "" }

func (s *Server) readOnlyMessage() string {
	switch s.readOnlyReason() {
	case readOnlyFlag:
		return "backend is running with --read-only"
	case "":
		return "read-only mode"
	default:
		return "this context is read-only in k8sman (click the lock next to the context to allow changes)"
	}
}

func (s *Server) readOnlyRoutes() {
	s.mux.HandleFunc("PUT /api/settings/readonly", s.handlePutReadOnly)
}

// handlePutReadOnly sets a context's read-only choice.
// Body: {"context": "<name>", "readOnly": true | false | null}; null goes
// back to automatic. Replies with the context's effective state.
func (s *Server) handlePutReadOnly(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Context  string `json:"context"`
		ReadOnly *bool  `json:"readOnly"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil || body.Context == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, apiError{Error: "body must be {context, readOnly}", Code: http.StatusBadRequest})
		return
	}
	if s.settings == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, apiError{Error: "settings are not available", Code: http.StatusServiceUnavailable})
		return
	}
	if err := s.settings.SetContextReadOnly(body.Context, body.ReadOnly); err != nil {
		writeErr(w, err)
		return
	}
	reason := contextReadOnlyReason(s.settings, body.Context)
	if s.readOnly {
		reason = readOnlyFlag
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": body.Context, "readOnly": reason != "", "readOnlyReason": reason})
}
