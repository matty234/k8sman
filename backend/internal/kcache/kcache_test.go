package kcache

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/watch"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	clienttesting "k8s.io/client-go/testing"
)

var cmGVR = schema.GroupVersionResource{Version: "v1", Resource: "configmaps"}

func cm(ns, name, rv string, lbl map[string]string) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetAPIVersion("v1")
	u.SetKind("ConfigMap")
	u.SetNamespace(ns)
	u.SetName(name)
	u.SetUID(types.UID(ns + "-" + name))
	u.SetResourceVersion(rv)
	u.SetLabels(lbl)
	return u
}

// fakeAPI is a dynamic client whose LIST results/errors and watches the test
// controls, counting calls.
type fakeAPI struct {
	t       *testing.T
	client  *dynamicfake.FakeDynamicClient
	lists   atomic.Int32
	mu      sync.Mutex
	items   []*unstructured.Unstructured
	listErr []error // consumed one per LIST
	listRV  string
	watches chan *watchCall
}

type watchCall struct {
	rv string
	w  *watch.FakeWatcher
}

func newFakeAPI(t *testing.T, items ...*unstructured.Unstructured) *fakeAPI {
	f := &fakeAPI{t: t, items: items, listRV: "100", watches: make(chan *watchCall, 64)}
	f.client = dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{cmGVR: "ConfigMapList"})
	f.client.PrependReactor("list", "configmaps", func(clienttesting.Action) (bool, runtime.Object, error) {
		f.lists.Add(1)
		f.mu.Lock()
		defer f.mu.Unlock()
		if len(f.listErr) > 0 {
			err := f.listErr[0]
			f.listErr = f.listErr[1:]
			return true, nil, err
		}
		l := &unstructured.UnstructuredList{}
		l.SetResourceVersion(f.listRV)
		for _, u := range f.items {
			l.Items = append(l.Items, *u.DeepCopy())
		}
		return true, l, nil
	})
	f.client.PrependWatchReactor("configmaps", func(a clienttesting.Action) (bool, watch.Interface, error) {
		w := watch.NewFakeWithChanSize(16, false)
		rv := a.(clienttesting.WatchActionImpl).GetWatchRestrictions().ResourceVersion
		f.watches <- &watchCall{rv: rv, w: w}
		return true, w, nil
	})
	return f
}

func (f *fakeAPI) nextWatch() *watchCall {
	f.t.Helper()
	select {
	case w := <-f.watches:
		return w
	case <-time.After(5 * time.Second):
		f.t.Fatal("no WATCH started")
		return nil
	}
}

func (f *fakeAPI) noWatch(d time.Duration) {
	f.t.Helper()
	select {
	case w := <-f.watches:
		f.t.Fatalf("unexpected WATCH from rv %q", w.rv)
	case <-time.After(d):
	}
}

func next(t *testing.T, sub *Sub) Update {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-sub.C():
			if u := sub.Next(); u.Err != nil || u.Snapshot != nil || len(u.Events) > 0 {
				return u
			}
		case <-deadline:
			t.Fatal("no update")
		}
	}
}

func names(items []*unstructured.Unstructured) string {
	s := ""
	for _, u := range items {
		s += u.GetName() + ","
	}
	return s
}

func testCache(t *testing.T, api *fakeAPI) *Cache {
	c := New(api.client)
	c.minBackoff, c.maxBackoff = 10*time.Millisecond, 20*time.Millisecond
	t.Cleanup(c.Close)
	return c
}

func TestSharedStreamRefCountAndIdleEviction(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil), cm("a", "y", "2", nil))
	c := testCache(t, api)
	c.idle = 50 * time.Millisecond
	key := Key{GVR: cmGVR, Namespace: "a"}

	s1 := c.Subscribe(key)
	u := next(t, s1)
	if u.Snapshot == nil || names(u.Snapshot.Items) != "x,y," || u.Snapshot.ResourceVersion != "100" {
		t.Fatalf("first update %+v", u)
	}
	w := api.nextWatch()
	if w.rv != "100" {
		t.Fatalf("watch from rv %q", w.rv)
	}
	s2 := c.Subscribe(key)
	if u := next(t, s2); u.Snapshot == nil || len(u.Snapshot.Items) != 2 {
		t.Fatalf("second subscriber %+v", u)
	}
	if n := api.lists.Load(); n != 1 {
		t.Fatalf("two subscribers made %d LISTs, want 1", n)
	}
	api.noWatch(50 * time.Millisecond)
	if st := c.Stats(); st.Streams != 1 || st.Subscribers != 2 {
		t.Fatalf("stats %+v", st)
	}

	// Both see the same event.
	w.w.Modify(cm("a", "x", "3", nil))
	for _, s := range []*Sub{s1, s2} {
		u := next(t, s)
		if len(u.Events) != 1 || u.Events[0].Type != watch.Modified || u.Events[0].Object.GetResourceVersion() != "3" {
			t.Fatalf("event %+v", u)
		}
	}

	// Snapshot reads are served from the warm stream without a LIST.
	if snap, ok := c.Cached(Key{GVR: cmGVR, Namespace: "a"}); !ok || len(snap.Items) != 2 {
		t.Fatalf("cached read %v %d", ok, len(snap.Items))
	}
	if _, ok := c.Cached(Key{GVR: cmGVR}); ok {
		t.Fatal("a namespaced stream must not answer an all-namespaces read")
	}

	s1.Close()
	s1.Close() // idempotent
	if st := c.Stats(); st.Streams != 1 || st.Subscribers != 1 {
		t.Fatalf("after one close %+v", st)
	}
	s2.Close()
	if _, ok := c.Cached(key); !ok {
		t.Fatal("stream should stay warm during the idle period")
	}
	time.Sleep(200 * time.Millisecond)
	if st := c.Stats(); st.Streams != 0 {
		t.Fatalf("stream not evicted after idle: %+v", st)
	}
	if _, ok := c.Cached(key); ok {
		t.Fatal("evicted stream still answers")
	}
	select {
	case <-w.w.ResultChan():
	case <-time.After(time.Second):
	}
	if !w.w.IsStopped() {
		t.Fatal("upstream watch not stopped after eviction")
	}
}

func TestResubscribeDuringIdleKeepsStream(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil))
	c := testCache(t, api)
	c.idle = 100 * time.Millisecond
	key := Key{GVR: cmGVR}
	s := c.Subscribe(key)
	next(t, s)
	api.nextWatch()
	s.Close()
	s = c.Subscribe(key)
	defer s.Close()
	next(t, s)
	time.Sleep(250 * time.Millisecond)
	if st := c.Stats(); st.Streams != 1 || api.lists.Load() != 1 {
		t.Fatalf("stream should survive: %+v lists=%d", st, api.lists.Load())
	}
}

func TestForbiddenEndsStreamWithSameError(t *testing.T) {
	api := newFakeAPI(t)
	forbidden := apierrors.NewForbidden(schema.GroupResource{Resource: "configmaps"}, "", errors.New("RBAC says no"))
	api.listErr = []error{forbidden, forbidden}
	c := testCache(t, api)
	key := Key{GVR: cmGVR, Namespace: "a"}

	s := c.Subscribe(key)
	u := next(t, s)
	if !apierrors.IsForbidden(u.Err) || !u.Terminal || u.Err.Error() != forbidden.Error() {
		t.Fatalf("want terminal Forbidden, got %+v", u)
	}
	s.Close()
	if st := c.Stats(); st.Streams != 0 {
		t.Fatalf("forbidden stream kept: %+v", st)
	}
	// List (the snapshot path) surfaces the same error.
	if _, err := c.List(context.Background(), key); !apierrors.IsForbidden(err) {
		t.Fatalf("List error %v", err)
	}
	// RBAC fixed: the next user starts over.
	if _, err := c.List(context.Background(), key); err != nil {
		t.Fatalf("after RBAC fix: %v", err)
	}
}

func TestTransientListErrorRetries(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil))
	api.listErr = []error{apierrors.NewInternalError(errors.New("etcd hiccup"))}
	c := testCache(t, api)
	s := c.Subscribe(Key{GVR: cmGVR})
	defer s.Close()
	if u := next(t, s); u.Err == nil || u.Terminal {
		t.Fatalf("want a retryable error first, got %+v", u)
	}
	if u := next(t, s); u.Snapshot == nil || len(u.Snapshot.Items) != 1 {
		t.Fatalf("want a snapshot after retry, got %+v", u)
	}
}

func TestWatchResumeAndExpiry(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil))
	c := testCache(t, api)
	s := c.Subscribe(Key{GVR: cmGVR})
	defer s.Close()
	next(t, s)
	w := api.nextWatch()

	// A plain close (the API server ends watches every few minutes) resumes
	// from the last seen version, with no re-list and no new snapshot.
	w.w.Add(cm("a", "y", "105", nil))
	next(t, s)
	w.w.Action(watch.Bookmark, cm("", "", "110", nil))
	time.Sleep(20 * time.Millisecond)
	w.w.Stop()
	w2 := api.nextWatch()
	if w2.rv != "110" || api.lists.Load() != 1 {
		t.Fatalf("resume rv=%q lists=%d", w2.rv, api.lists.Load())
	}

	// 410 Gone: re-list and send a fresh snapshot.
	api.mu.Lock()
	api.items = append(api.items, cm("a", "z", "120", nil))
	api.listRV = "120"
	api.mu.Unlock()
	w2.w.Error(&metav1.Status{Status: metav1.StatusFailure, Code: 410, Reason: metav1.StatusReasonExpired})
	u := next(t, s)
	if u.Snapshot == nil || names(u.Snapshot.Items) != "x,z," || u.Snapshot.ResourceVersion != "120" {
		t.Fatalf("after expiry %+v", u)
	}
	if api.lists.Load() != 2 {
		t.Fatalf("lists %d", api.lists.Load())
	}
	if w3 := api.nextWatch(); w3.rv != "120" {
		t.Fatalf("re-watch rv %q", w3.rv)
	}
}

func TestFilteredSubscriptionOnBroaderStream(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", map[string]string{"app": "web"}), cm("b", "y", "2", map[string]string{"app": "db"}))
	c := testCache(t, api)
	table := c.Subscribe(Key{GVR: cmGVR})
	defer table.Close()
	next(t, table)
	w := api.nextWatch()

	// Inspector-style single-object watch rides on the table's stream.
	one := c.Subscribe(Key{GVR: cmGVR, Namespace: "a", FieldSelector: "metadata.name=x"})
	defer one.Close()
	if u := next(t, one); u.Snapshot == nil || names(u.Snapshot.Items) != "x," {
		t.Fatalf("single object %+v", u)
	}
	web := c.Subscribe(Key{GVR: cmGVR, LabelSelector: "app=web"})
	defer web.Close()
	if u := next(t, web); u.Snapshot == nil || names(u.Snapshot.Items) != "x," {
		t.Fatalf("label selector %+v", u)
	}
	if api.lists.Load() != 1 {
		t.Fatalf("filtered subscribers made extra LISTs: %d", api.lists.Load())
	}
	api.noWatch(30 * time.Millisecond)

	// y gains app=web: ADDED for the label subscriber, nothing for `one`.
	w.w.Modify(cm("b", "y", "3", map[string]string{"app": "web"}))
	if u := next(t, web); len(u.Events) != 1 || u.Events[0].Type != watch.Added || u.Events[0].Object.GetName() != "y" {
		t.Fatalf("label gained %+v", u)
	}
	// x loses it: DELETED for the label subscriber, MODIFIED for `one`.
	w.w.Modify(cm("a", "x", "4", map[string]string{"app": "other"}))
	if u := next(t, web); len(u.Events) != 1 || u.Events[0].Type != watch.Deleted || u.Events[0].Object.GetName() != "x" {
		t.Fatalf("label lost %+v", u)
	}
	if u := next(t, one); len(u.Events) != 1 || u.Events[0].Type != watch.Modified {
		t.Fatalf("single object event %+v", u)
	}

	// Selectors the cache can't evaluate go to the API server.
	if _, f := c.warmLocked(Key{GVR: cmGVR, FieldSelector: "status.phase=Running"}); f != nil {
		t.Fatal("status.phase must not be filtered locally")
	}
}

func TestSlowSubscriberGetsSnapshotInsteadOfUnboundedQueue(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil))
	c := testCache(t, api)
	c.maxPending = 5
	s := c.Subscribe(Key{GVR: cmGVR})
	defer s.Close()
	next(t, s)
	w := api.nextWatch()
	for i := range 20 {
		w.w.Add(cm("a", fmt.Sprintf("n%02d", i), fmt.Sprint(200+i), nil))
	}
	// Wait until the stream has applied all 20.
	deadline := time.Now().Add(5 * time.Second)
	for {
		snap, _ := c.Cached(Key{GVR: cmGVR})
		if len(snap.Items) == 21 || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	s.s.mu.Lock()
	queued := len(s.pending)
	s.s.mu.Unlock()
	if queued > c.maxPending {
		t.Fatalf("queue grew to %d", queued)
	}
	u := next(t, s)
	if u.Snapshot == nil || len(u.Snapshot.Items) != 21 {
		t.Fatalf("want a resync snapshot of 21, got %+v", u)
	}
}

func TestMemoRecomputesOnlyOnChange(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil))
	c := testCache(t, api)
	s := c.Subscribe(Key{GVR: cmGVR})
	defer s.Close()
	u := next(t, s)
	obj := u.Snapshot.Items[0]
	calls := 0
	f := func() any { calls++; return calls }
	s.Memo(obj, "row", "", f)
	s.Memo(obj, "row", "", f)
	if calls != 1 {
		t.Fatalf("memo computed %d times", calls)
	}
	s.Memo(obj, "row", "usage-changed", f)
	s.Memo(obj, "other", "", f)
	if calls != 3 {
		t.Fatalf("memo should recompute for new extra/tag: %d", calls)
	}
	w := api.nextWatch()
	w.w.Modify(cm("a", "x", "2", nil))
	ev := next(t, s).Events[0].Object
	s.Memo(ev, "row", "", f)
	if calls != 4 {
		t.Fatalf("memo should recompute for a new resourceVersion: %d", calls)
	}
	w.w.Delete(ev)
	next(t, s)
	s.s.mu.Lock()
	n := len(s.s.memo)
	s.s.mu.Unlock()
	if n != 0 {
		t.Fatalf("memo kept %d entries for a deleted object", n)
	}
}

func TestCacheStripsManagedFields(t *testing.T) {
	withMF := func(u *unstructured.Unstructured) *unstructured.Unstructured {
		u.SetManagedFields([]metav1.ManagedFieldsEntry{{Manager: "kubectl", Operation: metav1.ManagedFieldsOperationUpdate}})
		return u
	}
	api := newFakeAPI(t, withMF(cm("a", "x", "1", nil)))
	c := testCache(t, api)
	sub := c.Subscribe(Key{GVR: cmGVR})
	defer sub.Close()
	if u := next(t, sub); u.Snapshot == nil || len(u.Snapshot.Items) != 1 || u.Snapshot.Items[0].GetManagedFields() != nil {
		t.Fatalf("listed object kept managedFields: %+v", u)
	}
	api.nextWatch().w.Add(withMF(cm("a", "y", "2", nil)))
	if u := next(t, sub); len(u.Events) != 1 || u.Events[0].Object.GetManagedFields() != nil {
		t.Fatalf("watched object kept managedFields: %+v", u)
	}
}

func TestListStartsStreamAndCtxCancel(t *testing.T) {
	api := newFakeAPI(t, cm("a", "x", "1", nil))
	c := testCache(t, api)
	c.idle = time.Hour
	key := Key{GVR: cmGVR}
	for range 3 {
		snap, err := c.List(context.Background(), key)
		if err != nil || len(snap.Items) != 1 {
			t.Fatal(err)
		}
	}
	if api.lists.Load() != 1 {
		t.Fatalf("List made %d upstream LISTs, want 1", api.lists.Load())
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	api.mu.Lock()
	api.listErr = []error{apierrors.NewInternalError(errors.New("x"))}
	api.mu.Unlock()
	if _, err := c.List(ctx, Key{GVR: cmGVR, Namespace: "other"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled List: %v", err)
	}
	c.Close()
	if c.Stats().Streams != 0 {
		t.Fatal("Close left streams")
	}
}
