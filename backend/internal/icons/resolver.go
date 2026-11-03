// Package icons finds an icon for a CRD API group (argoproj.io,
// cert-manager.io, …): the installing Helm chart's icon, a curated icon
// bundled with the app, or the favicon of the group's domain. Results,
// including misses, are cached under ~/.cache/k8sman/icons.
package icons

import (
	"context"
	"sync"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

// Sources reported in Result.Source.
const (
	SourceHelm    = "helm"    // the chart icon of the Helm release behind the group
	SourceBundled = "bundled" // an icon shipped with the app (Result.Asset)
	SourceFavicon = "favicon" // the website favicon of the group's domain
	SourceNone    = "none"    // nothing found: the UI draws a monogram
)

// Result is how a group's icon was resolved. Data is set for helm and
// favicon results.
type Result struct {
	Source string `json:"source"`
	// URL the image was fetched from (helm/favicon).
	URL string `json:"url,omitempty"`
	// Asset is the bundled icon name (frontend/assets/icons/<asset>.png).
	Asset string `json:"asset,omitempty"`
	// Release is the Helm release (namespace/name) the icon came from.
	Release     string `json:"release,omitempty"`
	ContentType string `json:"-"`
	Data        []byte `json:"-"`
}

// Cluster is the cluster a lookup runs against. Key identifies it for
// caching (e.g. kubeconfig + context). Metadata may be nil when Config is
// set; it is then built on demand.
type Cluster struct {
	Key      string
	Typed    kubernetes.Interface
	Metadata metadata.Interface
	Config   *rest.Config
}

// Resolver resolves group icons. Safe for concurrent use.
type Resolver struct {
	Cache   *Cache
	Fetcher *Fetcher
	// Remote reports whether network fetches (chart icon URLs and
	// favicons) are allowed right now. nil = always.
	Remote func() bool
	// HelmTTL is how long a cluster's Helm attribution is reused.
	HelmTTL time.Duration

	helmMu sync.Mutex
	helm   map[string]helmCacheEntry

	flightMu sync.Mutex
	flight   map[string]*flight
}

type helmCacheEntry struct {
	idx *helmIndex
	at  time.Time
}

type flight struct {
	done chan struct{}
	e    Entry
}

// NewResolver returns a resolver caching under dir ("" = memory only).
func NewResolver(dir string, remote func() bool) *Resolver {
	return &Resolver{Cache: NewCache(dir), Fetcher: NewFetcher(), Remote: remote, HelmTTL: 10 * time.Minute}
}

func (r *Resolver) remote() bool { return r.Remote == nil || r.Remote() }

// Resolve finds the icon for group on cluster cl.
func (r *Resolver) Resolve(ctx context.Context, cl Cluster, group string) Result {
	if !ValidGroup(group) {
		return Result{Source: SourceNone}
	}
	// 1. The Helm chart that installed or operates the group.
	if iconURL, release := r.helmIcon(ctx, cl, group); iconURL != "" {
		e := r.cached(ctx, "url:"+iconURL, func(ctx context.Context) Entry {
			data, ct, err := r.Fetcher.FetchImage(ctx, iconURL)
			if err != nil {
				return Entry{URL: iconURL, Error: err.Error()}
			}
			return Entry{OK: true, URL: iconURL, ContentType: ct, Data: data}
		})
		if e.OK {
			return Result{Source: SourceHelm, URL: e.URL, Release: release, ContentType: e.ContentType, Data: e.Data}
		}
	}
	// 2. A curated icon bundled with the app.
	if asset := CuratedAsset(group); asset != "" {
		return Result{Source: SourceBundled, Asset: asset}
	}
	// 3. The favicon of the group's domain.
	if domains := CandidateDomains(group); len(domains) > 0 {
		e := r.cached(ctx, "favicon:"+group, func(ctx context.Context) Entry {
			var last error
			for _, d := range domains {
				data, ct, u, err := r.Fetcher.FetchFavicon(ctx, d)
				if err == nil {
					return Entry{OK: true, URL: u, ContentType: ct, Data: data}
				}
				last = err
			}
			return Entry{Error: last.Error()}
		})
		if e.OK {
			return Result{Source: SourceFavicon, URL: e.URL, ContentType: e.ContentType, Data: e.Data}
		}
	}
	// 4. Nothing: the UI draws a monogram.
	return Result{Source: SourceNone}
}

// cached returns the cache entry for key, computing it with fn (at most once
// concurrently) when missing and remote fetching is allowed.
func (r *Resolver) cached(ctx context.Context, key string, fn func(context.Context) Entry) Entry {
	remote := r.remote()
	if e, ok := r.Cache.Get(key, !remote); ok {
		return e
	}
	if !remote {
		return Entry{}
	}
	r.flightMu.Lock()
	if r.flight == nil {
		r.flight = map[string]*flight{}
	}
	if f, ok := r.flight[key]; ok {
		r.flightMu.Unlock()
		select {
		case <-f.done:
			return f.e
		case <-ctx.Done():
			return Entry{}
		}
	}
	f := &flight{done: make(chan struct{})}
	r.flight[key] = f
	r.flightMu.Unlock()

	// Detach from the request so a closed connection doesn't cache a
	// spurious failure, but bound the whole lookup.
	fctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	e := fn(fctx)
	cancel()
	f.e = r.Cache.Put(key, e)
	close(f.done)
	r.flightMu.Lock()
	delete(r.flight, key)
	r.flightMu.Unlock()
	return f.e
}

func (r *Resolver) helmIcon(ctx context.Context, cl Cluster, group string) (iconURL, release string) {
	if cl.Typed == nil {
		return "", ""
	}
	r.helmMu.Lock()
	defer r.helmMu.Unlock()
	if r.helm == nil {
		r.helm = map[string]helmCacheEntry{}
	}
	ce, ok := r.helm[cl.Key]
	if !ok || time.Since(ce.at) > r.HelmTTL {
		meta := cl.Metadata
		if meta == nil && cl.Config != nil {
			meta, _ = metadata.NewForConfig(cl.Config)
		}
		hctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
		ce = helmCacheEntry{idx: buildHelmIndex(hctx, cl.Typed, meta), at: time.Now()}
		cancel()
		r.helm[cl.Key] = ce
	}
	return ce.idx.iconFor(group)
}

// InvalidateHelm drops the cached Helm attribution for a cluster (or all
// clusters when key is "").
func (r *Resolver) InvalidateHelm(key string) {
	r.helmMu.Lock()
	defer r.helmMu.Unlock()
	if key == "" {
		r.helm = nil
	} else {
		delete(r.helm, key)
	}
}
