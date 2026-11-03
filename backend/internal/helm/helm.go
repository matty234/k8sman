// Package helm manages Helm v3 releases through the Helm SDK: listing,
// inspecting, diffing revisions, rolling back, upgrading with new values
// (using the chart stored in the release) and uninstalling.
//
// Every function takes an *action.Configuration so tests can use Helm's
// in-memory storage driver and fake kube client.
package helm

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/release"
	"helm.sh/helm/v3/pkg/releaseutil"
	"helm.sh/helm/v3/pkg/storage/driver"
	helmtime "helm.sh/helm/v3/pkg/time"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/yaml"
)

// DefaultTimeout bounds hooks and --wait, like the helm CLI's --timeout.
const DefaultTimeout = 5 * time.Minute

// maxHistory matches the helm CLI's --history-max default.
const maxHistory = 10

// ---- errors ----------------------------------------------------------------

// ErrNotFound is returned when a release or revision doesn't exist.
var ErrNotFound = errors.New("not found")

// ErrInvalid marks a request the server should answer with 400/422.
var ErrInvalid = errors.New("invalid request")

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

// StuckError means the release's latest revision is pending-install,
// pending-upgrade or pending-rollback. Helm treats that as a lock: every
// further upgrade fails with "another operation is in progress" until the
// release is rolled back (or, for a first install, uninstalled).
type StuckError struct {
	Name     string `json:"name"`
	Status   string `json:"status"`
	Revision int    `json:"revision"`
	// RollbackTo is the last good revision to roll back to; 0 = none (uninstall instead).
	RollbackTo int    `json:"rollbackTo"`
	Remedy     string `json:"remedy"`
}

func (e *StuckError) Error() string {
	return fmt.Sprintf("release %q is stuck in %s at revision %d: a previous helm operation was interrupted, and Helm refuses further upgrades until it is resolved. %s",
		e.Name, e.Status, e.Revision, e.Remedy)
}

// stuckInfo reports whether the latest revision in history is pending.
func stuckInfo(history []*release.Release) *StuckError {
	if len(history) == 0 {
		return nil
	}
	releaseutil.SortByRevision(history)
	last := history[len(history)-1]
	if last.Info == nil || !last.Info.Status.IsPending() {
		return nil
	}
	e := &StuckError{Name: last.Name, Status: last.Info.Status.String(), Revision: last.Version}
	// Prefer the revision still marked deployed, else the newest superseded one.
	for _, want := range []release.Status{release.StatusDeployed, release.StatusSuperseded} {
		for i := len(history) - 2; i >= 0 && e.RollbackTo == 0; i-- {
			if history[i].Info != nil && history[i].Info.Status == want {
				e.RollbackTo = history[i].Version
			}
		}
	}
	if e.RollbackTo > 0 {
		e.Remedy = fmt.Sprintf("Roll back to revision %d (the last deployed revision) to recover.", e.RollbackTo)
	} else {
		e.Remedy = "There is no earlier deployed revision to roll back to; uninstall the release and install it again."
	}
	return e
}

func notFound(err error, what string) error {
	if errors.Is(err, driver.ErrReleaseNotFound) || errors.Is(err, driver.ErrNoDeployedReleases) {
		return fmt.Errorf("%w: %s", ErrNotFound, what)
	}
	return err
}

// ---- models ----------------------------------------------------------------

// ReleaseSummary is one row of the releases list or the history table.
type ReleaseSummary struct {
	Name         string `json:"name"`
	Namespace    string `json:"namespace"`
	Revision     int    `json:"revision"`
	Status       string `json:"status"`
	Chart        string `json:"chart"`
	ChartVersion string `json:"chartVersion"`
	AppVersion   string `json:"appVersion,omitempty"`
	Updated      string `json:"updated,omitempty"`
	Description  string `json:"description,omitempty"`
}

// ListResult is GET /api/helm/releases.
type ListResult struct {
	Releases []ReleaseSummary `json:"releases"`
	Total    int              `json:"total"`
	Failed   int              `json:"failed"`
	Pending  int              `json:"pending"`
}

// ChartInfo is the chart metadata stored with a release.
type ChartInfo struct {
	Name         string            `json:"name"`
	Version      string            `json:"version"`
	AppVersion   string            `json:"appVersion,omitempty"`
	Description  string            `json:"description,omitempty"`
	Home         string            `json:"home,omitempty"`
	Sources      []string          `json:"sources,omitempty"`
	Icon         string            `json:"icon,omitempty"`
	APIVersion   string            `json:"apiVersion,omitempty"`
	Type         string            `json:"type,omitempty"`
	Keywords     []string          `json:"keywords,omitempty"`
	Deprecated   bool              `json:"deprecated,omitempty"`
	KubeVersion  string            `json:"kubeVersion,omitempty"`
	Dependencies []ChartDependency `json:"dependencies"`
}

// ChartDependency is a Chart.yaml dependency (subchart).
type ChartDependency struct {
	Name       string `json:"name"`
	Version    string `json:"version,omitempty"`
	Repository string `json:"repository,omitempty"`
	Condition  string `json:"condition,omitempty"`
	Alias      string `json:"alias,omitempty"`
	// Embedded is false when the subchart isn't stored with the release
	// (Helm doesn't persist subcharts), which blocks upgrades from here.
	Embedded bool `json:"embedded"`
}

// HookInfo is a chart hook and its last run.
type HookInfo struct {
	Name           string   `json:"name"`
	Kind           string   `json:"kind"`
	Group          string   `json:"group"`
	Path           string   `json:"path,omitempty"`
	Events         []string `json:"events"`
	Weight         int      `json:"weight"`
	DeletePolicies []string `json:"deletePolicies,omitempty"`
	Phase          string   `json:"phase,omitempty"`
	StartedAt      string   `json:"startedAt,omitempty"`
	CompletedAt    string   `json:"completedAt,omitempty"`
	Manifest       string   `json:"manifest,omitempty"`
}

// Resource is an object rendered into a release manifest.
type Resource struct {
	Group     string `json:"group"`
	Version   string `json:"version"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace,omitempty"`
}

// Detail is GET /api/helm/release.
type Detail struct {
	ReleaseSummary
	LatestRevision int         `json:"latestRevision"`
	FirstDeployed  string      `json:"firstDeployed,omitempty"`
	LastDeployed   string      `json:"lastDeployed,omitempty"`
	Notes          string      `json:"notes,omitempty"`
	ChartInfo      ChartInfo   `json:"chartInfo"`
	Values         string      `json:"values"`
	ComputedValues string      `json:"computedValues"`
	Manifest       string      `json:"manifest"`
	Hooks          []HookInfo  `json:"hooks"`
	Resources      []Resource  `json:"resources"`
	Stuck          *StuckError `json:"stuck,omitempty"`
	// UpgradeBlocked explains why "upgrade with new values" isn't possible
	// from the stored chart (e.g. missing subcharts); empty when it is.
	UpgradeBlocked string `json:"upgradeBlocked,omitempty"`
}

// RevisionText is one side of a diff.
type RevisionText struct {
	Revision int    `json:"revision"`
	Status   string `json:"status"`
	Chart    string `json:"chart"`
	Manifest string `json:"manifest"`
	Values   string `json:"values"`
}

// DiffResult is GET /api/helm/diff.
type DiffResult struct {
	Name      string       `json:"name"`
	Namespace string       `json:"namespace"`
	From      RevisionText `json:"from"`
	To        RevisionText `json:"to"`
}

// ---- helpers ---------------------------------------------------------------

func ts(t helmtime.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func summarize(r *release.Release) ReleaseSummary {
	s := ReleaseSummary{Name: r.Name, Namespace: r.Namespace, Revision: r.Version}
	if r.Info != nil {
		s.Status = r.Info.Status.String()
		s.Updated = ts(r.Info.LastDeployed)
		s.Description = r.Info.Description
	}
	if r.Chart != nil && r.Chart.Metadata != nil {
		s.Chart = r.Chart.Metadata.Name
		s.ChartVersion = r.Chart.Metadata.Version
		s.AppVersion = r.Chart.Metadata.AppVersion
	}
	return s
}

func valuesYAML(v map[string]any) (string, error) {
	if len(v) == 0 {
		return "", nil
	}
	b, err := yaml.Marshal(v)
	return string(b), err
}

// ---- reads -----------------------------------------------------------------

// List returns the latest revision of every release visible to cfg, in all
// states (including pending and failed), sorted by namespace then name.
func List(cfg *action.Configuration) (*ListResult, error) {
	l := action.NewList(cfg)
	l.All = true
	l.AllNamespaces = true
	l.SetStateMask()
	rels, err := l.Run()
	if err != nil {
		return nil, err
	}
	out := &ListResult{Releases: make([]ReleaseSummary, 0, len(rels))}
	for _, r := range rels {
		s := summarize(r)
		out.Releases = append(out.Releases, s)
		switch {
		case r.Info != nil && r.Info.Status == release.StatusFailed:
			out.Failed++
		case r.Info != nil && r.Info.Status.IsPending():
			out.Pending++
		}
	}
	sort.SliceStable(out.Releases, func(i, j int) bool {
		a, b := out.Releases[i], out.Releases[j]
		if a.Namespace != b.Namespace {
			return a.Namespace < b.Namespace
		}
		return a.Name < b.Name
	})
	out.Total = len(out.Releases)
	return out, nil
}

// History returns every stored revision of a release, newest first.
func History(cfg *action.Configuration, name string) ([]ReleaseSummary, error) {
	rels, err := cfg.Releases.History(name)
	if err != nil {
		return nil, notFound(err, fmt.Sprintf("release %q", name))
	}
	if len(rels) == 0 {
		return nil, fmt.Errorf("%w: release %q", ErrNotFound, name)
	}
	releaseutil.Reverse(rels, releaseutil.SortByRevision)
	out := make([]ReleaseSummary, 0, len(rels))
	for _, r := range rels {
		out = append(out, summarize(r))
	}
	return out, nil
}

func getRevision(cfg *action.Configuration, name string, revision int) (*release.Release, error) {
	var (
		r   *release.Release
		err error
	)
	if revision > 0 {
		r, err = cfg.Releases.Get(name, revision)
	} else {
		r, err = cfg.Releases.Last(name)
	}
	if err != nil {
		what := fmt.Sprintf("release %q", name)
		if revision > 0 {
			what = fmt.Sprintf("release %q revision %d", name, revision)
		}
		return nil, notFound(err, what)
	}
	return r, nil
}

// Get returns one revision (0 = latest) with chart info, values, manifest,
// hooks and the resources in the manifest. mapper (may be nil) decides
// whether each kind is namespaced; without it a list of well-known
// cluster-scoped kinds is used.
func Get(cfg *action.Configuration, name string, revision int, mapper meta.RESTMapper) (*Detail, error) {
	r, err := getRevision(cfg, name, revision)
	if err != nil {
		return nil, err
	}
	history, err := cfg.Releases.History(name)
	if err != nil {
		return nil, notFound(err, fmt.Sprintf("release %q", name))
	}
	d := &Detail{ReleaseSummary: summarize(r), Manifest: r.Manifest, Hooks: []HookInfo{}}
	for _, h := range history {
		d.LatestRevision = max(d.LatestRevision, h.Version)
	}
	if r.Info != nil {
		d.FirstDeployed = ts(r.Info.FirstDeployed)
		d.LastDeployed = ts(r.Info.LastDeployed)
		d.Notes = r.Info.Notes
	}
	d.ChartInfo = chartInfo(r.Chart)
	if d.Values, err = valuesYAML(r.Config); err != nil {
		return nil, err
	}
	if r.Chart != nil {
		computed, err := chartutil.CoalesceValues(r.Chart, r.Config)
		if err != nil {
			return nil, err
		}
		if d.ComputedValues, err = valuesYAML(computed); err != nil {
			return nil, err
		}
	}
	for _, h := range r.Hooks {
		d.Hooks = append(d.Hooks, hookInfo(h))
	}
	sort.SliceStable(d.Hooks, func(i, j int) bool { return d.Hooks[i].Weight < d.Hooks[j].Weight })
	d.Resources = ParseResources(r.Manifest, r.Namespace, mapper)
	d.Stuck = stuckInfo(history)
	d.UpgradeBlocked = upgradeBlocked(r)
	return d, nil
}

func chartInfo(c *chart.Chart) ChartInfo {
	ci := ChartInfo{Dependencies: []ChartDependency{}}
	if c == nil || c.Metadata == nil {
		return ci
	}
	m := c.Metadata
	ci = ChartInfo{
		Name: m.Name, Version: m.Version, AppVersion: m.AppVersion, Description: m.Description,
		Home: m.Home, Sources: m.Sources, Icon: m.Icon, APIVersion: m.APIVersion, Type: m.Type,
		Keywords: m.Keywords, Deprecated: m.Deprecated, KubeVersion: m.KubeVersion,
		Dependencies: []ChartDependency{},
	}
	embedded := map[string]bool{}
	for _, d := range c.Dependencies() {
		if d.Metadata != nil {
			embedded[d.Metadata.Name] = true
		}
	}
	for _, d := range m.Dependencies {
		if d == nil {
			continue
		}
		ci.Dependencies = append(ci.Dependencies, ChartDependency{
			Name: d.Name, Version: d.Version, Repository: d.Repository, Condition: d.Condition, Alias: d.Alias,
			Embedded: embedded[d.Name],
		})
	}
	return ci
}

func hookInfo(h *release.Hook) HookInfo {
	hi := HookInfo{Name: h.Name, Kind: h.Kind, Path: h.Path, Weight: h.Weight, Manifest: h.Manifest, Events: []string{}}
	for _, e := range h.Events {
		hi.Events = append(hi.Events, e.String())
	}
	for _, p := range h.DeletePolicies {
		hi.DeletePolicies = append(hi.DeletePolicies, p.String())
	}
	if res := ParseResources(h.Manifest, "", nil); len(res) > 0 {
		hi.Group = res[0].Group
	}
	hi.Phase = h.LastRun.Phase.String()
	if !h.LastRun.StartedAt.IsZero() {
		hi.StartedAt = ts(h.LastRun.StartedAt)
	}
	if !h.LastRun.CompletedAt.IsZero() {
		hi.CompletedAt = ts(h.LastRun.CompletedAt)
	}
	return hi
}

// Diff returns the manifests and user values of two revisions. to = 0 means
// the latest revision; from = 0 means the revision before to.
func Diff(cfg *action.Configuration, name string, from, to int) (*DiffResult, error) {
	b, err := getRevision(cfg, name, to)
	if err != nil {
		return nil, err
	}
	if from == 0 {
		from = b.Version - 1
	}
	if from < 1 {
		return nil, invalid("release %q has no revision before %d", name, b.Version)
	}
	a, err := getRevision(cfg, name, from)
	if err != nil {
		return nil, err
	}
	side := func(r *release.Release) (RevisionText, error) {
		s := summarize(r)
		v, err := valuesYAML(r.Config)
		return RevisionText{Revision: r.Version, Status: s.Status, Chart: s.Chart + "-" + s.ChartVersion, Manifest: r.Manifest, Values: v}, err
	}
	out := &DiffResult{Name: name, Namespace: b.Namespace}
	if out.From, err = side(a); err != nil {
		return nil, err
	}
	if out.To, err = side(b); err != nil {
		return nil, err
	}
	return out, nil
}

// ---- manifest parsing ------------------------------------------------------

var docSep = regexp.MustCompile(`(?m)^---[ \t]*$`)

// clusterScoped is the fallback when no RESTMapper is available.
var clusterScoped = map[string]bool{
	"/Namespace": true, "/Node": true, "/PersistentVolume": true,
	"rbac.authorization.k8s.io/ClusterRole": true, "rbac.authorization.k8s.io/ClusterRoleBinding": true,
	"apiextensions.k8s.io/CustomResourceDefinition": true, "storage.k8s.io/StorageClass": true,
	"storage.k8s.io/CSIDriver": true, "networking.k8s.io/IngressClass": true, "scheduling.k8s.io/PriorityClass": true,
	"admissionregistration.k8s.io/ValidatingWebhookConfiguration": true,
	"admissionregistration.k8s.io/MutatingWebhookConfiguration":   true,
	"apiregistration.k8s.io/APIService":                           true, "node.k8s.io/RuntimeClass": true,
}

// ParseResources lists the objects in a rendered manifest. Objects without a
// namespace get defaultNS unless their kind is cluster-scoped.
func ParseResources(manifest, defaultNS string, mapper meta.RESTMapper) []Resource {
	out := []Resource{}
	for _, doc := range docSep.Split(manifest, -1) {
		if strings.TrimSpace(doc) == "" {
			continue
		}
		var obj struct {
			APIVersion string `json:"apiVersion"`
			Kind       string `json:"kind"`
			Metadata   struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"metadata"`
		}
		if err := yaml.Unmarshal([]byte(doc), &obj); err != nil || obj.Kind == "" || obj.Metadata.Name == "" {
			continue
		}
		gv, err := schema.ParseGroupVersion(obj.APIVersion)
		if err != nil {
			continue
		}
		r := Resource{Group: gv.Group, Version: gv.Version, Kind: obj.Kind, Name: obj.Metadata.Name, Namespace: obj.Metadata.Namespace}
		if r.Namespace == "" && namespaced(mapper, gv.WithKind(obj.Kind)) {
			r.Namespace = defaultNS
		}
		if r.Namespace != "" && !namespaced(mapper, gv.WithKind(obj.Kind)) {
			r.Namespace = ""
		}
		out = append(out, r)
	}
	return out
}

func namespaced(mapper meta.RESTMapper, gvk schema.GroupVersionKind) bool {
	if mapper != nil {
		if m, err := mapper.RESTMapping(gvk.GroupKind(), gvk.Version); err == nil {
			return m.Scope.Name() == meta.RESTScopeNameNamespace
		}
	}
	return !clusterScoped[gvk.Group+"/"+gvk.Kind]
}

// ---- mutations -------------------------------------------------------------

// RollbackRequest is POST /api/helm/rollback.
type RollbackRequest struct {
	Namespace      string `json:"namespace"`
	Name           string `json:"name"`
	Revision       int    `json:"revision"`
	DryRun         bool   `json:"dryRun"`
	Wait           bool   `json:"wait"`
	TimeoutSeconds int    `json:"timeoutSeconds"`
}

// UninstallRequest is POST /api/helm/uninstall.
type UninstallRequest struct {
	Namespace   string `json:"namespace"`
	Name        string `json:"name"`
	KeepHistory bool   `json:"keepHistory"`
	DryRun      bool   `json:"dryRun"`
}

// UpgradeRequest is POST /api/helm/upgrade.
type UpgradeRequest struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	// Values is the complete new set of user-supplied values (YAML).
	Values string `json:"values"`
	// ReuseValues merges Values over the release's current user values.
	ReuseValues bool `json:"reuseValues"`
	// Repo and Chart (and Version, "" = latest) upgrade to a chart fetched
	// like Install does, instead of re-rendering the stored chart.
	Repo           string `json:"repo,omitempty"`
	Chart          string `json:"chart,omitempty"`
	Version        string `json:"version,omitempty"`
	DryRun         bool   `json:"dryRun"`
	Wait           bool   `json:"wait"`
	TimeoutSeconds int    `json:"timeoutSeconds"`
}

// Result is returned by every mutation.
type Result struct {
	Message string          `json:"message"`
	DryRun  bool            `json:"dryRun"`
	Release *ReleaseSummary `json:"release,omitempty"`
	// Upgrade only: the rendered manifest (the dry-run result) and the
	// current one, so the UI can diff them before applying.
	Manifest        string `json:"manifest,omitempty"`
	CurrentManifest string `json:"currentManifest,omitempty"`
	Notes           string `json:"notes,omitempty"`
}

func timeout(seconds int) time.Duration {
	if seconds > 0 {
		return time.Duration(seconds) * time.Second
	}
	return DefaultTimeout
}

// Rollback rolls a release back to a revision (0 = the previous one). It is
// also the remedy for a release stuck in a pending state.
func Rollback(cfg *action.Configuration, req RollbackRequest) (*Result, error) {
	if req.Name == "" || req.Revision < 0 {
		return nil, invalid("name and a non-negative revision are required")
	}
	cur, err := getRevision(cfg, req.Name, 0)
	if err != nil {
		return nil, err
	}
	target := req.Revision
	if target == 0 {
		target = cur.Version - 1
	}
	if _, err := getRevision(cfg, req.Name, target); err != nil {
		return nil, err
	}
	rb := action.NewRollback(cfg)
	rb.Version = target
	rb.DryRun = req.DryRun
	rb.Wait = req.Wait
	rb.Timeout = timeout(req.TimeoutSeconds)
	rb.MaxHistory = maxHistory
	if err := rb.Run(req.Name); err != nil {
		return nil, err
	}
	res := &Result{DryRun: req.DryRun}
	if req.DryRun {
		res.Message = fmt.Sprintf("Dry run: %s would be rolled back from revision %d to %d", req.Name, cur.Version, target)
		return res, nil
	}
	if r, err := cfg.Releases.Last(req.Name); err == nil {
		s := summarize(r)
		res.Release = &s
	}
	res.Message = fmt.Sprintf("Rolled back %s to revision %d", req.Name, target)
	return res, nil
}

// Uninstall removes a release (optionally keeping its history).
func Uninstall(cfg *action.Configuration, req UninstallRequest) (*Result, error) {
	if req.Name == "" {
		return nil, invalid("name is required")
	}
	if _, err := getRevision(cfg, req.Name, 0); err != nil {
		return nil, err
	}
	u := action.NewUninstall(cfg)
	u.DryRun = req.DryRun
	u.KeepHistory = req.KeepHistory
	u.Timeout = DefaultTimeout
	resp, err := u.Run(req.Name)
	if err != nil {
		return nil, err
	}
	res := &Result{DryRun: req.DryRun}
	if resp != nil && resp.Release != nil {
		s := summarize(resp.Release)
		res.Release = &s
	}
	switch {
	case req.DryRun:
		res.Message = fmt.Sprintf("Dry run: %s would be uninstalled", req.Name)
	case req.KeepHistory:
		res.Message = fmt.Sprintf("Uninstalled %s (history kept)", req.Name)
	default:
		res.Message = fmt.Sprintf("Uninstalled %s", req.Name)
	}
	if resp != nil && resp.Info != "" {
		res.Message += ". " + resp.Info
	}
	return res, nil
}

// subchartSource matches manifest "# Source: <chart>/charts/<sub>/..." comments.
var subchartSource = regexp.MustCompile(`(?m)^# Source: [^/\s]+/charts/([^/\s]+)/`)

// upgradeBlocked explains why the stored chart can't be re-rendered safely.
// Helm doesn't persist subcharts in the release, so re-rendering a chart
// whose subcharts produced resources would silently delete them.
func upgradeBlocked(r *release.Release) string {
	if r.Chart == nil || r.Chart.Metadata == nil {
		return "the release has no stored chart"
	}
	embedded := map[string]bool{}
	for _, d := range r.Chart.Dependencies() {
		if d.Metadata != nil {
			embedded[d.Metadata.Name] = true
		}
	}
	var missing []string
	seen := map[string]bool{}
	for _, m := range subchartSource.FindAllStringSubmatch(r.Manifest, -1) {
		if !embedded[m[1]] && !seen[m[1]] {
			seen[m[1]] = true
			missing = append(missing, m[1])
		}
	}
	if len(missing) == 0 {
		return ""
	}
	return fmt.Sprintf("this release uses subcharts (%s) that Helm doesn't store with the release, so upgrading from the stored chart would delete their resources. Upgrade from the chart source with the helm CLI instead",
		strings.Join(missing, ", "))
}

// Upgrade re-renders the release's current chart with new user values (no
// repository fetch). With DryRun the rendered manifest is returned so it
// can be reviewed against the current one.
func Upgrade(ctx context.Context, cfg *action.Configuration, req UpgradeRequest) (*Result, error) {
	if req.Name == "" {
		return nil, invalid("name is required")
	}
	vals := map[string]any{}
	if strings.TrimSpace(req.Values) != "" {
		if err := yaml.Unmarshal([]byte(req.Values), &vals); err != nil {
			return nil, invalid("values are not valid YAML: %v", err)
		}
		if vals == nil {
			vals = map[string]any{}
		}
	}
	history, err := cfg.Releases.History(req.Name)
	if err != nil || len(history) == 0 {
		return nil, notFound(driver.ErrReleaseNotFound, fmt.Sprintf("release %q", req.Name))
	}
	if stuck := stuckInfo(history); stuck != nil {
		return nil, stuck
	}
	releaseutil.SortByRevision(history)
	last := history[len(history)-1]
	base := last
	if dep, err := cfg.Releases.Deployed(req.Name); err == nil {
		base = dep
	}
	fromSource := strings.TrimSpace(req.Repo) != ""
	if fromSource {
		if err := useRegistryClient(cfg); err != nil {
			return nil, err
		}
	} else if msg := upgradeBlocked(base); msg != "" {
		return nil, invalid("%s", msg)
	}
	up := action.NewUpgrade(cfg)
	ch := base.Chart
	up.Description = "Upgraded values from k8sman"
	if fromSource {
		if ch, err = fetchChart(&up.ChartPathOptions, req.Repo, req.Chart, req.Version); err != nil {
			return nil, err
		}
		up.Description = fmt.Sprintf("Upgraded to %s %s from k8sman", ch.Name(), ch.Metadata.Version)
	}
	up.Namespace = base.Namespace
	up.DryRun = req.DryRun
	if req.DryRun {
		up.DryRunOption = "client"
	}
	up.ReuseValues = req.ReuseValues
	up.ResetValues = !req.ReuseValues
	up.Wait = req.Wait
	up.Timeout = timeout(req.TimeoutSeconds)
	up.MaxHistory = maxHistory
	rel, err := up.RunWithContext(ctx, req.Name, ch, vals)
	if err != nil {
		return nil, err
	}
	s := summarize(rel)
	res := &Result{DryRun: req.DryRun, Release: &s, Manifest: rel.Manifest, CurrentManifest: last.Manifest}
	if rel.Info != nil {
		res.Notes = rel.Info.Notes
	}
	if req.DryRun {
		res.Message = fmt.Sprintf("Dry run: rendered revision %d of %s", rel.Version, req.Name)
	} else {
		res.Message = fmt.Sprintf("Upgraded %s to revision %d (%s)", req.Name, rel.Version, s.Status)
	}
	return res, nil
}
