package kcache

import (
	"context"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/metadata"

	"github.com/matty234/k8sman/backend/internal/kapi"
)

// Metadata-first streams.
//
// A lean stream (Key.Lean) of a heavy kind (kapi.MetadataFirst: Secrets,
// ConfigMaps, CRDs) keeps a summary of each object instead of the object:
// its metadata and what the kind's default table columns read (a Secret's
// type and its keys with their sizes, a CRD without its schemas), never a
// Secret value. Its readers are tables without objects and plugin lookups
// of Secrets, which see key names only anyway.
//
// It loads in two steps so a table shows its rows at once:
//
//  1. a metadata-only LIST (PartialObjectMetadataList, a small fraction
//     of the bytes) becomes the first snapshot: stand-ins with just
//     metadata, marked pending (Pending), whose body-derived cells the UI
//     shows as pending;
//  2. a fill pages through the full objects (fillPage at a time, at most
//     maxFills streams at once, on the context's own rate limits; in
//     protobuf for Secrets and ConfigMaps, see proto.go),
//     summarises each page and pushes the rows as MODIFIED events, one
//     batch per page. Objects that went away meanwhile are DELETED at the
//     end. The fill is one consistent read, so the watch then starts from
//     its resourceVersion, with full objects summarised one per event.
//
// A re-list after an expired watch takes the same path. Snapshot readers
// (Cached, List, Warm) never see stand-ins: they wait for the fill, or LIST
// on their own. Full readers (the inspector, /api/items, the YAML view)
// never ride on a lean stream (see narrowing).
//
// The last-applied-configuration annotation, which holds a copy of the
// object (a Secret's values too), is dropped from stand-ins and summaries.

const (
	// fillPage is how many full objects one fill request reads.
	fillPage = 50
	// maxFills bounds the fills in flight across every context.
	maxFills = 4
	// pendingField marks a stand-in (see Pending).
	pendingField = "k8sman.pending"

	lastApplied = "kubectl.kubernetes.io/last-applied-configuration"
)

// fillSlots caps concurrent fills (and one-off summarised LISTs).
var fillSlots = make(chan struct{}, maxFills)

// SecretsGVR is core/v1 Secrets.
var SecretsGVR = kapi.Secrets.GVR()

// summarisers turn a full object of a heavy kind into its summary. Every
// kind in kapi.MetadataFirst has one (TestLeanSummaries checks).
var summarisers = map[schema.GroupResource]func(map[string]any) map[string]any{
	{Resource: "secrets"}:    summariseSecret,
	{Resource: "configmaps"}: summariseConfigMap,
	{Group: "apiextensions.k8s.io", Resource: "customresourcedefinitions"}: summariseCRD,
}

// heavy returns the summariser and kind of a metadata-first resource.
func heavy(gvr schema.GroupVersionResource) (func(map[string]any) map[string]any, string, bool) {
	for _, a := range kapi.MetadataFirst {
		if a.Group == gvr.Group && a.Resource == gvr.Resource {
			f, ok := summarisers[gvr.GroupResource()]
			return f, a.Kind, ok
		}
	}
	return nil, "", false
}

// MetadataFirst reports whether lean streams of gvr load metadata first
// and keep summaries.
func MetadataFirst(gvr schema.GroupVersionResource) bool {
	_, _, ok := heavy(gvr)
	return ok
}

// Pending reports whether u is a metadata-only stand-in whose body hasn't
// been read yet: only its metadata is real.
func Pending(u *unstructured.Unstructured) bool {
	p, _ := u.Object[pendingField].(bool)
	return p
}

// norm clears Lean for kinds without a lean form, so they share one stream.
func (k Key) norm() Key {
	if k.Lean && !MetadataFirst(k.GVR) {
		k.Lean = false
	}
	return k
}

// source is what a stream lists and watches.
type source interface {
	List(ctx context.Context, opts metav1.ListOptions) (*unstructured.UnstructuredList, error)
	Watch(ctx context.Context, opts metav1.ListOptions) (watch.Interface, error)
}

// source builds the list+watch source for key: always full objects.
func (c *Cache) source(key Key) source {
	if key.Namespace != "" {
		return c.dyn.Resource(key.GVR).Namespace(key.Namespace)
	}
	return c.dyn.Resource(key.GVR)
}

// metaSource is the metadata-only LIST for a lean key of a heavy kind, or
// nil (then the stream lists in full and summarises).
func (c *Cache) metaSource(key Key) metadata.ResourceInterface {
	if !key.Lean || c.meta == nil {
		return nil
	}
	if key.Namespace != "" {
		return c.meta.Resource(key.GVR).Namespace(key.Namespace)
	}
	return c.meta.Resource(key.GVR)
}

// summariserFor is the summariser of a lean key, nil for a full one.
func summariserFor(key Key) func(map[string]any) map[string]any {
	if !key.Lean {
		return nil
	}
	f, _, _ := heavy(key.GVR)
	return f
}

// ListOnce is one LIST for key, without starting a stream: for a lean key
// of a heavy kind the full objects are read page by page and only their
// summaries kept.
func (c *Cache) ListOnce(ctx context.Context, key Key) (*unstructured.UnstructuredList, error) {
	key = key.norm()
	opts := metav1.ListOptions{LabelSelector: key.LabelSelector, FieldSelector: key.FieldSelector}
	sum := summariserFor(key)
	if sum == nil {
		return c.source(key).List(ctx, opts)
	}
	out := &unstructured.UnstructuredList{}
	rv, err := listPaged(ctx, c.pager(key, sum), opts, func(page []*unstructured.Unstructured) {
		for _, u := range page {
			out.Items = append(out.Items, *u)
		}
	})
	out.SetResourceVersion(rv)
	return out, err
}

// listPaged reads every object fillPage at a time (one consistent read),
// handing each page on summarised. It returns the list's resourceVersion.
func listPaged(ctx context.Context, read pageFunc, opts metav1.ListOptions, page func([]*unstructured.Unstructured)) (string, error) {
	select {
	case fillSlots <- struct{}{}:
		defer func() { <-fillSlots }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	opts.Limit, opts.ResourceVersion = fillPage, ""
	restarts := 0
	for {
		items, rv, cont, err := read(ctx, opts)
		if err != nil {
			if opts.Continue != "" && isExpired(err) && restarts < 3 {
				// The continue token outlived compaction: read again from
				// the start (pages already handed on are simply replaced).
				opts.Continue = ""
				restarts++
				continue
			}
			return "", err
		}
		page(items)
		if cont == "" {
			return rv, nil
		}
		opts.Continue = cont
	}
}

// listMetadata is step 1: the metadata LIST, as stand-ins.
func (s *stream) listMetadata(opts metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	ml, err := s.meta.List(s.ctx, opts)
	if err != nil {
		return nil, err
	}
	gv := s.key.GVR.GroupVersion().String()
	out := &unstructured.UnstructuredList{Items: make([]unstructured.Unstructured, len(ml.Items))}
	out.SetResourceVersion(ml.GetResourceVersion())
	for i := range ml.Items {
		out.Items[i] = *standIn(&ml.Items[i], gv, s.kind)
	}
	return out, nil
}

// standIn is an object's pending stand-in, built from its metadata.
func standIn(p *metav1.PartialObjectMetadata, apiVersion, kind string) *unstructured.Unstructured {
	md, _ := runtime.DefaultUnstructuredConverter.ToUnstructured(&p.ObjectMeta)
	stripMeta(md)
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": apiVersion, "kind": kind, "metadata": md, pendingField: true,
	}}
}

// fill is step 2: page through the full objects, replacing stand-ins with
// summaries, then drop what wasn't seen and mark the stream complete.
func (s *stream) fill() error {
	seen := map[string]bool{}
	rv, err := listPaged(s.ctx, s.c.pager(s.key, s.summarise), s.listOptions(), func(page []*unstructured.Unstructured) {
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, u := range page {
			trim(u)
			k := objKey(u)
			seen[k] = true
			t := watch.Added
			if _, ok := s.items[k]; ok {
				t = watch.Modified
			}
			s.items[k] = u
			for sub := range s.subs {
				sub.push(t, u)
			}
		}
	})
	if err != nil {
		return err
	}
	s.mu.Lock()
	for k, u := range s.items {
		if !seen[k] {
			delete(s.items, k)
			for sub := range s.subs {
				sub.push(watch.Deleted, u)
			}
			s.forgetMemoLocked(u)
		}
	}
	s.rv = rv
	s.filled = true
	s.markDoneLocked()
	s.mu.Unlock()
	return nil
}

// isExpired is a LIST continue token or watch version that is too old.
func isExpired(err error) bool {
	return apierrors.IsGone(err) || apierrors.IsResourceExpired(err)
}

// ---- summaries ---------------------------------------------------------------

// stripMeta drops what no summary reader needs from metadata.
func stripMeta(md map[string]any) {
	delete(md, "managedFields")
	if ann, ok := md["annotations"].(map[string]any); ok {
		delete(ann, lastApplied)
		if len(ann) == 0 {
			delete(md, "annotations")
		}
	}
}

// keep copies the named top-level fields of o (metadata stripped).
func keep(o map[string]any, fields ...string) map[string]any {
	out := make(map[string]any, len(fields)+1)
	for _, f := range append(fields, "apiVersion", "kind", "metadata") {
		if v, ok := o[f]; ok {
			out[f] = v
		}
	}
	if md, ok := out["metadata"].(map[string]any); ok {
		stripMeta(md)
	}
	return out
}

// sizes maps each key of m (a data map) to its value's size in bytes.
// Summaries hold int64 sizes where the object held values; the table's
// size helpers (base64size, textsize) take a number as a known size.
func sizes(m any, size func(string) int64) map[string]any {
	in, ok := m.(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string]any, len(in))
	for k, v := range in {
		s, _ := v.(string)
		out[k] = size(s)
	}
	return out
}

// base64Size is the decoded length of a base64 string, from its length.
func base64Size(s string) int64 {
	n := int64(len(s) / 4 * 3)
	switch {
	case strings.HasSuffix(s, "=="):
		n -= 2
	case strings.HasSuffix(s, "="):
		n--
	}
	return n
}

// textSize is a string's length in bytes (jq's utf8bytelength).
func textSize(s string) int64 { return int64(len(s)) }

// summariseSecret keeps the type and key names with value sizes.
func summariseSecret(o map[string]any) map[string]any {
	out := keep(o, "type", "immutable")
	if d := sizes(o["data"], base64Size); d != nil {
		out["data"] = d
	}
	return out
}

// summariseConfigMap keeps key names with value sizes.
func summariseConfigMap(o map[string]any) map[string]any {
	out := keep(o, "immutable")
	if d := sizes(o["data"], textSize); d != nil {
		out["data"] = d
	}
	if d := sizes(o["binaryData"], base64Size); d != nil {
		out["binaryData"] = d
	}
	return out
}

// summariseCRD drops the openAPI schemas (often hundreds of KB) and the
// conversion webhook's CA bundle; names, scope, versions (with their
// printer columns) and status stay.
func summariseCRD(o map[string]any) map[string]any {
	out := keep(o, "status")
	spec, ok := o["spec"].(map[string]any)
	if !ok {
		return out
	}
	s := make(map[string]any, len(spec))
	for k, v := range spec {
		switch k {
		case "versions":
			vs, _ := v.([]any)
			nv := make([]any, 0, len(vs))
			for _, x := range vs {
				if m, ok := x.(map[string]any); ok {
					c := make(map[string]any, len(m))
					for f, y := range m {
						if f != "schema" {
							c[f] = y
						}
					}
					nv = append(nv, c)
				}
			}
			s[k] = nv
		case "conversion":
			if m, ok := v.(map[string]any); ok {
				s[k] = map[string]any{"strategy": m["strategy"]}
			}
		default:
			s[k] = v
		}
	}
	out["spec"] = s
	return out
}
