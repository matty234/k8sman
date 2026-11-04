package server

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/portforward"
)

const fieldManager = "k8sman"

func (s *Server) mutationRoutes() {
	s.mux.HandleFunc("PUT /api/object", s.handleUpdateObject)

	s.mux.HandleFunc("GET /api/portforwards", s.handleListForwards)
	s.mux.HandleFunc("POST /api/portforwards", s.handleCreateForward)
	s.mux.HandleFunc("PATCH /api/portforwards/{id}", s.handleUpdateForward)
	s.mux.HandleFunc("POST /api/portforwards/{id}/start", s.handleForwardAction)
	s.mux.HandleFunc("POST /api/portforwards/{id}/stop", s.handleForwardAction)
	s.mux.HandleFunc("DELETE /api/portforwards/{id}", s.handleDeleteForward)
}

// handleUpdateObject replaces an object with the YAML/JSON body (like
// `kubectl edit`). The body must carry metadata.resourceVersion so a
// concurrent change yields 409 Conflict instead of being overwritten.
// ?dryRun=true runs server-side validation/admission without persisting.
func (s *Server) handleUpdateObject(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteJSON(w, http.StatusForbidden, apiError{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
		return
	}
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	name := r.URL.Query().Get("name")
	body, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
	if err != nil {
		writeErr(w, httpx.BadRequest("read body: %v", err))
		return
	}
	js, err := yaml.YAMLToJSON(body)
	if err != nil {
		writeErr(w, httpx.BadRequest("invalid YAML: %v", err))
		return
	}
	obj := &unstructured.Unstructured{}
	if err := obj.UnmarshalJSON(js); err != nil {
		writeErr(w, httpx.BadRequest("invalid object: %v", err))
		return
	}
	switch {
	case obj.GetName() != name:
		writeErr(w, httpx.BadRequest("metadata.name %q doesn't match %q (renaming isn't supported)", obj.GetName(), name))
		return
	case rq.Type.Namespaced && obj.GetNamespace() != "" && obj.GetNamespace() != rq.Namespace:
		writeErr(w, httpx.BadRequest("metadata.namespace %q doesn't match %q", obj.GetNamespace(), rq.Namespace))
		return
	case obj.GetResourceVersion() == "":
		writeErr(w, httpx.BadRequest("metadata.resourceVersion is required (it protects against overwriting concurrent changes)"))
		return
	case obj.GetKind() == "" || obj.GetAPIVersion() == "":
		writeErr(w, httpx.BadRequest("apiVersion and kind are required"))
		return
	}
	opts := metav1.UpdateOptions{FieldManager: fieldManager}
	dryRun := r.URL.Query().Get("dryRun") == "true"
	if dryRun {
		opts.DryRun = []string{metav1.DryRunAll}
	}
	out, err := rq.client(c).Update(r.Context(), obj, opts)
	if err != nil {
		writeErr(w, err)
		return
	}
	out.SetManagedFields(nil)
	y, _ := yaml.Marshal(out.Object)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"dryRun":          dryRun,
		"resourceVersion": out.GetResourceVersion(),
		"yaml":            string(y),
		"context":         c.Context,
	})
}

// ---- port-forwards ---------------------------------------------------------

func (s *Server) handleListForwards(w http.ResponseWriter, r *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"forwards": s.pf.List()})
}

func (s *Server) handleCreateForward(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteJSON(w, http.StatusForbidden, apiError{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
		return
	}
	var spec portforward.Spec
	if err := json.NewDecoder(r.Body).Decode(&spec); err != nil {
		writeErr(w, httpx.BadRequest("invalid body: %v", err))
		return
	}
	st, err := s.pf.Create(spec)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, st)
}

func (s *Server) handleUpdateForward(w http.ResponseWriter, r *http.Request) {
	var body struct {
		AutoStart *bool   `json:"autoStart"`
		Label     *string `json:"label"`
		LocalPort *int    `json:"localPort"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("invalid body: %v", err))
		return
	}
	st, err := s.pf.Update(r.PathValue("id"), body.AutoStart, body.Label, body.LocalPort)
	if err != nil {
		s.forwardErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}

func (s *Server) handleForwardAction(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var err error
	if r.URL.Path[len(r.URL.Path)-5:] == "start" {
		if s.isReadOnly() {
			httpx.WriteJSON(w, http.StatusForbidden, apiError{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
			return
		}
		err = s.pf.Start(id)
	} else {
		err = s.pf.Stop(id)
	}
	if err != nil {
		s.forwardErr(w, err)
		return
	}
	st, _ := s.pf.Get(id)
	httpx.WriteJSON(w, http.StatusOK, st)
}

func (s *Server) handleDeleteForward(w http.ResponseWriter, r *http.Request) {
	if err := s.pf.Delete(r.PathValue("id")); err != nil {
		s.forwardErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) forwardErr(w http.ResponseWriter, err error) {
	if portforward.IsNotFound(err) {
		httpx.WriteJSON(w, http.StatusNotFound, apiError{Error: err.Error(), Code: http.StatusNotFound})
		return
	}
	writeErr(w, err)
}

// statusCauses extracts field-level validation causes from an API error.
func statusCauses(err error) []map[string]string {
	var se apierrors.APIStatus
	if !errors.As(err, &se) || se.Status().Details == nil {
		return nil
	}
	var out []map[string]string
	for _, c := range se.Status().Details.Causes {
		out = append(out, map[string]string{"field": c.Field, "message": c.Message, "reason": string(c.Type)})
	}
	return out
}
