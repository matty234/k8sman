package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"k8s.io/client-go/dynamic"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/overview"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Integrations (Argo CD, Helm, GPUs, …) are compile-time modules: each
// one is a Module in its own file, listed in builtinModules. The server
// mounts their routes and asks the optional interfaces below for overview
// inputs and actions. Core features (tables, logs, exec, port-forwards,
// nodes, security, RBAC, the editor) are not modules.
//
// To add one: implement Module (plus OverviewSource / ActionSource /
// Configurable if it needs them) and add it to builtinModules. See
// docs/DEVELOPMENT.md.

// Module is one built-in integration. The user can turn it off
// (settings.json's disabledModules, set by the UI): then its routes answer
// 404 (reason ModuleDisabled) and it adds no overview inputs or actions.
type Module interface {
	// Name is the module's id: the same id as the UI's module
	// (frontend/lib/modules), e.g. "argocd".
	Name() string
	// Routes mounts the module's HTTP endpoints on r.
	Routes(r httpx.Router, d Deps)
}

// Deps is what the server hands every module. Requests reach a module's
// handlers only after the access checks (Host, Origin, bearer token,
// Content-Type; see guard.go), so modules don't deal with auth.
type Deps struct {
	Mgr      *cluster.Manager
	Settings *settings.Store
	// ReadOnlyFlag is --read-only (the whole backend is read-only).
	ReadOnlyFlag bool
	// RefuseReadOnly answers 403 and returns true when the current context
	// is read-only (the flag, or the user's per-context lock): call it
	// first in handlers that change the cluster.
	RefuseReadOnly func(w http.ResponseWriter) bool
	// ParseScope reads a request's namespace scope, narrowing "all" to the
	// context's namespace allowlist when it has one.
	ParseScope func(q url.Values) (kube.Namespaces, error)
}

// OverviewSource is implemented by modules that feed the health overview
// (GET /api/overview): they list their objects into overview.Input, and
// the overview package's analysis turns them into issues.
type OverviewSource interface {
	OverviewInputs(l *OverviewLists)
}

// ActionSource is implemented by modules that add actions to
// POST /api/actions/{action}.
type ActionSource interface {
	// ActionTargets maps action name → the "group/resource" targets it
	// applies to (see actionTargets). Naming a core action (e.g. "suspend")
	// only adds targets: the core still runs it.
	ActionTargets() map[string][]string
	// RunAction runs one of the module's own actions.
	RunAction(a ActionCall) (ActionResult, error)
}

// Configurable is implemented by modules with their own settings (e.g.
// Hubble's relay address). They are JSON objects saved per kube context in
// settings.json's moduleSettings, read and written through
// GET/PUT /api/settings/modules/{id}; the module reads them with
// Deps.Settings.ModuleSettings.
type Configurable interface {
	// ValidateSettings checks a PUT body (a JSON object; {} clears) before
	// it is saved.
	ValidateSettings(raw json.RawMessage) error
}

// SecretSettings is implemented by Configurable modules whose settings
// hold a secret (Argo CD's token). GET shows RedactSettings instead of
// what is saved, and a PUT body goes through MergeSettings before it is
// validated and saved, so the UI can change one field without ever
// having the secret.
type SecretSettings interface {
	// RedactSettings is the saved settings as the UI may see them.
	RedactSettings(saved json.RawMessage) json.RawMessage
	// MergeSettings combines the saved settings with a PUT body.
	MergeSettings(saved, body json.RawMessage) (json.RawMessage, error)
}

// ActionCall is one action request, already checked to be available for
// the target's type.
type ActionCall struct {
	Ctx     context.Context
	Clients *cluster.Clients
	Action  string
	// Type, Namespace and Name identify the target object.
	Type      cluster.ResourceType
	Namespace string
	Name      string
	// Resource is the dynamic client for the target's type and namespace.
	Resource dynamic.ResourceInterface
	// DryRun is the request's dryRun; DryRunOpt is the matching
	// metav1 DryRun option (nil or [All]).
	DryRun    bool
	DryRunOpt []string
	// Body is the raw request body (empty when there was none), for the
	// module's own fields.
	Body []byte
}

// builtinModules are the integrations compiled into the server.
func builtinModules() []Module {
	return []Module{
		&argoCDModule{},
		&argoWFModule{},
		&helmModule{},
		&gpuModule{},
		&promModule{},
		&gatewayModule{},
		&hubbleModule{},
		&externalSecretsModule{},
		&upgradeModule{},
	}
}

// mountModules registers every module's routes, behind a check that
// answers 404 while the user has the module turned off.
func (s *Server) mountModules() {
	d := Deps{Mgr: s.mgr, Settings: s.settings, ReadOnlyFlag: s.readOnly, RefuseReadOnly: s.refuseReadOnly, ParseScope: s.parseScope}
	for _, m := range s.modules {
		m.Routes(moduleRouter{s: s, name: m.Name()}, d)
	}
	s.mux.HandleFunc("GET /api/settings/modules", s.handleGetModules)
	s.mux.HandleFunc("PUT /api/settings/modules", s.handlePutModules)
	s.mux.HandleFunc("GET /api/settings/modules/{id}", s.handleGetModuleSettings)
	s.mux.HandleFunc("PUT /api/settings/modules/{id}", s.handlePutModuleSettings)
}

// configurable returns module id when it has settings.
func (s *Server) configurable(id string) (Configurable, bool) {
	for _, m := range s.modules {
		if m.Name() == id {
			c, ok := m.(Configurable)
			return c, ok
		}
	}
	return nil, false
}

// settingsContext is ?context=, else the current kube context.
func (s *Server) settingsContext(r *http.Request) string {
	if c := r.URL.Query().Get("context"); c != "" {
		return c
	}
	if c := s.mgr.Clients(); c != nil {
		return c.Context
	}
	return ""
}

// handleGetModuleSettings returns {context, settings}: module id's settings
// for the context ({} when none are saved).
func (s *Server) handleGetModuleSettings(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := s.configurable(id); !ok {
		httpx.WriteError(w, http.StatusNotFound, "", fmt.Sprintf("module %q has no settings", id))
		return
	}
	ctx := s.settingsContext(r)
	raw := s.settings.RawModuleSettings(id, ctx)
	if raw == nil {
		raw = json.RawMessage("{}")
	}
	if m, _ := s.configurable(id); m != nil {
		if ss, ok := m.(SecretSettings); ok {
			raw = ss.RedactSettings(raw)
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"context": ctx, "settings": raw})
}

// handlePutModuleSettings validates and saves the body (a JSON object; {}
// clears) as module id's settings for the context. Allowed in read-only
// mode: it changes k8sman's settings, not the cluster.
func (s *Server) handlePutModuleSettings(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m, ok := s.configurable(id)
	if !ok {
		httpx.WriteError(w, http.StatusNotFound, "", fmt.Sprintf("module %q has no settings", id))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 64<<10))
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if ss, ok := m.(SecretSettings); ok {
		if raw, err = ss.MergeSettings(s.settings.RawModuleSettings(id, s.settingsContext(r)), raw); err != nil {
			writeErr(w, httpx.BadRequest("%v", err))
			return
		}
	}
	if err := m.ValidateSettings(raw); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if err := s.settings.SetModuleSettings(id, s.settingsContext(r), raw); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	s.handleGetModuleSettings(w, r)
}

// moduleRouter mounts a module's handlers on the server's mux.
type moduleRouter struct {
	s    *Server
	name string
}

func (mr moduleRouter) HandleFunc(pattern string, h func(http.ResponseWriter, *http.Request)) {
	mr.s.mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
		if mr.s.settings.ModuleDisabled(mr.name) {
			httpx.WriteError(w, http.StatusNotFound, "ModuleDisabled",
				fmt.Sprintf("the %s integration is turned off in k8sman's settings", mr.name))
			return
		}
		h(w, r)
	})
}

// handleGetModules returns {disabled: [ids]}: the integrations the user
// turned off. Works without a cluster connection.
func (s *Server) handleGetModules(w http.ResponseWriter, r *http.Request) {
	disabled := s.settings.Get().DisabledModules
	if disabled == nil {
		disabled = []string{}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"disabled": disabled})
}

// handlePutModules saves {disabled: [ids]}. Ids may name UI-only modules
// (e.g. "addons") too.
func (s *Server) handlePutModules(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Disabled []string `json:"disabled"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("body must be {\"disabled\": [...]}: %v", err))
		return
	}
	if err := s.settings.SetDisabledModules(body.Disabled); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	s.handleGetModules(w, r)
}

// refuseReadOnly writes 403 when the current context is read-only.
func (s *Server) refuseReadOnly(w http.ResponseWriter) bool {
	if s.isReadOnly() {
		httpx.WriteError(w, http.StatusForbidden, "", s.readOnlyMessage())
		return true
	}
	return false
}

// enabledModules are the modules the user hasn't turned off: only they
// feed the overview and offer actions.
func (s *Server) enabledModules() []Module {
	out := make([]Module, 0, len(s.modules))
	for _, m := range s.modules {
		if !s.settings.ModuleDisabled(m.Name()) {
			out = append(out, m)
		}
	}
	return out
}

// OverviewLists runs the health overview's lists in parallel and collects
// the input for overview.Analyze (see sourceRun: sources keep running after
// a request has answered, storing their results under a lock).
type OverviewLists struct {
	*sourceRun[overview.Input]
	Clients *cluster.Clients
	// Namespace is the overview's namespace ("" = all), or a namespace set
	// "a,b": listCached and listTyped accept either.
	Namespace string
}

func newOverviewLists(ctx context.Context, c *cluster.Clients, ns string) *OverviewLists {
	return &OverviewLists{sourceRun: newSourceRun[overview.Input](ctx, "pods", overviewLabel, overviewHardWait, overviewReuse), Clients: c, Namespace: ns}
}

// overviewSourceLabels maps source names onto the labels reported in the
// response's `pending` (the frontend maps those onto its sections).
var overviewSourceLabels = map[string]string{
	"persistentvolumeclaims":   "pvcs",
	"applications.argoproj.io": "argocd",
	"workflows.argoproj.io":    "workflows",
	"gateways":                 "gateway",
	"httproutes":               "gateway",
	"grpcroutes":               "gateway",
	"tcproutes":                "gateway",
	"tlsroutes":                "gateway",
	"udproutes":                "gateway",
}

func overviewLabel(name string) string {
	if l, ok := overviewSourceLabels[name]; ok {
		return l
	}
	return name
}

// snapshot copies what has completed so far: the input (with the labels of
// the sources still running in Pending) and the errors.
func (l *OverviewLists) snapshot() (overview.Input, map[string]error) {
	in, pending, errs := l.snap()
	in.Now = time.Now()
	in.Pending = pending
	return in, errs
}
