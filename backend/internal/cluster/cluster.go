// Package cluster owns the connection to the Kubernetes API: kubeconfig
// loading, context switching, discovery and the dynamic/typed clients.
package cluster

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"sort"
	"strings"
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

// ResourceType describes one listable API resource discovered on the server.
type ResourceType struct {
	Group      string   `json:"group"`
	Version    string   `json:"version"`
	Resource   string   `json:"resource"`
	Kind       string   `json:"kind"`
	Namespaced bool     `json:"namespaced"`
	Verbs      []string `json:"verbs"`
	ShortNames []string `json:"shortNames,omitempty"`
	Categories []string `json:"categories,omitempty"`
	// Custom is true when the resource is served by a CustomResourceDefinition.
	Custom bool `json:"custom"`
	// Subresources lists the editable subresources the type serves
	// ("status", "scale").
	Subresources []string `json:"subresources,omitempty"`
}

// GVR returns the schema.GroupVersionResource for the type.
func (r ResourceType) GVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: r.Group, Version: r.Version, Resource: r.Resource}
}

// PrinterColumn is a CRD additionalPrinterColumn for a served version.
type PrinterColumn struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	JSONPath string `json:"jsonPath"`
}

// ContextInfo describes a kubeconfig context.
type ContextInfo struct {
	Name      string `json:"name"`
	Cluster   string `json:"cluster"`
	User      string `json:"user"`
	Namespace string `json:"namespace,omitempty"`
	// Server is the cluster's API server URL.
	Server string `json:"server,omitempty"`
	// Fingerprint identifies the cluster in shareable links (see
	// Fingerprint); "" when the server URL has no host.
	Fingerprint string `json:"fingerprint,omitempty"`
	// Auth names the exec credential plugin or auth provider that signs the
	// user in (e.g. "kubelogin", "aws", "gke-gcloud-auth-plugin"); "" for
	// static credentials. Such plugins may wait for a browser login.
	Auth string `json:"auth,omitempty"`
}

// Clients is an immutable snapshot of the clients for the active context.
// Handlers take a snapshot so a concurrent context switch can't change the
// clients mid-request.
type Clients struct {
	Context    string
	Namespace  string // default namespace from the context, may be ""
	RESTConfig *rest.Config
	Dynamic    dynamic.Interface
	Typed      kubernetes.Interface
	Discovery  discovery.CachedDiscoveryInterface
	// Metadata lists objects as metadata only (PartialObjectMetadata). Optional.
	Metadata metadata.Interface

	// refreshDiscovery, when set, re-fetches discovery into the on-disk
	// cache in the background (see buildClients). Started at most once,
	// after the first Resources call served from disk.
	refreshDiscovery func() error
	refreshOnce      sync.Once

	resMu    sync.Mutex
	resTypes []ResourceType // last successful Resources(), nil = not cached

	crdMu sync.Mutex
	// crdSet is every CRD-served group/resource (from a metadata-only list).
	crdSet map[schema.GroupResource]bool
	// crdCols caches additionalPrinterColumns per served version, fetched
	// lazily per CRD (CRD objects carry full schemas and can be megabytes).
	crdCols map[schema.GroupResource]map[string][]PrinterColumn
}

var crdGVR = schema.GroupVersionResource{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}

// Resources discovers all listable resources (preferred version per group).
// Set refresh to drop the discovery cache first (e.g. after installing a CRD).
// The result is cached until the next refresh; callers must not modify it.
func (c *Clients) Resources(ctx context.Context, refresh bool) ([]ResourceType, error) {
	if refresh {
		c.invalidate()
	} else {
		c.resMu.Lock()
		cached := c.resTypes
		c.resMu.Unlock()
		if cached != nil {
			return cached, nil
		}
	}
	// Discovery and the CRD set are independent round trips: overlap them.
	var custom map[schema.GroupResource]bool
	crdsDone := make(chan struct{})
	go func() {
		defer close(crdsDone)
		custom = c.loadCRDs(ctx)
	}()
	lists, err := c.Discovery.ServerPreferredResources()
	<-crdsDone
	if err != nil && !discovery.IsGroupDiscoveryFailedError(err) {
		return nil, err
	}
	partial := err != nil
	out := []ResourceType{}
	for _, l := range lists {
		gv, perr := schema.ParseGroupVersion(l.GroupVersion)
		if perr != nil {
			continue
		}
		// The preferred list drops "<name>/<sub>" entries; the per-version
		// lists behind it are served from the discovery cache.
		var subs map[string][]string
		if full, ferr := c.Discovery.ServerResourcesForGroupVersion(l.GroupVersion); ferr == nil {
			subs = subresourcesOf(full.APIResources)
		}
		for _, r := range l.APIResources {
			if strings.Contains(r.Name, "/") || !slices.Contains(r.Verbs, "list") {
				continue
			}
			out = append(out, ResourceType{
				Group:      gv.Group,
				Version:    gv.Version,
				Resource:   r.Name,
				Kind:       r.Kind,
				Namespaced: r.Namespaced,
				Verbs:      r.Verbs,
				ShortNames: r.ShortNames,
				Categories: r.Categories,
				Custom:     custom[schema.GroupResource{Group: gv.Group, Resource: r.Name}],

				Subresources: subs[r.Name],
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Group != out[j].Group {
			return out[i].Group < out[j].Group
		}
		return out[i].Kind < out[j].Kind
	})
	// Don't pin a partial result (a group failed) or one that raced with a
	// cancelled CRD list: the next call retries.
	if !partial && ctx.Err() == nil {
		c.resMu.Lock()
		c.resTypes = out
		c.resMu.Unlock()
	}
	if !c.Discovery.Fresh() && c.refreshDiscovery != nil {
		c.refreshOnce.Do(func() { go c.backgroundRefresh() })
	}
	return out, nil
}

// invalidate drops every discovery-derived cache.
func (c *Clients) invalidate() {
	c.Discovery.Invalidate()
	c.resMu.Lock()
	c.resTypes = nil
	c.resMu.Unlock()
	c.crdMu.Lock()
	c.crdSet, c.crdCols = nil, nil
	c.crdMu.Unlock()
}

// backgroundRefresh re-fetches discovery after a start served from the disk
// cache, so new or removed APIs show up without blocking the first paint.
func (c *Clients) backgroundRefresh() {
	if err := c.refreshDiscovery(); err != nil {
		log.Printf("discovery refresh (%s): %v", c.Context, err)
		return
	}
	// The disk cache now holds fresh files; recompute from them.
	c.resMu.Lock()
	c.resTypes = nil
	c.resMu.Unlock()
	c.crdMu.Lock()
	c.crdSet = nil
	c.crdMu.Unlock()
}

// Find resolves a group/version/resource to its discovered ResourceType.
// Version may be empty to accept the preferred version.
func (c *Clients) Find(ctx context.Context, group, version, resource string) (ResourceType, error) {
	t, err := c.find(ctx, group, version, resource)
	if err != nil && !c.Discovery.Fresh() && strings.Contains(err.Error(), "not found") {
		// Served from a (possibly stale) disk cache: refresh once and retry,
		// like kubectl does.
		c.invalidate()
		return c.find(ctx, group, version, resource)
	}
	return t, err
}

func (c *Clients) find(ctx context.Context, group, version, resource string) (ResourceType, error) {
	types, err := c.Resources(ctx, false)
	if err != nil {
		return ResourceType{}, err
	}
	for _, t := range types {
		if t.Group == group && t.Resource == resource && (version == "" || t.Version == version) {
			return t, nil
		}
	}
	// Non-preferred versions aren't in the preferred list; fall back to a
	// direct lookup so explicit versions still work.
	if version != "" {
		gv := schema.GroupVersion{Group: group, Version: version}.String()
		if l, err := c.Discovery.ServerResourcesForGroupVersion(gv); err == nil {
			subs := subresourcesOf(l.APIResources)
			for _, r := range l.APIResources {
				if r.Name == resource {
					return ResourceType{Group: group, Version: version, Resource: resource, Kind: r.Kind,
						Namespaced: r.Namespaced, Verbs: r.Verbs, ShortNames: r.ShortNames, Subresources: subs[resource]}, nil
				}
			}
		}
	}
	return ResourceType{}, fmt.Errorf("resource %s/%s %q not found", group, version, resource)
}

// PrinterColumns returns CRD additionalPrinterColumns for a custom resource.
// The CRD is fetched on first use and cached until discovery is refreshed.
func (c *Clients) PrinterColumns(ctx context.Context, gvr schema.GroupVersionResource) []PrinterColumn {
	gr := gvr.GroupResource()
	if !c.loadCRDs(ctx)[gr] {
		return nil
	}
	c.crdMu.Lock()
	if byVersion, ok := c.crdCols[gr]; ok {
		c.crdMu.Unlock()
		return byVersion[gvr.Version]
	}
	c.crdMu.Unlock()

	item, err := c.Dynamic.Resource(crdGVR).Get(ctx, gr.Resource+"."+gr.Group, metav1.GetOptions{ResourceVersion: "0"})
	if err != nil {
		return nil // e.g. RBAC: fall back to generic columns, retry next time
	}
	byVersion := parsePrinterColumns(item)
	c.crdMu.Lock()
	if c.crdCols == nil {
		c.crdCols = map[schema.GroupResource]map[string][]PrinterColumn{}
	}
	c.crdCols[gr] = byVersion
	c.crdMu.Unlock()
	return byVersion[gvr.Version]
}

func parsePrinterColumns(item *unstructured.Unstructured) map[string][]PrinterColumn {
	out := map[string][]PrinterColumn{}
	versions, _, _ := unstructured.NestedSlice(item.Object, "spec", "versions")
	for _, v := range versions {
		vm, ok := v.(map[string]any)
		if !ok {
			continue
		}
		vname, _ := vm["name"].(string)
		pcs, _ := vm["additionalPrinterColumns"].([]any)
		var parsed []PrinterColumn
		for _, pc := range pcs {
			pm, ok := pc.(map[string]any)
			if !ok {
				continue
			}
			p := PrinterColumn{}
			p.Name, _ = pm["name"].(string)
			p.Type, _ = pm["type"].(string)
			p.JSONPath, _ = pm["jsonPath"].(string)
			parsed = append(parsed, p)
		}
		out[vname] = parsed
	}
	return out
}

// loadCRDs returns the set of CRD-served group/resources. It lists CRDs as
// metadata only: CRD names are "<plural>.<group>", and full CRD objects
// (with their OpenAPI schemas) can add up to tens of megabytes.
func (c *Clients) loadCRDs(ctx context.Context) map[schema.GroupResource]bool {
	c.crdMu.Lock()
	defer c.crdMu.Unlock()
	if c.crdSet != nil {
		return c.crdSet
	}
	set := map[schema.GroupResource]bool{}
	names, err := c.crdNames(ctx)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return set // don't cache: the next request retries
		}
		// Lack of RBAC for CRDs is fine — resources just won't be flagged custom.
	}
	for _, n := range names {
		plural, group, ok := strings.Cut(n, ".")
		if ok {
			set[schema.GroupResource{Group: group, Resource: plural}] = true
		}
	}
	c.crdSet = set
	return set
}

func (c *Clients) crdNames(ctx context.Context) ([]string, error) {
	var names []string
	if c.Metadata != nil {
		list, err := c.Metadata.Resource(crdGVR).List(ctx, metav1.ListOptions{ResourceVersion: "0"})
		if err != nil {
			return nil, err
		}
		for _, it := range list.Items {
			names = append(names, it.Name)
		}
		return names, nil
	}
	list, err := c.Dynamic.Resource(crdGVR).List(ctx, metav1.ListOptions{ResourceVersion: "0"})
	if err != nil {
		return nil, err
	}
	for _, it := range list.Items {
		names = append(names, it.GetName())
	}
	return names, nil
}

// subresourcesOf maps each resource name to its editable subresources
// ("status", "scale") found among the "<name>/<sub>" discovery entries.
func subresourcesOf(rs []metav1.APIResource) map[string][]string {
	subs := map[string][]string{}
	for _, r := range rs {
		if base, sub, ok := strings.Cut(r.Name, "/"); ok && (sub == "status" || sub == "scale") {
			subs[base] = append(subs[base], sub)
		}
	}
	return subs
}
