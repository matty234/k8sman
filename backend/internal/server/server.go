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
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/argoapi"
	"github.com/matty234/k8sman/backend/internal/argowf"
	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/columns"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/icons"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/metrics"
	"github.com/matty234/k8sman/backend/internal/portforward"
	"github.com/matty234/k8sman/backend/internal/prom"
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
	argowf   *argowf.Handler
	token    string
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
	s.actionRoutes()
	s.overviewRoutes()
	s.kubeconfigRoutes()
	s.execRoutes()
	s.helmRoutes()
	s.securityRoutes()
	s.gpuRoutes()
	s.rbacRoutes()
	prom.Register(s.mux, mgr, opts.ReadOnly)
	argoapi.Register(s.mux, mgr, s.settings)
	s.argowf = argowf.Register(s.mux, mgr)
	metrics.Register(s.mux, mgr)
	s.iconRoutes(opts)
	return s
}

// worksDisconnected lists endpoints that don't need an active context, so
// the UI can still pick a kubeconfig when none could be loaded.
func worksDisconnected(path string) bool {
	return path == "/api/health" || path == "/api/contexts" ||
		strings.HasPrefix(path, "/api/kubeconfigs") || strings.HasPrefix(path, "/api/portforwards")
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /api/health", s.handleHealth)
	s.mux.HandleFunc("GET /api/contexts", s.handleContexts)
	s.mux.HandleFunc("POST /api/contexts/current", s.handleSwitchContext)
	s.mux.HandleFunc("GET /api/resources", s.handleResources)
	s.mux.HandleFunc("GET /api/namespaces", s.handleNamespaces)
	s.mux.HandleFunc("GET /api/table", s.handleTable)
	s.mux.HandleFunc("GET /api/items", s.handleItems)
	s.mux.HandleFunc("GET /api/object", s.handleObject)
	s.mux.HandleFunc("GET /api/events", s.handleEvents)
	s.mux.HandleFunc("GET /api/columns", s.handleGetColumns)
	s.mux.HandleFunc("PUT /api/columns", s.handlePutColumns)
	s.mux.HandleFunc("DELETE /api/columns", s.handleDeleteColumns)
	s.mux.HandleFunc("POST /api/columns/preview", s.handlePreviewColumns)
	s.mux.HandleFunc("GET /api/watch", s.handleWatch)
	s.mux.HandleFunc("GET /api/logs", s.handleLogs)
}

// ServeHTTP checks Host, Origin, the bearer token and Content-Type
// (guard.go), then routes and logs.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !checkAccess(w, r, s.token) {
		return
	}
	start := time.Now()
	if s.mgr.Clients() == nil && !worksDisconnected(r.URL.Path) {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, apiError{
			Error:  fmt.Sprintf("no cluster connection: %v", s.mgr.Err()),
			Code:   http.StatusServiceUnavailable,
			Reason: "NoKubeconfig",
		})
		return
	}
	s.mux.ServeHTTP(w, r)
	if r.URL.Path != "/api/health" {
		log.Printf("%s %s (%s)", r.Method, r.URL.RequestURI(), time.Since(start).Round(time.Millisecond))
	}
}

// ---- helpers ---------------------------------------------------------------

type apiError struct {
	Error string `json:"error"`
	Code  int    `json:"code"`
	// Reason is the Kubernetes StatusReason (e.g. Conflict, Invalid).
	Reason string              `json:"reason,omitempty"`
	Causes []map[string]string `json:"causes,omitempty"`
}

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
	httpx.WriteJSON(w, status, apiError{Error: err.Error(), Code: status, Reason: reason, Causes: statusCauses(err)})
}

// resourceQuery is the common ?group=&version=&resource=&namespace= target.
type resourceQuery struct {
	Type          cluster.ResourceType
	Namespace     string
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
	return c, resourceQuery{
		Type:          rt,
		Namespace:     q.Get("namespace"),
		LabelSelector: q.Get("labelSelector"),
		FieldSelector: q.Get("fieldSelector"),
	}, nil
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
}

// snapshot answers from a warm shared watch, else with a direct LIST (a
// one-off read shouldn't start a watch).
func (s *Server) snapshot(ctx context.Context, c *cluster.Clients, rq resourceQuery) (listing, error) {
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

func (rq resourceQuery) listOptions() metav1.ListOptions {
	return metav1.ListOptions{LabelSelector: rq.LabelSelector, FieldSelector: rq.FieldSelector}
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
	out := map[string]any{"ok": true, "readOnly": s.readOnly, "kubeconfig": s.mgr.Kubeconfig(), "connected": false}
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
	httpx.WriteJSON(w, 200, map[string]any{"current": current, "contexts": ctxs})
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
	list, err := c.Typed.CoreV1().Namespaces().List(r.Context(), metav1.ListOptions{})
	if err != nil {
		// Users without cluster-wide namespace list still get their default.
		if apierrors.IsForbidden(err) && c.Namespace != "" {
			httpx.WriteJSON(w, 200, map[string]any{"namespaces": []string{c.Namespace}, "default": c.Namespace})
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
	httpx.WriteJSON(w, 200, map[string]any{"namespaces": names, "default": c.Namespace})
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
	cols, isDefault := s.columnsFor(r.Context(), c, rq.Type)
	b := newTableBuilder(cols, r.URL.Query().Get("includeObject") == "true")
	b.decorate = s.usageDecorator(r.Context(), c, rq)
	b.memo = snap.memo
	t, _ := b.tableOf(rq.Type, isDefault, snap.items, snap.rv)
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
	httpx.WriteJSON(w, 200, map[string]any{"resource": rq.Type, "resourceVersion": snap.rv, "items": items})
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
	obj, err := rq.client(c).Get(r.Context(), name, metav1.GetOptions{})
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
	var body struct {
		Columns []columns.Column `json:"columns"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("invalid body: %v", err))
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

// handlePreviewColumns evaluates an unsaved column set against live objects
// so the column editor can show results and errors as the user types.
func (s *Server) handlePreviewColumns(w http.ResponseWriter, r *http.Request) {
	c, rq, err := s.parseResource(r.Context(), r)
	if err != nil {
		writeErr(w, err)
		return
	}
	var body struct {
		Columns []columns.Column `json:"columns"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, httpx.BadRequest("invalid body: %v", err))
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
