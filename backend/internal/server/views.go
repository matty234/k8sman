package server

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Saved views (docs/VIEWS.md) live in settings.json and work without a
// cluster connection, so the error and connecting screens can list them.
func (s *Server) viewRoutes() {
	s.mux.HandleFunc("GET /api/settings/views", s.handleGetViews)
	s.mux.HandleFunc("PUT /api/settings/views/launch", s.handlePutLaunchView)
	s.mux.HandleFunc("POST /api/settings/views/export", s.handleExportViews)
	s.mux.HandleFunc("POST /api/settings/views/parse", s.handleParseViews)
	s.mux.HandleFunc("PUT /api/settings/views/{id}", s.handlePutView)
	s.mux.HandleFunc("DELETE /api/settings/views/{id}", s.handleDeleteView)
}

// handleGetViews returns {views: [...], launchView: "<id>"}. Records are
// returned as stored, including ones of a newer version than this build
// writes (clients skip what they don't understand).
func (s *Server) handleGetViews(w http.ResponseWriter, r *http.Request) {
	st := s.settings.Get()
	views := st.Views
	if views == nil {
		views = []json.RawMessage{}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"views": views, "launchView": st.LaunchView})
}

// handlePutView adds or replaces the view with the path's id.
func (s *Server) handlePutView(w http.ResponseWriter, r *http.Request) {
	var v settings.View
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<18)).Decode(&v); err != nil {
		writeErr(w, httpx.BadRequest("invalid view: %v", err))
		return
	}
	if v.ID != r.PathValue("id") {
		writeErr(w, httpx.BadRequest("the view's id must match the URL"))
		return
	}
	if v.Namespaces == nil {
		v.Namespaces = []string{}
	}
	if err := v.Valid(); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	cols := make([]columns.Column, len(v.Columns))
	for i, c := range v.Columns {
		cols[i] = columns.Column{Name: c.Name, Query: c.Query, Type: c.Type}
	}
	if err := columns.Validate(cols); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if err := s.settings.PutView(v); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}

func (s *Server) handleDeleteView(w http.ResponseWriter, r *http.Request) {
	if err := s.settings.DeleteView(r.PathValue("id")); err != nil {
		writeErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handlePutLaunchView sets the view opened at launch. Body: {"id": "<id>"}
// ("" = reconnect to the last context, as by default).
func (s *Server) handlePutLaunchView(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {\"id\": \"<view id>\"}"))
		return
	}
	if err := s.settings.SetLaunchView(body.ID); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"launchView": body.ID})
}

// viewDoc is the shareable YAML form of a view (docs/VIEWS.md, "Sharing").
// The kubeconfig path is never exported; a bound view keeps its context
// name and API server URL so the importer can re-point it.
type viewDoc struct {
	APIVersion string                `json:"apiVersion"`
	Kind       string                `json:"kind"`
	Name       string                `json:"name"`
	Context    *viewDocContext       `json:"context"`
	Resource   settings.ViewKind     `json:"resource"`
	Namespaces []string              `json:"namespaces"`
	Filter     string                `json:"filter,omitempty"`
	Sort       *settings.ViewSort    `json:"sort,omitempty"`
	Columns    []settings.ViewColumn `json:"columns,omitempty"`
}

type viewDocContext struct {
	Name   string `json:"name"`
	Server string `json:"server,omitempty"`
}

const viewDocAPIVersion = "k8sman.dev/v1"

// handleExportViews renders views as YAML documents. Body: {"views": [View]}
// (the client sends what it shows, so unsaved edits export too).
func (s *Server) handleExportViews(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Views []settings.View `json:"views"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {\"views\": [...]}: %v", err))
		return
	}
	var out bytes.Buffer
	for i, v := range body.Views {
		d := viewDoc{APIVersion: viewDocAPIVersion, Kind: "View", Name: v.Name, Resource: v.Kind, Namespaces: v.Namespaces,
			Filter: v.Filter, Sort: v.Sort, Columns: v.Columns}
		if d.Namespaces == nil {
			d.Namespaces = []string{}
		}
		if v.Context != nil {
			d.Context = &viewDocContext{Name: v.Context.Name, Server: v.Context.Server}
		}
		b, err := yaml.Marshal(d)
		if err != nil {
			writeErr(w, err)
			return
		}
		if i > 0 {
			out.WriteString("---\n")
		}
		out.Write(b)
	}
	w.Header().Set("Content-Type", "application/yaml")
	_, _ = w.Write(out.Bytes())
}

// handleParseViews reads YAML view documents (as exported) and returns them
// as views with fresh ids, without saving: the UI re-points bound contexts
// first. Body: {"yaml": "..."}.
func (s *Server) handleParseViews(w http.ResponseWriter, r *http.Request) {
	var body struct {
		YAML string `json:"yaml"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {\"yaml\": \"...\"}: %v", err))
		return
	}
	views, err := parseViewDocs(body.YAML)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"views": views})
}

func parseViewDocs(text string) ([]settings.View, error) {
	views := []settings.View{}
	for i, doc := range splitYAMLDocs([]byte(text)) {
		var d viewDoc
		if err := yaml.UnmarshalStrict([]byte(doc.text), &d); err != nil {
			return nil, fmt.Errorf("document %d: %v", i+1, err)
		}
		if d.APIVersion != viewDocAPIVersion || d.Kind != "View" {
			return nil, fmt.Errorf("document %d: not a view (want apiVersion %s, kind View)", i+1, viewDocAPIVersion)
		}
		v := settings.View{Version: settings.ViewVersion, ID: newViewID(), Name: d.Name, Kind: d.Resource, Namespaces: d.Namespaces,
			Filter: d.Filter, Sort: d.Sort, Columns: d.Columns}
		if v.Namespaces == nil {
			v.Namespaces = []string{}
		}
		if d.Context != nil {
			v.Context = &settings.ViewContext{Name: d.Context.Name, Server: d.Context.Server}
		}
		if err := v.Valid(); err != nil {
			return nil, fmt.Errorf("document %d: %v", i+1, err)
		}
		views = append(views, v)
	}
	if len(views) == 0 {
		return nil, errors.New("no views found")
	}
	return views, nil
}

func newViewID() string {
	b := make([]byte, 8)
	_, _ = io.ReadFull(rand.Reader, b)
	return hex.EncodeToString(b)
}
