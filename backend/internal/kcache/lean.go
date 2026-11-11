package kcache

import (
	"context"
	"sync"

	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/metadata"
)

// A lean stream (Key.Lean) may leave out Secret values its readers never
// show: tables (whose Keys and Size columns need only key names and
// value lengths) and plugins (which see key names only). Helm release
// Secrets (type helm.sh/release.v1, one per release revision) hold the
// whole release gzipped and base64-encoded twice; on a typical cluster
// they are almost all of the bytes of a Secrets LIST (tens of MB). A lean
// stream lists and watches them as metadata only, and every other Secret
// in full, so opening the Secrets table costs a fraction of the transfer.
//
// A Helm release's stand-in has its type and its one key, "release" (the
// only key Helm's Secret storage writes), with a null value: "not loaded",
// which the Size column shows as blank. Readers that need values (the
// inspector, /api/items, the YAML view) use full streams or a live GET;
// a lean stream never answers them (see narrowing).

// SecretsGVR is core/v1 Secrets, the one kind with a lean form.
var SecretsGVR = schema.GroupVersionResource{Version: "v1", Resource: "secrets"}

const (
	helmReleaseType = "helm.sh/release.v1"
	helmReleaseKey  = "release"
)

// norm clears Lean for kinds without a lean form, so they share one stream.
func (k Key) norm() Key {
	if k.Lean && k.GVR != SecretsGVR {
		k.Lean = false
	}
	return k
}

// source is what a stream lists and watches: a dynamic resource, or for a
// lean Secrets key, leanSecrets.
type source interface {
	List(ctx context.Context, opts metav1.ListOptions) (*unstructured.UnstructuredList, error)
	Watch(ctx context.Context, opts metav1.ListOptions) (watch.Interface, error)
}

// source builds the list+watch source for key.
func (c *Cache) source(key Key) source {
	var full source = c.dyn.Resource(key.GVR)
	if key.Namespace != "" {
		full = c.dyn.Resource(key.GVR).Namespace(key.Namespace)
	}
	if !key.Lean || c.meta == nil {
		return full
	}
	var m metadata.ResourceInterface = c.meta.Resource(key.GVR)
	if key.Namespace != "" {
		m = c.meta.Resource(key.GVR).Namespace(key.Namespace)
	}
	return &leanSecrets{full: full, meta: m}
}

// ListOnce is one LIST for key through the same source a stream would use
// (so a lean key costs a lean LIST), without starting a stream.
func (c *Cache) ListOnce(ctx context.Context, key Key) (*unstructured.UnstructuredList, error) {
	key = key.norm()
	return c.source(key).List(ctx, metav1.ListOptions{LabelSelector: key.LabelSelector, FieldSelector: key.FieldSelector})
}

// leanSecrets lists and watches Helm release Secrets as metadata and the
// rest in full. The two parts are split by field selector (Secrets support
// `type`) and resume their watches from their own resourceVersions, which
// it tracks itself: the stream's single resourceVersion is only a token.
type leanSecrets struct {
	full source
	meta metadata.ResourceInterface

	mu             sync.Mutex
	rvFull, rvMeta string
}

func withSelector(fs, extra string) string {
	if fs == "" {
		return extra
	}
	return fs + "," + extra
}

func (l *leanSecrets) List(ctx context.Context, opts metav1.ListOptions) (*unstructured.UnstructuredList, error) {
	fullOpts, metaOpts := opts, opts
	fullOpts.FieldSelector = withSelector(opts.FieldSelector, "type!="+helmReleaseType)
	metaOpts.FieldSelector = withSelector(opts.FieldSelector, "type="+helmReleaseType)
	var (
		ml   *metav1.PartialObjectMetadataList
		merr error
		wg   sync.WaitGroup
	)
	wg.Add(1)
	go func() {
		defer wg.Done()
		ml, merr = l.meta.List(ctx, metaOpts)
	}()
	list, err := l.full.List(ctx, fullOpts)
	wg.Wait()
	if err != nil {
		return nil, err
	}
	if merr != nil {
		return nil, merr
	}
	l.mu.Lock()
	l.rvFull, l.rvMeta = list.GetResourceVersion(), ml.GetResourceVersion()
	l.mu.Unlock()
	for i := range ml.Items {
		list.Items = append(list.Items, *helmStub(&ml.Items[i]))
	}
	return list, nil
}

// Watch resumes both parts from where each last was (opts.ResourceVersion
// is ignored) and merges them. The merged watch ends when either part does.
func (l *leanSecrets) Watch(ctx context.Context, opts metav1.ListOptions) (watch.Interface, error) {
	l.mu.Lock()
	fullOpts, metaOpts := opts, opts
	fullOpts.ResourceVersion, metaOpts.ResourceVersion = l.rvFull, l.rvMeta
	l.mu.Unlock()
	fullOpts.FieldSelector = withSelector(opts.FieldSelector, "type!="+helmReleaseType)
	metaOpts.FieldSelector = withSelector(opts.FieldSelector, "type="+helmReleaseType)
	fw, err := l.full.Watch(ctx, fullOpts)
	if err != nil {
		return nil, err
	}
	mw, err := l.meta.Watch(ctx, metaOpts)
	if err != nil {
		fw.Stop()
		return nil, err
	}
	m := &mergedWatch{out: make(chan watch.Event), stop: make(chan struct{})}
	m.ws = []watch.Interface{fw, mw}
	m.wg.Add(2)
	go m.forward(fw, func(rv string) { l.mu.Lock(); l.rvFull = rv; l.mu.Unlock() }, nil)
	go m.forward(mw, func(rv string) { l.mu.Lock(); l.rvMeta = rv; l.mu.Unlock() }, func(o runtime.Object) runtime.Object {
		if p, ok := o.(*metav1.PartialObjectMetadata); ok {
			return helmStub(p)
		}
		return o
	})
	go func() { m.wg.Wait(); close(m.out) }()
	return m, nil
}

// helmStub is a Helm release Secret's stand-in, built from its metadata.
func helmStub(p *metav1.PartialObjectMetadata) *unstructured.Unstructured {
	md, _ := runtime.DefaultUnstructuredConverter.ToUnstructured(&p.ObjectMeta)
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1", "kind": "Secret", "metadata": md,
		"type": helmReleaseType,
		"data": map[string]any{helmReleaseKey: nil},
	}}
}

// mergedWatch is two watches as one.
type mergedWatch struct {
	out  chan watch.Event
	stop chan struct{}
	once sync.Once
	wg   sync.WaitGroup
	ws   []watch.Interface
}

func (m *mergedWatch) ResultChan() <-chan watch.Event { return m.out }

func (m *mergedWatch) Stop() {
	m.once.Do(func() {
		close(m.stop)
		for _, w := range m.ws {
			w.Stop()
		}
	})
}

// forward passes w's events on (bookmarks only advance its
// resourceVersion), converting objects with conv when set.
func (m *mergedWatch) forward(w watch.Interface, setRV func(string), conv func(runtime.Object) runtime.Object) {
	defer m.wg.Done()
	defer m.Stop()
	for {
		var ev watch.Event
		var ok bool
		select {
		case <-m.stop:
			return
		case ev, ok = <-w.ResultChan():
			if !ok {
				return
			}
		}
		rv := ""
		if ev.Type != watch.Error {
			if a, err := meta.Accessor(ev.Object); err == nil {
				rv = a.GetResourceVersion()
			}
			if ev.Type == watch.Bookmark {
				if rv != "" {
					setRV(rv)
				}
				continue
			}
			if conv != nil {
				ev.Object = conv(ev.Object)
			}
		}
		select {
		case m.out <- ev:
		case <-m.stop:
			return
		}
		// Only once delivered: a resumed watch must not skip it.
		if rv != "" {
			setRV(rv)
		}
	}
}
