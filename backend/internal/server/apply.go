package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/restmapper"
	"sigs.k8s.io/yaml"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
)

func (s *Server) applyRoutes() {
	s.mux.HandleFunc("POST /api/apply", s.handleApply)
}

// applyResult is the outcome for one document of an apply request.
type applyResult struct {
	// Index is the document's position (0-based) and Line its first line
	// (1-based) in the request body, so the UI can point at it.
	Index     int    `json:"index"`
	Line      int    `json:"line"`
	Group     string `json:"group"`
	Version   string `json:"version"`
	Kind      string `json:"kind"`
	Namespace string `json:"namespace,omitempty"`
	Name      string `json:"name"`
	Created   bool   `json:"created"`
	Error     string `json:"error,omitempty"`
	// Reason is the Kubernetes StatusReason (AlreadyExists, Invalid, …).
	Reason string              `json:"reason,omitempty"`
	Causes []map[string]string `json:"causes,omitempty"`
}

// handleApply creates the objects in a YAML/JSON body of one or more
// documents (`---`), in order, like `kubectl create -f`. Kinds resolve
// through discovery, so CRs work too. Namespaced objects without a
// namespace go to ?namespace= (else the context's default). Each document
// gets its own result; one failing doesn't stop the rest.
//
// ?mode=apply uses server-side apply instead (fieldManager k8sman, no
// force), which also updates existing objects: fields another manager
// owns come back as a Conflict rather than being taken over.
// ?dryRun=true persists nothing.
func (s *Server) handleApply(w http.ResponseWriter, r *http.Request) {
	if s.isReadOnly() {
		httpx.WriteJSON(w, http.StatusForbidden, httpx.ErrorBody{Error: s.readOnlyMessage(), Code: http.StatusForbidden})
		return
	}
	q := r.URL.Query()
	mode := q.Get("mode")
	if mode == "" {
		mode = "create"
	}
	if mode != "create" && mode != "apply" {
		writeErr(w, httpx.BadRequest("mode must be create or apply"))
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
	if err != nil {
		writeErr(w, httpx.BadRequest("read body: %v", err))
		return
	}
	docs := splitYAMLDocs(body)
	if len(docs) == 0 {
		writeErr(w, httpx.BadRequest("nothing to apply: the body has no documents"))
		return
	}
	c := s.mgr.Clients()
	defaultNS := q.Get("namespace")
	if defaultNS == "" {
		defaultNS = c.Namespace
	}
	if defaultNS == "" {
		defaultNS = metav1.NamespaceDefault
	}
	a := applier{c: c, mapper: restmapper.NewDeferredDiscoveryRESTMapper(c.Discovery), dryRun: q.Get("dryRun") == "true", serverSide: mode == "apply", defaultNS: defaultNS}
	results := []applyResult{}
	for i, d := range docs {
		for _, obj := range d.objects() {
			res := a.apply(r.Context(), obj.u, obj.err)
			res.Index, res.Line = i, d.line
			results = append(results, res)
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"dryRun": a.dryRun, "mode": mode, "context": c.Context, "results": results})
}

type applier struct {
	c          *cluster.Clients
	mapper     meta.ResettableRESTMapper
	dryRun     bool
	serverSide bool
	defaultNS  string
}

func (a *applier) apply(ctx context.Context, obj *unstructured.Unstructured, parseErr error) applyResult {
	if parseErr != nil {
		return applyResult{Error: parseErr.Error(), Reason: "BadRequest"}
	}
	gvk := obj.GroupVersionKind()
	res := applyResult{Group: gvk.Group, Version: gvk.Version, Kind: gvk.Kind, Name: obj.GetName(), Namespace: obj.GetNamespace()}
	fail := func(err error) applyResult {
		res.Error, res.Causes = err.Error(), statusCauses(err)
		var se apierrors.APIStatus
		if errors.As(err, &se) {
			res.Reason = string(se.Status().Reason)
		}
		return res
	}
	switch {
	case gvk.Kind == "" || gvk.Version == "":
		return fail(httpx.BadRequest("apiVersion and kind are required"))
	case obj.GetName() == "" && (a.serverSide || obj.GetGenerateName() == ""):
		return fail(httpx.BadRequest("metadata.name is required"))
	}
	m, err := a.mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
	if meta.IsNoMatchError(err) {
		a.mapper.Reset() // maybe a CRD installed since discovery was cached
		m, err = a.mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
	}
	if err != nil {
		return fail(fmt.Errorf("%s %s isn't served by this cluster: %w", gvk.GroupVersion(), gvk.Kind, err))
	}
	ri := a.c.Dynamic.Resource(m.Resource)
	client := ri.Namespace("")
	if m.Scope.Name() == meta.RESTScopeNameNamespace {
		if obj.GetNamespace() == "" {
			obj.SetNamespace(a.defaultNS)
		}
		client = ri.Namespace(obj.GetNamespace())
	} else {
		obj.SetNamespace("")
	}
	res.Namespace = obj.GetNamespace()
	var dr []string
	if a.dryRun {
		dr = []string{metav1.DryRunAll}
	}
	var out *unstructured.Unstructured
	if a.serverSide {
		_, gerr := client.Get(ctx, obj.GetName(), metav1.GetOptions{})
		if gerr != nil && !apierrors.IsNotFound(gerr) {
			return fail(gerr)
		}
		res.Created = apierrors.IsNotFound(gerr)
		obj.SetResourceVersion("")
		obj.SetManagedFields(nil)
		js, merr := json.Marshal(obj.Object)
		if merr != nil {
			return fail(merr)
		}
		force := false
		out, err = client.Patch(ctx, obj.GetName(), types.ApplyPatchType, js, metav1.PatchOptions{FieldManager: fieldManager, Force: &force, DryRun: dr})
	} else {
		obj.SetResourceVersion("")
		out, err = client.Create(ctx, obj, metav1.CreateOptions{FieldManager: fieldManager, DryRun: dr})
		res.Created = err == nil
	}
	if err != nil {
		res.Created = false
		return fail(err)
	}
	res.Name = out.GetName()
	return res
}

// yamlDoc is one `---`-separated document and the line it starts on.
type yamlDoc struct {
	text string
	line int
}

type parsedObject struct {
	u   *unstructured.Unstructured
	err error
}

// objects parses the document; a v1 List expands to its items.
func (d yamlDoc) objects() []parsedObject {
	js, err := yaml.YAMLToJSON([]byte(d.text))
	if err != nil {
		return []parsedObject{{err: fmt.Errorf("invalid YAML: %v", err)}}
	}
	u := &unstructured.Unstructured{}
	if err := u.UnmarshalJSON(js); err != nil {
		return []parsedObject{{err: fmt.Errorf("invalid object: %v", err)}}
	}
	if u.GetKind() != "List" || !strings.HasSuffix(u.GetAPIVersion(), "v1") {
		return []parsedObject{{u: u}}
	}
	items, _, _ := unstructured.NestedSlice(u.Object, "items")
	var out []parsedObject
	for _, it := range items {
		m, ok := it.(map[string]any)
		if !ok {
			out = append(out, parsedObject{err: errors.New("invalid List item")})
			continue
		}
		out = append(out, parsedObject{u: &unstructured.Unstructured{Object: m}})
	}
	return out
}

var docSeparator = regexp.MustCompile(`^---(\s.*)?$`)

// splitYAMLDocs splits a multi-document body on `---` lines, dropping
// documents that are empty or only comments. A JSON body is one document.
func splitYAMLDocs(body []byte) []yamlDoc {
	var docs []yamlDoc
	var cur strings.Builder
	start, n, content := 1, 0, false
	flush := func(next int) {
		if content {
			docs = append(docs, yamlDoc{text: cur.String(), line: start})
		}
		cur.Reset()
		start, content = next, false
	}
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 64<<10), len(body)+1)
	for sc.Scan() {
		n++
		line := strings.TrimRight(sc.Text(), " \t\r")
		if docSeparator.MatchString(line) {
			flush(n + 1)
			continue
		}
		if line == "..." {
			continue
		}
		if t := strings.TrimSpace(line); t != "" && !strings.HasPrefix(t, "#") {
			if !content {
				start = n // point at the first real line, past leading comments
			}
			content = true
		}
		cur.WriteString(sc.Text())
		cur.WriteByte('\n')
	}
	flush(0)
	return docs
}
