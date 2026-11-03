// Package cluster owns the connection to the Kubernetes API: kubeconfig
// loading, context switching, discovery and the dynamic/typed clients.
package cluster

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
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

	crdMu   sync.Mutex
	crdCols map[schema.GroupVersionResource][]PrinterColumn
	crdSet  map[schema.GroupResource]bool
}

var crdGVR = schema.GroupVersionResource{Group: "apiextensions.k8s.io", Version: "v1", Resource: "customresourcedefinitions"}

// Resources discovers all listable resources (preferred version per group).
// Set refresh to drop the discovery cache first (e.g. after installing a CRD).
func (c *Clients) Resources(ctx context.Context, refresh bool) ([]ResourceType, error) {
	if refresh {
		c.Discovery.Invalidate()
		c.crdMu.Lock()
		c.crdSet, c.crdCols = nil, nil
		c.crdMu.Unlock()
	}
	lists, err := c.Discovery.ServerPreferredResources()
	if err != nil && !discovery.IsGroupDiscoveryFailedError(err) {
		return nil, err
	}
	custom := c.loadCRDs(ctx)
	var out []ResourceType
	for _, l := range lists {
		gv, perr := schema.ParseGroupVersion(l.GroupVersion)
		if perr != nil {
			continue
		}
		for _, r := range l.APIResources {
			if strings.Contains(r.Name, "/") || !hasVerb(r.Verbs, "list") {
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
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Group != out[j].Group {
			return out[i].Group < out[j].Group
		}
		return out[i].Kind < out[j].Kind
	})
	return out, nil
}

// Find resolves a group/version/resource to its discovered ResourceType.
// Version may be empty to accept the preferred version.
func (c *Clients) Find(ctx context.Context, group, version, resource string) (ResourceType, error) {
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
			for _, r := range l.APIResources {
				if r.Name == resource {
					return ResourceType{Group: group, Version: version, Resource: resource, Kind: r.Kind,
						Namespaced: r.Namespaced, Verbs: r.Verbs, ShortNames: r.ShortNames}, nil
				}
			}
		}
	}
	return ResourceType{}, fmt.Errorf("resource %s/%s %q not found", group, version, resource)
}

// PrinterColumns returns CRD additionalPrinterColumns for a custom resource.
func (c *Clients) PrinterColumns(ctx context.Context, gvr schema.GroupVersionResource) []PrinterColumn {
	c.loadCRDs(ctx)
	c.crdMu.Lock()
	defer c.crdMu.Unlock()
	return c.crdCols[gvr]
}

func (c *Clients) loadCRDs(ctx context.Context) map[schema.GroupResource]bool {
	c.crdMu.Lock()
	defer c.crdMu.Unlock()
	if c.crdSet != nil {
		return c.crdSet
	}
	set := map[schema.GroupResource]bool{}
	cols := map[schema.GroupVersionResource][]PrinterColumn{}
	list, err := c.Dynamic.Resource(crdGVR).List(ctx, metav1.ListOptions{})
	if err == nil {
		for _, item := range list.Items {
			group, _, _ := unstructured.NestedString(item.Object, "spec", "group")
			plural, _, _ := unstructured.NestedString(item.Object, "spec", "names", "plural")
			set[schema.GroupResource{Group: group, Resource: plural}] = true
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
				cols[schema.GroupVersionResource{Group: group, Version: vname, Resource: plural}] = parsed
			}
		}
	} else if !errors.Is(err, context.Canceled) {
		// Lack of RBAC for CRDs is fine — resources just won't be flagged custom.
		set = map[schema.GroupResource]bool{}
	}
	c.crdSet, c.crdCols = set, cols
	return set
}

func hasVerb(verbs []string, v string) bool {
	for _, x := range verbs {
		if x == v {
			return true
		}
	}
	return false
}
