package server

import (
	"context"
	"fmt"
	"net/http"
	"sync"

	"k8s.io/client-go/dynamic"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/overview"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Integrations (Argo CD, Helm, GPUs, …) are compile-time modules: each
// one is a Module in its own file, listed in builtinModules. The server
// mounts their routes and asks the optional interfaces below for overview
// inputs and actions. Core features (tables, logs, exec, port-forwards,
// nodes, security, RBAC, the editor) are not modules.
//
// To add one: implement Module (plus OverviewSource / ActionSource if it
// needs them) and add it to builtinModules. See docs/DEVELOPMENT.md.

// Module is one built-in integration.
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
	}
}

// mountModules registers every module's routes.
func (s *Server) mountModules() {
	d := Deps{Mgr: s.mgr, Settings: s.settings, ReadOnlyFlag: s.readOnly, RefuseReadOnly: s.readOnlyRefused}
	for _, m := range s.modules {
		m.Routes(s.mux, d)
	}
}

// readOnlyRefused writes 403 when the current context is read-only.
func (s *Server) readOnlyRefused(w http.ResponseWriter) bool {
	if s.isReadOnly() {
		httpx.WriteJSON(w, http.StatusForbidden, apiError{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
		return true
	}
	return false
}

// enabledModules are the modules currently switched on.
func (s *Server) enabledModules() []Module {
	return s.modules
}

// OverviewLists runs the health overview's lists in parallel and collects
// the input for overview.Analyze.
type OverviewLists struct {
	Ctx     context.Context
	Clients *cluster.Clients
	// Namespace is the overview's namespace ("" = all).
	Namespace string

	in   overview.Input
	mu   sync.Mutex
	wg   sync.WaitGroup
	errs map[string]error
}

// Go runs list in the background. When it returns an apply func, that is
// called (under a lock, so it may write to the shared Input) to store the
// result; an error is reported in the overview's `errors` under name.
func (l *OverviewLists) Go(name string, list func() (apply func(in *overview.Input), err error)) {
	l.wg.Add(1)
	go func() {
		defer l.wg.Done()
		apply, err := list()
		l.mu.Lock()
		defer l.mu.Unlock()
		if apply != nil {
			apply(&l.in)
		}
		if err != nil {
			l.errs[name] = fmt.Errorf("list %s: %w", name, err)
		}
	}()
}

// Set changes the input right away (under the lock).
func (l *OverviewLists) Set(f func(in *overview.Input)) {
	l.mu.Lock()
	defer l.mu.Unlock()
	f(&l.in)
}
