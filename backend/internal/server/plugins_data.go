package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/overview"
	"github.com/matty234/k8sman/backend/internal/plugins"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// What plugins read and change beyond their object (docs/PLUGINS.md §6):
//
//   - related objects, through pluginLookup: only kinds in the plugin's
//     permissions.read (the loader checks), from the shared watch cache;
//   - metrics, through the Prometheus module's QueryVector, cached 15 s
//     per query, and only while that module is on;
//   - patch, subresource and create actions, through
//     POST /api/actions/plugin.<id>.<action> (handleAction: read-only
//     refusal, availability, dry-run), never on Secrets;
//   - alerts, as an overview source over the overview's own lists.

// pluginEnv is the evaluation environment for c.
func (s *Server) pluginEnv(c *cluster.Clients) plugins.Env {
	return plugins.Env{Context: c.Context, Lookup: &pluginLookup{s: s, c: c}}
}

// typeForKey resolves kind key group/Kind (pinned to version when set)
// through the cached discovery.
func (s *Server) typeForKey(ctx context.Context, c *cluster.Clients, key, version string) (cluster.ResourceType, bool) {
	all, err := c.Resources(ctx, false)
	if err != nil {
		return cluster.ResourceType{}, false
	}
	group, kind, _ := strings.Cut(key, "/")
	for _, t := range all {
		if t.Group == group && t.Kind == kind && (version == "" || t.Version == version) {
			return t, true
		}
	}
	return cluster.ResourceType{}, false
}

// pluginLookup serves related objects and metrics for one context.
type pluginLookup struct {
	s *Server
	c *cluster.Clients
}

func (l *pluginLookup) List(ctx context.Context, kindKey, ns, labelSelector, name string) ([]map[string]any, error) {
	rt, ok := l.s.typeForKey(ctx, l.c, kindKey, "")
	if !ok {
		return nil, plugins.ErrNotServed
	}
	if !rt.Namespaced {
		ns = ""
	}
	// Plugins see a Secret's key names, never its values, so Secrets come
	// from a lean stream (summaries, see kcache.Key.Lean). Other heavy kinds
	// (ConfigMaps, CRDs) are read in full: a plugin may read their bodies.
	lean := rt.GVR().GroupResource() == kcache.SecretsGVR.GroupResource()
	key := kcache.Key{GVR: rt.GVR(), Namespace: ns, LabelSelector: labelSelector, Lean: lean}
	if name != "" {
		key.FieldSelector = "metadata.name=" + name
	}
	snap, err := kcache.For(l.c).List(ctx, key)
	if err != nil {
		if apierrors.IsForbidden(err) {
			where := ""
			if ns != "" {
				where = " in " + ns
			}
			return nil, fmt.Errorf("not allowed to list %s%s", rt.Resource, where)
		}
		return nil, err
	}
	out := make([]map[string]any, len(snap.Items))
	for i, u := range snap.Items {
		out[i] = u.Object
	}
	return out, nil
}

func (l *pluginLookup) Query(ctx context.Context, instance, query string) ([]plugins.Sample, error) {
	if l.s.settings.ModuleDisabled("prometheus") {
		return nil, plugins.ErrNoPrometheus
	}
	return l.s.pluginMetrics.query(ctx, l.c, instance, query)
}

// pluginMetricTTL is how long a plugin metric query's answer is reused.
const pluginMetricTTL = 15 * time.Second

// pluginMetricCache keeps plugin metric answers (and errors) per context,
// instance and query string.
type pluginMetricCache struct {
	mu sync.Mutex
	m  map[string]pluginMetric
}

type pluginMetric struct {
	at      time.Time
	samples []plugins.Sample
	err     error
}

func (mc *pluginMetricCache) query(ctx context.Context, c *cluster.Clients, instance, query string) ([]plugins.Sample, error) {
	key := fmt.Sprintf("%p|%s|%s", c, instance, query)
	mc.mu.Lock()
	if e, ok := mc.m[key]; ok && time.Since(e.at) < pluginMetricTTL {
		mc.mu.Unlock()
		return e.samples, e.err
	}
	mc.mu.Unlock()
	vec, _, err := prom.QueryVectorAt(ctx, c, instance, query)
	var ue *prom.UpstreamError
	if errors.As(err, &ue) && ue.NoInstance {
		err = plugins.ErrNoPrometheus
	}
	samples := make([]plugins.Sample, len(vec))
	for i, v := range vec {
		samples[i] = plugins.Sample{Labels: v.Metric, Value: v.Value}
	}
	mc.mu.Lock()
	if mc.m == nil {
		mc.m = map[string]pluginMetric{}
	}
	for k, e := range mc.m {
		if time.Since(e.at) >= pluginMetricTTL {
			delete(mc.m, k)
		}
	}
	mc.m[key] = pluginMetric{at: time.Now(), samples: samples, err: err}
	mc.mu.Unlock()
	return samples, err
}

// ---- write actions -----------------------------------------------------------

// ActionPreview is a dry run's change, shown in a plugin write action's
// confirmation. PatchType says which sort:
//
//   - merge or json: a patch; Patch is it, Before and After the object
//     around it (YAML, without managedFields and the like);
//   - subresource: a subresource call, which has no dry run, so it is
//     only described: Patch is {method, path, body};
//   - create: Patch is the object sent, After the object the API server
//     would create (Before is empty).
type ActionPreview struct {
	PatchType string          `json:"patchType"`
	Patch     json.RawMessage `json:"patch"`
	Before    string          `json:"before"`
	After     string          `json:"after"`
}

// ActionTargets implements ActionSource: every patch, subresource and
// create action of the active plugins, on its kind ("kind:group/Kind").
func (m *pluginsModule) ActionTargets() map[string][]string {
	if !m.s.pluginsOn() {
		return nil
	}
	out := map[string][]string{}
	for name, keys := range m.s.plugins.WriteTargets() {
		for _, k := range keys {
			out[name] = append(out[name], "kind:"+k)
		}
	}
	return out
}

// RunAction implements ActionSource: a plugin's patch, subresource or
// create action. The body is {"inputs": {name: value}, "dryRun"}. The
// plugin builds the request from the object as it is now and the inputs
// (checked here, not by the UI).
func (m *pluginsModule) RunAction(a ActionCall) (ActionResult, error) {
	s := m.s
	pluginID, actionID, ok := plugins.SplitActionName(a.Action)
	if !ok || !s.pluginsOn() {
		return ActionResult{}, httpx.BadRequest("action %q isn't available", a.Action)
	}
	if plugins.KindKey(a.Type) == "/Secret" {
		return ActionResult{}, httpx.BadRequest("plugins can't change Secrets")
	}
	var body struct {
		Inputs map[string]any `json:"inputs"`
	}
	if err := decodeActionBody(a.Body, &body); err != nil {
		return ActionResult{}, err
	}
	before, err := a.Resource.Get(a.Ctx, a.Name, metav1.GetOptions{})
	if err != nil {
		return ActionResult{}, err
	}
	ch, err := s.plugins.BuildAction(s.pluginEnv(a.Clients), a.Type, before.Object, pluginID, actionID, body.Inputs)
	if err != nil {
		return ActionResult{}, httpx.BadRequest("%v", err)
	}
	res := ActionResult{Message: ch.Label + ": " + a.Name, DryRun: a.DryRun, Context: a.Clients.Context}
	switch ch.Kind {
	case "subresource":
		return runSubresource(a, ch, res)
	case "create":
		return s.runCreate(a, ch, before, res)
	}
	pt := types.MergePatchType
	if ch.PatchType == "json" {
		pt = types.JSONPatchType
	}
	after, err := a.Resource.Patch(a.Ctx, a.Name, pt, ch.Body, metav1.PatchOptions{FieldManager: fieldManager, DryRun: a.DryRunOpt})
	if err != nil {
		return ActionResult{}, err
	}
	if a.DryRun {
		res.Preview = &ActionPreview{PatchType: ch.PatchType, Patch: ch.Body, Before: previewYAML(before), After: previewYAML(after)}
	}
	return res, nil
}

// subresourcePath is the URL path of subresource sub of object name, of
// type rt in namespace ns, served by group/version.
func subresourcePath(group, version string, rt cluster.ResourceType, ns, name, sub string) string {
	p := "/apis/" + group + "/" + version
	if group == "" {
		p = "/api/" + version
	}
	if rt.Namespaced {
		p += "/namespaces/" + url.PathEscape(ns)
	}
	return p + "/" + rt.Resource + "/" + url.PathEscape(name) + "/" + sub
}

// runSubresource calls a subresource with the user's credentials.
// Subresource writes generally have no dry run, so a dry run describes
// the request instead of sending it.
func runSubresource(a ActionCall, ch *plugins.Change, res ActionResult) (ActionResult, error) {
	path := subresourcePath(ch.Group, ch.Version, a.Type, a.Namespace, a.Name, ch.Subresource)
	if a.DryRun {
		req, err := json.Marshal(map[string]any{"method": ch.Method, "path": path, "body": json.RawMessage(ch.Body)})
		if err != nil {
			return ActionResult{}, err
		}
		res.Message += " (not sent: subresource calls have no dry run)"
		res.Preview = &ActionPreview{PatchType: "subresource", Patch: req}
		return res, nil
	}
	rc, ok := a.Clients.Typed.Discovery().RESTClient().(*rest.RESTClient)
	if !ok || rc == nil {
		return ActionResult{}, fmt.Errorf("no REST client for %s", a.Clients.Context)
	}
	err := rc.Verb(ch.Method).AbsPath(path).SetHeader("Content-Type", "application/json").Body(ch.Body).Do(a.Ctx).Error()
	return res, err
}

// runCreate creates a create action's object, in the object's namespace
// when its kind is namespaced (none when it is cluster-scoped).
func (s *Server) runCreate(a ActionCall, ch *plugins.Change, before *unstructured.Unstructured, res ActionResult) (ActionResult, error) {
	obj := runtime.DeepCopyJSON(ch.Object)
	gv, err := schema.ParseGroupVersion(fmt.Sprint(obj["apiVersion"]))
	if err != nil {
		return ActionResult{}, httpx.BadRequest("apiVersion: %v", err)
	}
	kind := fmt.Sprint(obj["kind"])
	rt, ok := s.typeForKey(a.Ctx, a.Clients, gv.Group+"/"+kind, gv.Version)
	if !ok {
		return ActionResult{}, httpx.BadRequest("the cluster doesn't serve %s %s", gv, kind)
	}
	if !slices.Contains(rt.Verbs, "create") {
		return ActionResult{}, httpx.BadRequest("%s can't be created", kind)
	}
	md, _ := obj["metadata"].(map[string]any)
	ns := ""
	if rt.Namespaced {
		if ns = before.GetNamespace(); ns == "" {
			return ActionResult{}, httpx.BadRequest("%s is namespaced and %s isn't: there is no namespace to create it in", kind, a.Name)
		}
		md["namespace"] = ns
	} else {
		delete(md, "namespace")
	}
	var ri dynamic.ResourceInterface = a.Clients.Dynamic.Resource(rt.GVR())
	if ns != "" {
		ri = a.Clients.Dynamic.Resource(rt.GVR()).Namespace(ns)
	}
	created, err := ri.Create(a.Ctx, &unstructured.Unstructured{Object: obj}, metav1.CreateOptions{FieldManager: fieldManager, DryRun: a.DryRunOpt})
	if err != nil {
		return ActionResult{}, err
	}
	res.Message = fmt.Sprintf("%s: created %s %s", ch.Label, kind, created.GetName())
	if a.DryRun {
		res.Preview = &ActionPreview{PatchType: "create", Patch: ch.Body, After: previewYAML(created)}
	} else {
		res.Created = &ObjectRefJSON{Group: gv.Group, Kind: kind, Name: created.GetName(), Namespace: ns}
	}
	return res, nil
}

// previewYAML is obj as YAML without the fields every write changes.
func previewYAML(u *unstructured.Unstructured) string {
	if u == nil {
		return ""
	}
	obj := runtime.DeepCopyJSON(u.Object)
	if md, ok := obj["metadata"].(map[string]any); ok {
		for _, k := range []string{"managedFields", "resourceVersion", "generation"} {
			delete(md, k)
		}
	}
	b, err := yaml.Marshal(obj)
	if err != nil {
		return ""
	}
	return string(b)
}

// ---- alerts and status lines ---------------------------------------------------

// pluginLister lists a kind's objects in scope ns ("" = every namespace)
// from the watch cache, for alerts and status lines.
func (s *Server) pluginLister(ctx context.Context, c *cluster.Clients, scope string) plugins.AlertLister {
	kc := kcache.For(c)
	return func(key, version string) ([]map[string]any, error) {
		rt, ok := s.typeForKey(ctx, c, key, version)
		if !ok {
			return nil, plugins.ErrNotServed
		}
		ns := scope
		if !rt.Namespaced {
			ns = ""
		}
		items, err := listCached(ctx, kc, rt.GVR(), ns)
		if err != nil {
			return nil, err
		}
		out := make([]map[string]any, len(items))
		for i, u := range items {
			out[i] = u.Object
		}
		return out, nil
	}
}

// handlePluginStatus answers the active plugins' status lines (their rows
// in Settings ▸ Integrations), over every namespace: {plugins: {id:
// StatusOut}}. A plugin without a status line, or whose kinds the cluster
// doesn't serve, is absent.
func (s *Server) handlePluginStatus(w http.ResponseWriter, r *http.Request) {
	out := map[string]plugins.StatusOut{}
	if c := s.mgr.Clients(); c != nil && s.pluginsOn() {
		out = s.plugins.Status(plugins.Env{Context: c.Context}, s.pluginLister(r.Context(), c, ""))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"plugins": out})
}

// handlePluginTemplates is GET /api/plugins/templates?kind=group/Kind: the
// active plugins' templates for the create editor (every kind without
// kind). Text only, so it needs no cluster.
func (s *Server) handlePluginTemplates(w http.ResponseWriter, r *http.Request) {
	out := []plugins.TemplateOut{}
	if s.pluginsOn() {
		out = s.plugins.Templates(r.URL.Query().Get("kind"))
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"templates": out})
}

// OverviewInputs implements OverviewSource: the active plugins' alerts
// over their kinds' objects in the overview's scope, from the watch cache.
func (m *pluginsModule) OverviewInputs(l *OverviewLists) {
	s := m.s
	if !s.pluginsOn() || !s.plugins.HasAlerts() {
		return
	}
	l.Go("plugins", func() (func(*overview.Input), error) {
		hits, errs := s.plugins.Alerts(plugins.Env{Context: l.Clients.Context}, s.pluginLister(l.Ctx, l.Clients, l.Namespace))
		fs := make([]overview.Finding, len(hits))
		for i, h := range hits {
			fs[i] = overview.Finding{
				Issue: overview.Issue{Severity: h.Severity, Category: h.Category, Kind: h.Kind, Group: h.Group,
					Namespace: h.Namespace, Name: h.Name, Reason: h.Label, Message: h.Message},
				Label: h.Label, Section: h.Section, Since: h.Since,
			}
		}
		return func(in *overview.Input) { in.Findings = append(slices.Clip(in.Findings), fs...) }, errors.Join(errs...)
	})
}

// ---- background shell actions -----------------------------------------------

// pluginRunTimeout bounds a background shell action.
const pluginRunTimeout = 2 * time.Minute

// pluginRunTail is how many lines of output a background run reports.
const pluginRunTail = 20

// handlePluginRun runs a background shell action (POST
// /api/plugins/run?plugin=&action=&group=&version=&resource=&namespace=&name=)
// and answers {argv, exitCode, output} with the last lines of its output.
// The same checks as a dock-tab run apply (pluginShellSpec): plugins on,
// not read-only, consent, the action offered for the object; the command
// comes from the loaded plugin, never from the request.
func (s *Server) handlePluginRun(w http.ResponseWriter, r *http.Request) {
	if s.refuseReadOnly(w) {
		return
	}
	contextName := ""
	if c := s.mgr.Clients(); c != nil {
		contextName = c.Context
	}
	home, _ := os.UserHomeDir()
	chain := kubeconfigChain(s.mgr.Kubeconfig(), os.Getenv("KUBECONFIG"), home)
	if contextName != "" {
		tmp, err := writeContextKubeconfig("", contextName)
		if err != nil {
			writeErr(w, fmt.Errorf("could not prepare the command's kubeconfig: %w", err))
			return
		}
		defer os.Remove(tmp)
		chain = tmp + string(os.PathListSeparator) + chain
	}
	spec := localShellSpec{Dir: home, Env: localShellEnv(os.Environ(), chain, contextName)}
	a, err := s.pluginShellSpec(r, &spec, chain)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	if a.Shell == nil || !a.Shell.Background {
		writeErr(w, httpx.BadRequest("%s runs in a terminal tab, not in the background", a.ID))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), pluginRunTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, spec.Shell, spec.Args...)
	cmd.Dir, cmd.Env = spec.Dir, spec.Env
	var out tailBuffer
	cmd.Stdout, cmd.Stderr = &out, &out
	runErr := cmd.Run()
	code := 0
	var exitErr *exec.ExitError
	switch {
	case errors.As(runErr, &exitErr):
		code = exitErr.ExitCode()
	case runErr != nil:
		writeErr(w, runErr)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"argv": append([]string{a.Shell.Command}, spec.Args...), "exitCode": code, "output": out.tail(pluginRunTail),
		"timedOut": ctx.Err() == context.DeadlineExceeded,
	})
}

// tailBuffer keeps the last 64 KiB written to it.
type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if over := len(t.buf) - 64<<10; over > 0 {
		t.buf = t.buf[over:]
	}
	return len(p), nil
}

// tail is the last n lines.
func (t *tailBuffer) tail(n int) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	lines := bytes.Split(bytes.TrimRight(t.buf, "\n"), []byte("\n"))
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return string(bytes.Join(lines, []byte("\n")))
}
