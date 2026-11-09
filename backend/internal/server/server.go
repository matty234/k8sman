// Package server exposes the cluster over a local HTTP + WebSocket API for the
// Flutter UI. See API.md at the repo root for the contract.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/icons"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/metrics"
	"github.com/matty234/k8sman/backend/internal/portforward"
	"github.com/matty234/k8sman/backend/internal/settings"
)

// Server wires the HTTP API to a cluster manager and column store.
type Server struct {
	mgr      *cluster.Manager
	store    *columns.Store
	pf       *portforward.Manager
	readOnly bool
	settings *settings.Store
	mux      *http.ServeMux
	icons    *icons.Resolver
	token    string
	// modules are the built-in integrations (see module.go).
	modules []Module
	// overviewRuns shares one in-flight overview run per context and scope.
	overviewRuns overviewRuns
	// securityRuns shares one in-flight security run per context and scope.
	securityRuns runRegistry[*securityLists]
}

// Options configures optional server behaviour.
type Options struct {
	// ReadOnly disables object edits and starting port-forwards.
	ReadOnly bool
	// Settings persists the chosen kubeconfig and last context. Optional.
	Settings *settings.Store
	// NoRemoteIcons disables fetching CRD group icons from the internet.
	NoRemoteIcons bool
	// IconCacheDir caches resolved icons ("" = memory only).
	IconCacheDir string
	// AuthToken is the bearer token every request must carry (see
	// checkAccess in guard.go). Shorter than MinTokenLength (or empty) means
	// every request is refused with 401: there is no unauthenticated mode.
	AuthToken string
}

// New builds the server and registers routes.
func New(mgr *cluster.Manager, store *columns.Store, pf *portforward.Manager, opts Options) *Server {
	s := &Server{mgr: mgr, store: store, pf: pf, readOnly: opts.ReadOnly, settings: opts.Settings, mux: http.NewServeMux(), token: opts.AuthToken}
	if s.settings == nil {
		s.settings, _ = settings.Open("")
	}
	s.routes()
	s.mutationRoutes()
	s.applyRoutes()
	s.actionRoutes()
	s.drainRoutes()
	s.overviewRoutes()
	s.kubeconfigRoutes()
	s.sidebarRoutes()
	s.linkRoutes()
	s.securityIgnoreRoutes()
	s.logSettingsRoutes()
	s.viewRoutes()
	s.readOnlyRoutes()
	s.tablePrefsRoutes()
	s.namespaceRoutes()
	s.appearanceRoutes()
	s.execRoutes()
	s.localShellRoutes()
	s.securityRoutes()
	s.rbacRoutes()
	metrics.Register(s.mux, mgr, s.allowedNamespaces)
	s.iconRoutes(opts)
	// Integrations (Argo CD, Helm, GPUs, …): see module.go.
	s.modules = builtinModules()
	s.mountModules()
	return s
}

// worksDisconnected lists endpoints that don't need an active context, so
// the UI can still pick a kubeconfig when none could be loaded.
func worksDisconnected(path string) bool {
	return path == "/api/health" || path == "/api/contexts" ||
		strings.HasPrefix(path, "/api/kubeconfigs") || strings.HasPrefix(path, "/api/portforwards") ||
		strings.HasPrefix(path, "/api/settings/")
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /api/health", s.handleHealth)
	s.mux.HandleFunc("GET /api/contexts", s.handleContexts)
	s.mux.HandleFunc("POST /api/contexts/current", s.handleSwitchContext)
	s.mux.HandleFunc("GET /api/probe", s.handleProbe)
	s.mux.HandleFunc("GET /api/resources", s.handleResources)
	s.mux.HandleFunc("GET /api/namespaces", s.handleNamespaces)
	s.mux.HandleFunc("GET /api/table", s.handleTable)
	s.mux.HandleFunc("GET /api/items", s.handleItems)
	s.mux.HandleFunc("GET /api/object", s.handleObject)
	s.mux.HandleFunc("GET /api/events", s.handleEvents)
	s.mux.HandleFunc("GET /api/owned", s.handleOwned)
	s.mux.HandleFunc("GET /api/columns", s.handleGetColumns)
	s.mux.HandleFunc("PUT /api/columns", s.handlePutColumns)
	s.mux.HandleFunc("DELETE /api/columns", s.handleDeleteColumns)
	s.mux.HandleFunc("POST /api/columns/preview", s.handlePreviewColumns)
	s.mux.HandleFunc("GET /api/watch", s.handleWatch)
	s.mux.HandleFunc("GET /api/logs", s.handleLogs)
	s.mux.HandleFunc("GET /api/logs/aggregate", s.handleLogsAggregate)
}

// ServeHTTP checks Host, Origin, the bearer token and Content-Type
// (guard.go), then routes and logs.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !checkAccess(w, r, s.token) {
		return
	}
	start := time.Now()
	if s.mgr.Clients() == nil && !worksDisconnected(r.URL.Path) {
		httpx.WriteError(w, http.StatusServiceUnavailable, "NoKubeconfig", fmt.Sprintf("no cluster connection: %v", s.mgr.Err()))
		return
	}
	if contextMismatch(w, r, s.mgr.Clients()) {
		return
	}
	s.mux.ServeHTTP(w, r)
	if r.URL.Path != "/api/health" {
		log.Printf("%s %s (%s)", r.Method, r.URL.RequestURI(), time.Since(start).Round(time.Millisecond))
	}
}

// ContextHeader carries the context the UI showed when it sent a request.
const ContextHeader = "X-K8sman-Context"

// contextMismatch refuses a change (any non-GET request) made for a context
// other than the current one: the UI confirmed it against the context it
// showed, and the backend may have switched since. Switching contexts and
// kubeconfigs, and app settings, aren't tied to a cluster.
func contextMismatch(w http.ResponseWriter, r *http.Request, c *cluster.Clients) bool {
	want := r.Header.Get(ContextHeader)
	if want == "" || c == nil || r.Method == http.MethodGet || r.Method == http.MethodHead || c.Context == want {
		return false
	}
	for _, p := range []string{"/api/contexts", "/api/kubeconfigs", "/api/settings"} {
		if strings.HasPrefix(r.URL.Path, p) {
			return false
		}
	}
	httpx.WriteError(w, http.StatusConflict, "ContextMismatch",
		fmt.Sprintf("k8sman is now on context %q, not %q, so nothing was changed. Check the cluster and try again.", c.Context, want))
	return true
}

// ---- helpers ---------------------------------------------------------------

func writeErr(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	reason := ""
	if r, c := classifyError(err); r != "" {
		status, reason = c, r
	} else if c, r, ok := httpx.KubeStatus(err, status); ok {
		status, reason = c, r
	} else if errors.Is(err, httpx.ErrBadRequest) {
		status = http.StatusBadRequest
	}
	httpx.WriteJSON(w, status, httpx.ErrorBody{Error: err.Error(), Code: status, Reason: reason, Causes: statusCauses(err)})
}

// resourceQuery is the common ?group=&version=&resource=&namespace= target.
type resourceQuery struct {
	Type      cluster.ResourceType
	Namespace string
	// Namespaces is a set of two or more namespaces (?namespaces=a,b); then
	// Namespace is "". One namespace is always in Namespace.
	Namespaces kube.Namespaces
	// Columns, when set (?columns=<JSON array>), replace the kind's column
	// configuration for this request: a saved view's own columns.
	Columns       []columns.Column
	LabelSelector string
	FieldSelector string
}

func (s *Server) parseResource(ctx context.Context, r *http.Request) (*cluster.Clients, resourceQuery, error) {
	q := r.URL.Query()
	c := s.mgr.Clients()
	res := q.Get("resource")
	if res == "" {
		return c, resourceQuery{}, httpx.BadRequest("resource is required")
	}
	rt, err := c.Find(ctx, q.Get("group"), q.Get("version"), res)
	if err != nil {
		err = discoveryErr(err)
		if reason, _ := classifyError(err); reason != "" {
			return c, resourceQuery{}, err // discovery failed: unreachable, unauthorized, …
		}
		if strings.Contains(err.Error(), "not found") {
			return c, resourceQuery{}, fmt.Errorf("%w: %v", errNotServed, err)
		}
		return c, resourceQuery{}, httpx.BadRequest("%v", err)
	}
	scope, err := kube.ParseNamespaces(q)
	if err != nil {
		return c, resourceQuery{}, httpx.BadRequest("%v", err)
	}
	if scope.All() && rt.Namespaced && r.Method == http.MethodGet {
		// Reads of "all namespaces" fan out over the allowlist, if any.
		scope = s.allowedNamespaces()
	}
	rq := resourceQuery{
		Type:          rt,
		Namespace:     scope.Single(),
		LabelSelector: q.Get("labelSelector"),
		FieldSelector: q.Get("fieldSelector"),
	}
	if len(scope) > 1 && rt.Namespaced {
		rq.Namespaces = scope
	}
	if raw := q.Get("columns"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &rq.Columns); err != nil {
			return c, resourceQuery{}, httpx.BadRequest("columns must be a JSON array of columns: %v", err)
		}
		if err := columns.Validate(rq.Columns); err != nil {
			return c, resourceQuery{}, httpx.BadRequest("%v", err)
		}
	}
	return c, rq, nil
}

// subscribe joins the shared watch for the query: one stream, or for a
// namespace set one per namespace, merged (see kcache.SubscribeSet).
func (s *Server) subscribe(c *cluster.Clients, rq resourceQuery) kcache.Subscription {
	if len(rq.Namespaces) > 1 {
		return kcache.For(c).SubscribeSet(rq.cacheKey(), rq.Namespaces)
	}
	return kcache.For(c).Subscribe(rq.cacheKey())
}

// inNamespace is the query narrowed to one namespace of its set.
func (rq resourceQuery) inNamespace(ns string) resourceQuery {
	rq.Namespace, rq.Namespaces = ns, nil
	return rq
}

func (rq resourceQuery) client(c *cluster.Clients) dynamic.ResourceInterface {
	ri := c.Dynamic.Resource(rq.Type.GVR())
	if rq.Type.Namespaced && rq.Namespace != "" {
		return ri.Namespace(rq.Namespace)
	}
	return ri
}

// cacheKey is the shared-watch key for the query.
func (rq resourceQuery) cacheKey() kcache.Key {
	return kcache.Key{GVR: rq.Type.GVR(), Namespace: namespaceFor(rq), LabelSelector: rq.LabelSelector, FieldSelector: rq.FieldSelector}
}

// listing is a point-in-time list, from the shared watch cache or a LIST.
type listing struct {
	items []*unstructured.Unstructured // shared with the cache: read only
	rv    string
	memo  memoFunc // nil for a direct LIST
	// partial lists namespaces of a set that could not be read (the
	// others are in items).
	partial []PartialError
}

// PartialError is a namespace of a namespace set that could not be read
// (e.g. RBAC forbids it) while the others could. It is the payload of the
// PARTIAL_ERROR watch frame and of `partialErrors` in /api/table and
// /api/items.
type PartialError struct {
	Namespace string `json:"namespace"`
	Error     string `json:"error"`
	Reason    string `json:"reason,omitempty"`
	Code      int    `json:"code,omitempty"`
}

func partialError(ns string, err error) PartialError {
	f := errorFrame(nil, err)
	return PartialError{Namespace: ns, Error: f.Error, Reason: f.Reason, Code: f.Code}
}

// snapshot answers from a warm shared watch, else with a direct LIST (a
// one-off read shouldn't start a watch). A namespace set is answered from
// a warm all-namespaces watch when there is one, else by reading every
// namespace in parallel; namespaces that fail are reported in partial,
// unless all of them fail.
func (s *Server) snapshot(ctx context.Context, c *cluster.Clients, rq resourceQuery) (listing, error) {
	if len(rq.Namespaces) > 1 {
		return s.snapshotSet(ctx, c, rq)
	}
	if snap, ok := kcache.For(c).Cached(rq.cacheKey()); ok {
		return listing{items: snap.Items, rv: snap.ResourceVersion, memo: snap.Memo}, nil
	}
	list, err := rq.client(c).List(ctx, rq.listOptions())
	if err != nil {
		return listing{}, err
	}
	items := make([]*unstructured.Unstructured, len(list.Items))
	for i := range list.Items {
		items[i] = &list.Items[i]
	}
	return listing{items: items, rv: list.GetResourceVersion()}, nil
}

func (s *Server) snapshotSet(ctx context.Context, c *cluster.Clients, rq resourceQuery) (listing, error) {
	if snap, ok := kcache.For(c).CachedSet(rq.cacheKey(), rq.Namespaces); ok {
		return listing{items: snap.Items, rv: snap.ResourceVersion, memo: snap.Memo}, nil
	}
	parts := make([]listing, len(rq.Namespaces))
	errs := make([]error, len(rq.Namespaces))
	var wg sync.WaitGroup
	for i, ns := range rq.Namespaces {
		wg.Add(1)
		go func() {
			defer wg.Done()
			parts[i], errs[i] = s.snapshot(ctx, c, rq.inNamespace(ns))
		}()
	}
	wg.Wait()
	var out listing
	memos := map[string]memoFunc{}
	failed := 0
	for i, ns := range rq.Namespaces {
		if errs[i] != nil {
			failed++
			out.partial = append(out.partial, partialError(ns, errs[i]))
			continue
		}
		out.items = append(out.items, parts[i].items...)
		if parts[i].memo != nil {
			memos[ns] = parts[i].memo
		}
	}
	if failed == len(rq.Namespaces) {
		return listing{}, errs[0]
	}
	if len(memos) > 0 {
		out.memo = func(u *unstructured.Unstructured, tag any, extra string, compute func() any) any {
			if m := memos[u.GetNamespace()]; m != nil {
				return m(u, tag, extra, compute)
			}
			return compute()
		}
	}
	return out, nil
}

func (rq resourceQuery) listOptions() metav1.ListOptions {
	return metav1.ListOptions{LabelSelector: rq.LabelSelector, FieldSelector: rq.FieldSelector}
}

// tableColumns is the query's own columns (a saved view's), else
// columnsFor.
func (s *Server) tableColumns(ctx context.Context, c *cluster.Clients, rq resourceQuery) (cols []columns.Column, isDefault bool) {
	if rq.Columns != nil {
		return rq.Columns, false
	}
	return s.columnsFor(ctx, c, rq.Type)
}

// columnsFor resolves user override → built-in → CRD printer columns → generic.
func (s *Server) columnsFor(ctx context.Context, c *cluster.Clients, rt cluster.ResourceType) (cols []columns.Column, isDefault bool) {
	if cols, ok := s.store.Get(columns.Key(rt.Group, rt.Resource)); ok {
		return cols, false
	}
	return columns.Defaults(rt, c.PrinterColumns(ctx, rt.GVR())), true
}

// ---- table model -----------------------------------------------------------

// Row is one table row. Object is included only when requested.
type Row struct {
	UID             string         `json:"uid"`
	Name            string         `json:"name"`
	Namespace       string         `json:"namespace,omitempty"`
	ResourceVersion string         `json:"resourceVersion"`
	Cells           []any          `json:"cells"`
	Object          map[string]any `json:"object,omitempty"`
	// Controlled is true when a controller owns the object (e.g. a pod of a
	// ReplicaSet), so deleting it means the controller recreates it.
	Controlled bool `json:"controlled,omitempty"`
}

// Table is a list rendered through the column set.
type Table struct {
	Resource        cluster.ResourceType `json:"resource"`
	Columns         []columns.Column     `json:"columns"`
	IsDefault       bool                 `json:"isDefaultColumns"`
	ResourceVersion string               `json:"resourceVersion"`
	Rows            []Row                `json:"rows"`
	// ColumnErrors maps column index → first evaluation error seen.
	ColumnErrors map[int]string `json:"columnErrors,omitempty"`
	// PartialErrors lists namespaces of a namespace set that could not be
	// read (/api/table only; the watch sends PARTIAL_ERROR frames).
	PartialErrors []PartialError `json:"partialErrors,omitempty"`
}

type tableBuilder struct {
	eval          *columns.Evaluator
	includeObject bool
	colErrs       map[int]string
	// decorate, if set, returns a copy of the object with extra data for the
	// columns (e.g. `.k8sman.usage` for pods/nodes). Row.Object stays the original.
	decorate metrics.Decorator
	// memo, if set, caches rendered rows per object version (see
	// kcache.Sub.Memo), so re-snapshots and usage ticks only re-evaluate the
	// jq columns of objects that changed.
	memo memoFunc
	tag  rowTag
}

type memoFunc func(u *unstructured.Unstructured, tag any, extra string, compute func() any) any

// rowTag identifies a column set + rendering options for the row memo.
type rowTag struct {
	cols          string
	includeObject bool
}

// builtRow is a rendered row, its per-column errors and (for rows without
// the object) its JSON, encoded once and shared by every watcher.
type builtRow struct {
	Row  Row
	errs []error
	raw  []byte
}

func newTableBuilder(cols []columns.Column, includeObject bool) *tableBuilder {
	key, _ := json.Marshal(cols)
	return &tableBuilder{eval: columns.NewEvaluator(cols), includeObject: includeObject, colErrs: map[int]string{},
		tag: rowTag{cols: string(key), includeObject: includeObject}}
}

func (b *tableBuilder) row(u *unstructured.Unstructured) Row { return b.build(u).Row }

func (b *tableBuilder) build(u *unstructured.Unstructured) *builtRow {
	obj := u.Object
	extra := ""
	if b.decorate != nil {
		obj = b.decorate(obj)
		if usage, ok := obj[metrics.UsageKey]; ok && b.memo != nil {
			fp, _ := json.Marshal(usage)
			extra = string(fp)
		}
	}
	compute := func() any {
		eval := obj
		if b.memo != nil {
			// Shared with other goroutines (the watch cache): gojq writes
			// to its input, so evaluate a private copy.
			eval = columns.PrivateCopy(obj)
		}
		cells, errs := b.eval.Row(eval)
		r := Row{
			UID:             string(u.GetUID()),
			Name:            u.GetName(),
			Namespace:       u.GetNamespace(),
			ResourceVersion: u.GetResourceVersion(),
			Cells:           cells,
			Controlled:      metav1.GetControllerOf(u) != nil,
		}
		br := &builtRow{Row: r, errs: errs}
		if b.includeObject {
			br.Row.Object = u.Object
		} else if b.memo != nil {
			br.raw, _ = json.Marshal(r)
		}
		return br
	}
	var br *builtRow
	if b.memo != nil {
		br = b.memo(u, b.tag, extra, compute).(*builtRow)
	} else {
		br = compute().(*builtRow)
	}
	for i, e := range br.errs {
		if e != nil {
			if _, seen := b.colErrs[i]; !seen {
				b.colErrs[i] = e.Error()
			}
		}
	}
	return br
}

func (b *tableBuilder) table(rt cluster.ResourceType, isDefault bool, list *unstructured.UnstructuredList) Table {
	items := make([]*unstructured.Unstructured, len(list.Items))
	for i := range list.Items {
		items[i] = &list.Items[i]
	}
	t, _ := b.tableOf(rt, isDefault, items, list.GetResourceVersion())
	return t
}

// tableOf renders items (rows sorted by namespace, name) and also returns
// each row's builtRow in the same order.
func (b *tableBuilder) tableOf(rt cluster.ResourceType, isDefault bool, items []*unstructured.Unstructured, rv string) (Table, []*builtRow) {
	t := Table{Resource: rt, Columns: b.eval.Columns(), IsDefault: isDefault, ResourceVersion: rv, Rows: make([]Row, 0, len(items))}
	built := make([]*builtRow, 0, len(items))
	for _, u := range items {
		built = append(built, b.build(u))
	}
	sort.SliceStable(built, func(i, j int) bool {
		if built[i].Row.Namespace != built[j].Row.Namespace {
			return built[i].Row.Namespace < built[j].Row.Namespace
		}
		return built[i].Row.Name < built[j].Row.Name
	})
	for _, br := range built {
		t.Rows = append(t.Rows, br.Row)
	}
	if len(b.colErrs) > 0 {
		t.ColumnErrors = b.colErrs
	}
	return t, built
}

// ---- handlers --------------------------------------------------------------

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	reason := s.readOnlyReason()
	out := map[string]any{"ok": true, "readOnly": reason != "", "readOnlyReason": reason, "kubeconfig": s.mgr.Kubeconfig(), "connected": false}
	if c := s.mgr.Clients(); c != nil {
		out["context"], out["host"], out["connected"] = c.Context, c.RESTConfig.Host, true
	} else {
		out["error"] = s.mgr.Err().Error()
	}
	httpx.WriteJSON(w, 200, out)
}

func (s *Server) handleContexts(w http.ResponseWriter, r *http.Request) {
	current, ctxs, err := s.mgr.Contexts()
	if err != nil {
		writeErr(w, err)
		return
	}
	// Contexts that are read-only, and why ("flag", "context" or "auto").
	readOnly := map[string]string{}
	for _, c := range ctxs {
		reason := contextReadOnlyReason(s.settings, c.Name)
		if s.readOnly {
			reason = readOnlyFlag
		}
		if reason != "" {
			readOnly[c.Name] = reason
		}
	}
	httpx.WriteJSON(w, 200, map[string]any{"current": current, "contexts": ctxs, "readOnly": readOnly})
}

func (s *Server) handleSwitchContext(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
		writeErr(w, httpx.BadRequest("body must be {\"name\": \"<context>\"}"))
		return
	}
	if err := s.mgr.SwitchContext(body.Name); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if err := s.settings.SetLastContext(s.mgr.Kubeconfig(), body.Name); err != nil {
		log.Printf("save settings: %v", err)
	}
	s.handleContexts(w, r)
}

// handleProbe runs one connection step for the current context before the
// UI starts discovery: step=reach (is anything answering at the server
// address? short deadline, no credentials) or step=auth (do the credentials
// work? runs the exec plugin, which may wait for a browser login).
func (s *Server) handleProbe(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	start := time.Now()
	var err error
	switch step := r.URL.Query().Get("step"); step {
	case "reach":
		err = c.ProbeReach(r.Context())
	case "auth":
		err = c.ProbeAuth(r.Context())
	default:
		writeErr(w, httpx.BadRequest("step must be reach or auth"))
		return
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"ok": true, "host": c.RESTConfig.Host, "ms": time.Since(start).Milliseconds()})
}

// namespacesTimeout bounds the namespace list at startup: a server that
// accepted the connection but never answers must not hang the UI.
const namespacesTimeout = 30 * time.Second

func (s *Server) handleResources(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	types, err := c.Resources(r.Context(), r.URL.Query().Get("refresh") == "true")
	if err != nil {
		writeErr(w, discoveryErr(err))
		return
	}
	httpx.WriteJSON(w, 200, types)
}

func (s *Server) handleNamespaces(w http.ResponseWriter, r *http.Request) {
	c := s.mgr.Clients()
	if allowed := s.allowedNamespaces(); len(allowed) > 0 {
		// The allowlist stands in for the cluster's list (which a tenant
		// usually may not read).
		httpx.WriteJSON(w, 200, map[string]any{"namespaces": allowed, "default": c.Namespace, "listed": true, "restricted": true})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), namespacesTimeout)
	defer cancel()
	list, err := c.Typed.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		// Users without cluster-wide namespace list still get their
		// default (if the kubeconfig has one); the UI lets them type more.
		if apierrors.IsForbidden(err) {
			names := []string{}
			if c.Namespace != "" {
				names = append(names, c.Namespace)
			}
			httpx.WriteJSON(w, 200, map[string]any{"namespaces": names, "default": c.Namespace, "listed": false})
			return
		}
		writeErr(w, err)
		return
	}
	names := make([]string, 0, len(list.Items))
	for _, n := range list.Items {
		names = append(names, n.Name)
	}
	sort.Strings(names)
	httpx.WriteJSON(w, 200, map[string]any{"namespaces": names, "default": c.Namespace, "listed": true})
}

func (s *Server) handleTable(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	// Served from a warm shared watch when one exists (e.g. the table is
	// open), else listed directly.
	snap, err := s.snapshot(r.Context(), c, rq)
	if err != nil {
		writeErr(w, err)
		return
	}
	cols, isDefault := s.tableColumns(r.Context(), c, rq)
	b := newTableBuilder(cols, r.URL.Query().Get("includeObject") == "true")
	b.decorate = s.usageDecorator(r.Context(), c, rq)
	b.memo = snap.memo
	t, _ := b.tableOf(rq.Type, isDefault, snap.items, snap.rv)
	t.PartialErrors = snap.partial
	httpx.WriteJSON(w, 200, t)
}

// handleItems returns raw objects — for panels that need related resources
// (e.g. pods matching a deployment's selector).
func (s *Server) handleItems(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	snap, err := s.snapshot(r.Context(), c, rq)
	if err != nil {
		writeErr(w, err)
		return
	}
	items := make([]map[string]any, 0, len(snap.items))
	for _, it := range snap.items {
		items = append(items, it.Object)
	}
	out := map[string]any{"resource": rq.Type, "resourceVersion": snap.rv, "items": items}
	if len(snap.partial) > 0 {
		out["partialErrors"] = snap.partial
	}
	httpx.WriteJSON(w, 200, out)
}

func (s *Server) handleObject(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		writeErr(w, httpx.BadRequest("name is required"))
		return
	}
	sub, err := subresourceParam(r, rq.Type)
	if err != nil {
		writeErr(w, err)
		return
	}
	obj, err := rq.client(c).Get(r.Context(), name, metav1.GetOptions{}, sub...)
	if err != nil {
		writeErr(w, err)
		return
	}
	if r.URL.Query().Get("format") == "yaml" {
		u := obj.DeepCopy()
		if r.URL.Query().Get("managedFields") != "true" {
			u.SetManagedFields(nil)
		}
		b, err := yaml.Marshal(u.Object)
		if err != nil {
			writeErr(w, err)
			return
		}
		w.Header().Set("Content-Type", "application/yaml")
		_, _ = w.Write(b)
		return
	}
	httpx.WriteJSON(w, 200, obj.Object)
}

// handleEvents returns core/v1 events for an involved object (by uid, or
// kind+name) sorted newest first.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var sel []string
	if uid := q.Get("uid"); uid != "" {
		sel = append(sel, "involvedObject.uid="+uid)
	}
	if kind := q.Get("kind"); kind != "" {
		sel = append(sel, "involvedObject.kind="+kind)
	}
	if name := q.Get("name"); name != "" {
		sel = append(sel, "involvedObject.name="+name)
	}
	c := s.mgr.Clients()
	list, err := c.Typed.CoreV1().Events(q.Get("namespace")).List(r.Context(), metav1.ListOptions{FieldSelector: strings.Join(sel, ",")})
	if err != nil {
		writeErr(w, err)
		return
	}
	items := list.Items
	last := func(i int) time.Time {
		e := items[i]
		switch {
		case !e.LastTimestamp.IsZero():
			return e.LastTimestamp.Time
		case !e.EventTime.IsZero():
			return e.EventTime.Time
		default:
			return e.CreationTimestamp.Time
		}
	}
	sort.SliceStable(items, func(i, j int) bool { return last(i).After(last(j)) })
	httpx.WriteJSON(w, 200, map[string]any{"items": items})
}

func (s *Server) handleGetColumns(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	cols, isDefault := s.columnsFor(r.Context(), c, rq.Type)
	defaults := columns.Defaults(rq.Type, c.PrinterColumns(r.Context(), rq.Type.GVR()))
	httpx.WriteJSON(w, 200, map[string]any{"columns": cols, "isDefault": isDefault, "defaults": defaults})
}

func (s *Server) handlePutColumns(w http.ResponseWriter, r *http.Request) {
	_, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	body, ok := httpx.DecodeJSON[columnsBody](w, r, 0)
	if !ok {
		return
	}
	if err := s.store.Set(columns.Key(rq.Type.Group, rq.Type.Resource), body.Columns); err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	httpx.WriteJSON(w, 200, map[string]any{"columns": body.Columns, "isDefault": false})
}

func (s *Server) handleDeleteColumns(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	if err := s.store.Delete(columns.Key(rq.Type.Group, rq.Type.Resource)); err != nil {
		writeErr(w, err)
		return
	}
	cols, _ := s.columnsFor(r.Context(), c, rq.Type)
	httpx.WriteJSON(w, 200, map[string]any{"columns": cols, "isDefault": true})
}

// columnsBody is the body of the column-configuration endpoints.
type columnsBody struct {
	Columns []columns.Column `json:"columns"`
}

// handlePreviewColumns evaluates an unsaved column set against live objects
// so the column editor can show results and errors as the user types.
func (s *Server) handlePreviewColumns(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	body, ok := httpx.DecodeJSON[columnsBody](w, r, 0)
	if !ok {
		return
	}
	limit := int64(25)
	if l, err := strconv.ParseInt(r.URL.Query().Get("limit"), 10, 64); err == nil && l > 0 {
		limit = l
	}
	opts := rq.listOptions()
	opts.Limit = limit
	list, err := rq.client(c).List(r.Context(), opts)
	if err != nil {
		writeErr(w, err)
		return
	}
	b := newTableBuilder(body.Columns, false)
	b.decorate = s.usageDecorator(r.Context(), c, rq)
	httpx.WriteJSON(w, 200, b.table(rq.Type, false, list))
}
