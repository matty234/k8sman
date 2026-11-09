package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	admissionv1 "k8s.io/api/admissionregistration/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/rest"

	"github.com/matty234/k8sman/backend/internal/cluster"
	"github.com/matty234/k8sman/backend/internal/httpx"
	"github.com/matty234/k8sman/backend/internal/kcache"
	"github.com/matty234/k8sman/backend/internal/kube"
	"github.com/matty234/k8sman/backend/internal/security"
	upg "github.com/matty234/k8sman/backend/internal/upgrade"
)

// upgradeModule is the Upgrade readiness page (GET /api/upgrade): what
// stands between the cluster and a newer Kubernetes minor. Strictly
// read-only (gets, lists, discovery and one raw GET of /metrics), so it
// works the same with --read-only. Its settings hold the user's ignore
// rules ({"ignores": [...]}, the Security page's rule shape).
type upgradeModule struct {
	d    Deps
	runs runRegistry[*upgradeLists]
}

const upgradeID = "upgrade"

func (m *upgradeModule) Name() string { return upgradeID }

func (m *upgradeModule) Routes(r httpx.Router, d Deps) {
	m.d = d
	r.HandleFunc("GET /api/upgrade", m.handleUpgrade)
}

// upgradeSettings are the module's settings.
type upgradeSettings struct {
	Ignores []security.IgnoreRule `json:"ignores,omitempty"`
}

// ValidateSettings implements Configurable.
func (m *upgradeModule) ValidateSettings(raw json.RawMessage) error {
	var s upgradeSettings
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return err
	}
	if len(s.Ignores) > maxSecurityIgnores {
		return fmt.Errorf("at most %d ignore rules", maxSecurityIgnores)
	}
	for _, g := range s.Ignores {
		if g.Check == "" || (g.Kind == "") != (g.Name == "") {
			return errors.New("an ignore rule needs a check, and kind and name together")
		}
	}
	return nil
}

// Like Security: answer after a soft deadline with what has finished, the
// rest named in `pending`; the lists keep running for the next poll.
const (
	upgradeSoftWait = 1500 * time.Millisecond
	upgradeMaxWait  = 20 * time.Second
	upgradeHardWait = 60 * time.Second
	upgradeReuse    = 5 * time.Second
	// upgradeParallel bounds the per-object requests one source makes at
	// once (Helm release GETs, endpoint lookups, per-namespace lists).
	upgradeParallel = 8
)

type upgradeLists = sourceRun[upg.Input]

// handleUpgrade: ?target=1.33 (default: the next minor), &wait=.
func (m *upgradeModule) handleUpgrade(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var target upg.Version
	if t := q.Get("target"); t != "" {
		v, ok := upg.ParseVersion(t)
		if !ok {
			writeErr(w, httpx.BadRequest("target: want a version such as 1.33"))
			return
		}
		target = v
	}
	scope, err := m.d.ParseScope(q)
	if err != nil {
		writeErr(w, httpx.BadRequest("%v", err))
		return
	}
	wait, err := parseSoftWait(r, upgradeSoftWait, upgradeMaxWait)
	if err != nil {
		writeErr(w, err)
		return
	}
	c := m.d.Mgr.Clients()
	if c == nil {
		writeErr(w, m.d.Mgr.Err())
		return
	}
	ns := scope.String()
	l := m.runs.get(fmt.Sprintf("%p|%s", c, ns), func() *upgradeLists { return startUpgrade(c, ns) })
	if !l.await(r.Context(), wait) {
		return
	}
	in, pending, errs := l.snap()
	if err := errs[upg.SrcDiscovery]; err != nil {
		writeErr(w, err)
		return
	}
	in.Now = time.Now()
	in.Pending = pending
	in.Errors = errs
	in.Forbidden = apierrors.IsForbidden
	res := upg.Analyze(in, target)
	var s upgradeSettings
	_, _ = m.d.Settings.ModuleSettings(upgradeID, c.Context, &s)
	upg.ApplyIgnores(&res, s.Ignores)
	httpx.WriteJSON(w, http.StatusOK, res)
}

var (
	gvrPDBs       = schema.GroupVersionResource{Group: "policy", Version: "v1", Resource: "poddisruptionbudgets"}
	gvrPVs        = schema.GroupVersionResource{Version: "v1", Resource: "persistentvolumes"}
	gvrSecrets    = schema.GroupVersionResource{Version: "v1", Resource: "secrets"}
	gvrValidating = schema.GroupVersionResource{Group: "admissionregistration.k8s.io", Version: "v1", Resource: "validatingwebhookconfigurations"}
	gvrMutating   = schema.GroupVersionResource{Group: "admissionregistration.k8s.io", Version: "v1", Resource: "mutatingwebhookconfigurations"}
)

// startUpgrade starts every list the checks need, detached from the
// request (see sourceRun). Discovery runs first, inline: which kinds to scan
// for removed APIs depends on the server's version.
func startUpgrade(c *cluster.Clients, ns string) *upgradeLists {
	ctx, cancel := context.WithTimeout(context.Background(), upgradeHardWait)
	l := newSourceRun[upg.Input](ctx, upg.SrcDiscovery, nil, upgradeHardWait, upgradeReuse)
	kc := kcache.For(c)
	set := kube.SplitNamespaces(ns)

	disc, discErr := discoverAPIs(c)
	l.Go(upg.SrcDiscovery, func() (func(*upg.Input), error) {
		if discErr != nil {
			return nil, discErr
		}
		return func(in *upg.Input) { in.ServerVersion, in.Served = disc.version, disc.served }, nil
	})
	if discErr != nil {
		l.sealed(cancel)
		return l
	}

	listInto(l, kc, upg.SrcNodes, gvrNodes, "", "", func(in *upg.Input, v []corev1.Node) { in.Nodes = v })
	listInto(l, kc, upg.SrcPods, gvrPods, ns, "", func(in *upg.Input, v []corev1.Pod) { in.Pods = v })
	listInto(l, kc, upg.SrcDeployments, gvrDeployments, ns, "", func(in *upg.Input, v []appsv1.Deployment) { in.Deployments = v })
	listInto(l, kc, upg.SrcStatefuls, gvrStatefulSets, ns, "", func(in *upg.Input, v []appsv1.StatefulSet) { in.StatefulSets = v })
	listInto(l, kc, upg.SrcDaemonSets, gvrDaemonSets, ns, "", func(in *upg.Input, v []appsv1.DaemonSet) { in.DaemonSets = v })
	listInto(l, kc, upg.SrcPDBs, gvrPDBs, ns, "", func(in *upg.Input, v []policyv1.PodDisruptionBudget) { in.PDBs = v })
	listInto(l, kc, upg.SrcPVCs, gvrPVCs, ns, "", func(in *upg.Input, v []corev1.PersistentVolumeClaim) { in.PVCs = v })
	listInto(l, kc, upg.SrcPVs, gvrPVs, "", "", func(in *upg.Input, v []corev1.PersistentVolume) { in.PVs = v })

	l.Go(upg.SrcControl, func() (func(*upg.Input), error) {
		pods, err := c.Typed.CoreV1().Pods("kube-system").List(ctx, metav1.ListOptions{LabelSelector: "component=kube-apiserver"})
		if err != nil {
			return nil, err
		}
		return func(in *upg.Input) { in.ControlPlane = pods.Items }, nil
	})

	// Webhooks, then the endpoints of the Services they call.
	services := make(chan []upg.ServiceKey, 1)
	l.Go(upg.SrcWebhooks, func() (func(*upg.Input), error) {
		defer close(services)
		val, err := listTyped[admissionv1.ValidatingWebhookConfiguration](ctx, kc, gvrValidating, "", "")
		if err != nil {
			return nil, err
		}
		mut, err := listTyped[admissionv1.MutatingWebhookConfiguration](ctx, kc, gvrMutating, "", "")
		if err != nil {
			return nil, err
		}
		var svcs []upg.ServiceKey
		add := func(cc admissionv1.WebhookClientConfig) {
			if s := cc.Service; s != nil {
				k := upg.ServiceKey(s.Namespace + "/" + s.Name)
				if !slices.Contains(svcs, k) {
					svcs = append(svcs, k)
				}
			}
		}
		for _, v := range val {
			for _, h := range v.Webhooks {
				add(h.ClientConfig)
			}
		}
		for _, v := range mut {
			for _, h := range v.Webhooks {
				add(h.ClientConfig)
			}
		}
		services <- svcs
		return func(in *upg.Input) { in.Validating, in.Mutating = val, mut }, nil
	})
	l.Go(upg.SrcEndpoints, func() (func(*upg.Input), error) {
		svcs, ok := <-services
		if !ok {
			return nil, nil // the webhooks list failed: reported there
		}
		ready, err := readyEndpoints(ctx, c, svcs)
		return func(in *upg.Input) { in.ReadyEndpoints = ready }, err
	})

	l.Go(upg.SrcCRDs, func() (func(*upg.Input), error) {
		crds, err := listCRDInfo(ctx, c)
		if err != nil {
			return nil, err
		}
		return func(in *upg.Input) { in.CRDs = crds }, nil
	})

	cur, _ := upg.ParseVersion(disc.version)
	l.Go(upg.SrcObjects, func() (func(*upg.Input), error) {
		uses, err := scanAPIUses(ctx, c, disc, cur, set)
		return func(in *upg.Input) { in.APIUses = uses }, err
	})
	l.Go(upg.SrcHelm, func() (func(*upg.Input), error) {
		rels, err := latestHelmReleases(ctx, c, set)
		return func(in *upg.Input) { in.Helm = rels }, err
	})
	l.Go(upg.SrcMetrics, func() (func(*upg.Input), error) {
		reqs, err := deprecatedRequests(ctx, c)
		if err != nil {
			return nil, err
		}
		return func(in *upg.Input) { in.Deprecated = reqs }, nil
	})
	l.sealed(cancel)
	return l
}

// apiDiscovery is what discovery says: the version, every served
// apiVersion's resources, and which group/resources are namespaced.
type apiDiscovery struct {
	version    string
	served     map[string][]string
	namespaced map[schema.GroupResource]bool
}

func discoverAPIs(c *cluster.Clients) (apiDiscovery, error) {
	out := apiDiscovery{served: map[string][]string{}, namespaced: map[schema.GroupResource]bool{}}
	v, err := c.Discovery.ServerVersion()
	if err != nil {
		return out, err
	}
	out.version = v.GitVersion
	_, lists, err := c.Discovery.ServerGroupsAndResources()
	if err != nil && !discovery.IsGroupDiscoveryFailedError(err) {
		return out, err
	}
	for _, rl := range lists {
		gv, perr := schema.ParseGroupVersion(rl.GroupVersion)
		if perr != nil {
			continue
		}
		for _, r := range rl.APIResources {
			if strings.Contains(r.Name, "/") {
				continue
			}
			out.served[rl.GroupVersion] = append(out.served[rl.GroupVersion], r.Name)
			out.namespaced[schema.GroupResource{Group: gv.Group, Resource: r.Name}] = r.Namespaced
		}
	}
	return out, nil
}

// scanAPIUses lists, as metadata only, the objects of every kind whose API
// the next three minors remove, and records the managedFields entries and
// last-applied annotations that name one of the table's apiVersions.
func scanAPIUses(ctx context.Context, c *cluster.Clients, disc apiDiscovery, cur upg.Version, set kube.Namespaces) ([]upg.APIUse, error) {
	type target struct {
		gvr        schema.GroupVersionResource
		kind       string
		namespaced bool
	}
	var targets []target
	seen := map[schema.GroupVersionResource]bool{}
	for _, ch := range upg.RemovalsBetween(cur, cur.Plus(3)) {
		if ch.Ephemeral {
			continue
		}
		// Read the objects through the replacement when it is served, else
		// through the old version itself (still served before removal).
		for _, apiVersion := range []string{ch.Replacement, ch.APIVersion()} {
			if apiVersion == "" || !slices.Contains(disc.served[apiVersion], ch.Resource) {
				continue
			}
			gv, _ := schema.ParseGroupVersion(apiVersion)
			gvr := gv.WithResource(ch.Resource)
			if !seen[gvr] {
				seen[gvr] = true
				targets = append(targets, target{gvr, ch.Kind, disc.namespaced[gvr.GroupResource()]})
			}
			break
		}
	}
	var (
		mu       sync.Mutex
		uses     []upg.APIUse
		firstErr error
		ok       bool
	)
	for _, t := range targets {
		nss := []string{""}
		if t.namespaced && len(set) > 0 {
			nss = set
		}
		err := forEachLimited(nss, upgradeParallel, func(ns string) error {
			items, err := listMetadata(ctx, c, t.gvr, ns, "")
			if err != nil {
				return err
			}
			var found []upg.APIUse
			for _, it := range items {
				found = append(found, apiUsesOf(t.gvr.Group, t.kind, it)...)
			}
			mu.Lock()
			uses = append(uses, found...)
			mu.Unlock()
			return nil
		})
		if err != nil && firstErr == nil {
			firstErr = err
		} else if err == nil {
			ok = true
		}
	}
	if !ok && firstErr != nil {
		return nil, firstErr
	}
	if uses == nil {
		uses = []upg.APIUse{}
	}
	return uses, nil
}

// apiUsesOf reads one object's managedFields and last-applied annotation.
func apiUsesOf(group, kind string, o metav1.Object) []upg.APIUse {
	r := security.ObjectRef{Group: group, Kind: kind, Namespace: o.GetNamespace(), Name: o.GetName()}
	var out []upg.APIUse
	for _, mf := range o.GetManagedFields() {
		if _, hit := upg.LookupAPI(mf.APIVersion, kind); hit {
			out = append(out, upg.APIUse{Object: r, APIVersion: mf.APIVersion, Source: "managedFields", Manager: mf.Manager})
		}
	}
	if la := o.GetAnnotations()[corev1.LastAppliedConfigAnnotation]; la != "" {
		var head struct {
			APIVersion string `json:"apiVersion"`
		}
		if json.Unmarshal([]byte(la), &head) == nil {
			if _, hit := upg.LookupAPI(head.APIVersion, kind); hit {
				out = append(out, upg.APIUse{Object: r, APIVersion: head.APIVersion, Source: "last-applied"})
			}
		}
	}
	return out
}

// listMetadata lists gvr in ns ("" = all) as metadata, a page at a time.
func listMetadata(ctx context.Context, c *cluster.Clients, gvr schema.GroupVersionResource, ns, labelSelector string) ([]metav1.Object, error) {
	var out []metav1.Object
	opts := metav1.ListOptions{Limit: 500, LabelSelector: labelSelector}
	for {
		var cont string
		if c.Metadata != nil {
			l, err := c.Metadata.Resource(gvr).Namespace(ns).List(ctx, opts)
			if err != nil {
				return nil, err
			}
			for i := range l.Items {
				out = append(out, &l.Items[i])
			}
			cont = l.Continue
		} else {
			l, err := c.Dynamic.Resource(gvr).Namespace(ns).List(ctx, opts)
			if err != nil {
				return nil, err
			}
			for i := range l.Items {
				out = append(out, &l.Items[i])
			}
			cont = l.GetContinue()
		}
		if cont == "" {
			return out, nil
		}
		opts.Continue = cont
	}
}

// latestHelmReleases finds each release's latest revision from the Helm
// secrets' labels (metadata only), then reads and decodes just those.
func latestHelmReleases(ctx context.Context, c *cluster.Clients, set kube.Namespaces) ([]upg.HelmRelease, error) {
	type latest struct {
		ns, secret string
		version    int
	}
	var (
		mu    sync.Mutex
		byRel = map[string]latest{}
	)
	nss := []string{""}
	if len(set) > 0 {
		nss = set
	}
	if err := forEachLimited(nss, upgradeParallel, func(ns string) error {
		items, err := listMetadata(ctx, c, gvrSecrets, ns, "owner=helm")
		if err != nil {
			return err
		}
		mu.Lock()
		defer mu.Unlock()
		for _, it := range items {
			l := it.GetLabels()
			v, _ := strconv.Atoi(l["version"])
			k := it.GetNamespace() + "/" + l["name"]
			if cur, ok := byRel[k]; !ok || v > cur.version {
				byRel[k] = latest{it.GetNamespace(), it.GetName(), v}
			}
		}
		return nil
	}); err != nil && len(byRel) == 0 {
		return nil, err
	}
	todo := make([]latest, 0, len(byRel))
	for _, v := range byRel {
		todo = append(todo, v)
	}
	out := make([]upg.HelmRelease, 0, len(todo))
	err := forEachLimited(todo, upgradeParallel, func(lt latest) error {
		s, err := c.Typed.CoreV1().Secrets(lt.ns).Get(ctx, lt.secret, metav1.GetOptions{})
		if err != nil {
			return err
		}
		if s.Type != "helm.sh/release.v1" {
			return nil
		}
		rel, err := upg.DecodeHelmRelease(lt.ns, lt.secret, s.Data["release"])
		if err != nil {
			return nil // not a release we can read: skip it
		}
		mu.Lock()
		out = append(out, rel)
		mu.Unlock()
		return nil
	})
	if err != nil && len(out) == 0 && len(todo) > 0 {
		return nil, err
	}
	slices.SortFunc(out, func(a, b upg.HelmRelease) int {
		return strings.Compare(a.Namespace+"/"+a.Name, b.Namespace+"/"+b.Name)
	})
	return out, nil
}

// forEachLimited runs f over items, at most n at once. It returns the first
// error, after every call has finished.
func forEachLimited[T any](items []T, n int, f func(T) error) error {
	sem := make(chan struct{}, n)
	var (
		wg       sync.WaitGroup
		mu       sync.Mutex
		firstErr error
	)
	for _, it := range items {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			if err := f(it); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return firstErr
}

// readyEndpoints counts each Service's ready endpoints from its
// EndpointSlices. A Service whose slices can't be read is left out.
func readyEndpoints(ctx context.Context, c *cluster.Clients, svcs []upg.ServiceKey) (map[upg.ServiceKey]int, error) {
	out := map[upg.ServiceKey]int{}
	var mu sync.Mutex
	err := forEachLimited(svcs, upgradeParallel, func(k upg.ServiceKey) error {
		ns, name, _ := strings.Cut(string(k), "/")
		l, err := c.Typed.DiscoveryV1().EndpointSlices(ns).List(ctx, metav1.ListOptions{LabelSelector: discoveryv1.LabelServiceName + "=" + name})
		if err != nil {
			return err
		}
		n := 0
		for _, s := range l.Items {
			for _, e := range s.Endpoints {
				if e.Conditions.Ready == nil || *e.Conditions.Ready {
					n++
				}
			}
		}
		mu.Lock()
		out[k] = n
		mu.Unlock()
		return nil
	})
	if err != nil && len(out) == 0 && len(svcs) > 0 {
		return out, err
	}
	return out, nil
}

// listCRDInfo pages through the CRDs (which carry whole schemas) keeping
// only their versions.
func listCRDInfo(ctx context.Context, c *cluster.Clients) ([]upg.CRDInfo, error) {
	out := []upg.CRDInfo{}
	opts := metav1.ListOptions{Limit: 100}
	for {
		l, err := c.Dynamic.Resource(cluster.CRDGVR).List(ctx, opts)
		if err != nil {
			return nil, err
		}
		for _, it := range l.Items {
			raw, err := json.Marshal(it.Object)
			if err != nil {
				continue
			}
			var crd struct {
				Metadata struct{ Name string } `json:"metadata"`
				Spec     struct {
					Names    struct{ Kind string } `json:"names"`
					Versions []struct {
						Name       string `json:"name"`
						Served     bool   `json:"served"`
						Storage    bool   `json:"storage"`
						Deprecated bool   `json:"deprecated"`
					} `json:"versions"`
				} `json:"spec"`
				Status struct {
					StoredVersions []string `json:"storedVersions"`
				} `json:"status"`
			}
			if json.Unmarshal(raw, &crd) != nil {
				continue
			}
			info := upg.CRDInfo{Name: crd.Metadata.Name, Kind: crd.Spec.Names.Kind, StoredVersions: crd.Status.StoredVersions}
			for _, v := range crd.Spec.Versions {
				info.Versions = append(info.Versions, upg.CRDVersion{Name: v.Name, Served: v.Served, Storage: v.Storage, Deprecated: v.Deprecated})
			}
			out = append(out, info)
		}
		if l.GetContinue() == "" {
			return out, nil
		}
		opts.Continue = l.GetContinue()
	}
}

// deprecatedSeries matches one apiserver_requested_deprecated_apis sample.
var deprecatedSeries = regexp.MustCompile(`^apiserver_requested_deprecated_apis\{([^}]*)\}\s+(\S+)`)
var metricLabel = regexp.MustCompile(`(\w+)="((?:[^"\\]|\\.)*)"`)

// deprecatedRequests reads the API server's own /metrics (a raw GET, which
// needs the nonResourceURL /metrics; forbidden for most users) for the
// deprecated APIs clients have called.
func deprecatedRequests(ctx context.Context, c *cluster.Clients) ([]upg.DeprecatedRequest, error) {
	rc, ok := c.Typed.Discovery().RESTClient().(*rest.RESTClient)
	if !ok || rc == nil {
		return []upg.DeprecatedRequest{}, nil // fake clients (tests)
	}
	body, err := rc.Get().AbsPath("/metrics").DoRaw(ctx)
	if err != nil {
		return nil, err
	}
	return parseDeprecatedMetric(body), nil
}

func parseDeprecatedMetric(body []byte) []upg.DeprecatedRequest {
	out := []upg.DeprecatedRequest{}
	seen := map[upg.DeprecatedRequest]bool{}
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		m := deprecatedSeries.FindStringSubmatch(sc.Text())
		if m == nil || m[2] == "0" {
			continue
		}
		var d upg.DeprecatedRequest
		for _, kv := range metricLabel.FindAllStringSubmatch(m[1], -1) {
			switch kv[1] {
			case "group":
				d.Group = kv[2]
			case "version":
				d.Version = kv[2]
			case "resource":
				d.Resource = kv[2]
			case "subresource":
				d.Subresource = kv[2]
			case "removed_release":
				d.RemovedRelease = kv[2]
			}
		}
		if !seen[d] {
			seen[d] = true
			out = append(out, d)
		}
	}
	return out
}
