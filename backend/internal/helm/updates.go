package helm

// "Upgrade available" for installed releases: a newer version of the same
// chart in a configured repository (one whose index also lists the
// installed version), else, when the user allows it, on Artifact Hub.

import (
	"context"
	"sync"
	"time"

	"github.com/Masterminds/semver/v3"
)

// ChartQuery is an installed chart and version.
type ChartQuery struct {
	Chart   string `json:"chart"`
	Version string `json:"version"`
}

// Key is how GET /api/helm/updates keys its answers: "chart@version".
func (q ChartQuery) Key() string { return q.Chart + "@" + q.Version }

// Update is a newer chart version for an installed one.
type Update struct {
	Chart     string `json:"chart"`
	Installed string `json:"installed"`
	Latest    string `json:"latest"`
	// Source is "repo" or "artifacthub"; Repo its repository name and
	// RepoURL what to upgrade from (https repository or oci:// reference).
	Source  string `json:"source"`
	Repo    string `json:"repo"`
	RepoURL string `json:"repoURL"`
}

const updatesTTL = 30 * time.Minute

var updateCache = struct {
	sync.Mutex
	m map[string]updateEntry
}{m: map[string]updateEntry{}}

type updateEntry struct {
	at time.Time
	u  *Update // nil = none found
}

func newerThan(latest, installed string) bool {
	a, err1 := semver.NewVersion(latest)
	b, err2 := semver.NewVersion(installed)
	return err1 == nil && err2 == nil && a.GreaterThan(b)
}

func sameVersion(a, b string) bool {
	if a == b {
		return true
	}
	x, err1 := semver.NewVersion(a)
	y, err2 := semver.NewVersion(b)
	return err1 == nil && err2 == nil && x.Equal(y)
}

// FindUpdates looks up a newer version for each query. Local repository
// indexes are always checked; Artifact Hub only when artifactHub is set.
// Answers (including "none") are cached; lookups that fail are not.
func FindUpdates(ctx context.Context, queries []ChartQuery, artifactHub bool) map[string]Update {
	out := map[string]Update{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	seen := map[string]bool{}
	for _, q := range queries {
		if q.Chart == "" || q.Version == "" || seen[q.Key()] {
			continue
		}
		seen[q.Key()] = true
		cacheKey := q.Key()
		if artifactHub {
			cacheKey += "\x00ah"
		}
		updateCache.Lock()
		e, ok := updateCache.m[cacheKey]
		updateCache.Unlock()
		if ok && time.Since(e.at) < updatesTTL {
			if e.u != nil {
				out[q.Key()] = *e.u
			}
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			u, definitive := findUpdate(ctx, q, artifactHub)
			if definitive {
				updateCache.Lock()
				updateCache.m[cacheKey] = updateEntry{time.Now(), u}
				updateCache.Unlock()
			}
			if u != nil {
				mu.Lock()
				out[q.Key()] = *u
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return out
}

// findUpdate returns the update (nil = none) and whether the answer is
// definitive (worth caching).
func findUpdate(ctx context.Context, q ChartQuery, artifactHub bool) (*Update, bool) {
	if u, matched := localUpdate(q); matched {
		return u, true
	}
	if !artifactHub {
		return nil, true
	}
	return artifactHubUpdate(ctx, q)
}

// localUpdate checks the configured repositories that list the installed
// version of the chart. matched is false when none does.
func localUpdate(q ChartQuery) (best *Update, matched bool) {
	s := UserSettings()
	f, err := loadRepoFile(s.RepositoryConfig)
	if err != nil {
		return nil, false
	}
	pre := isPrerelease(q.Version)
	for _, e := range f.Repositories {
		if e == nil {
			continue
		}
		idx, err := cachedRepoIndex(s, e.Name)
		if err != nil || idx == nil {
			continue
		}
		vs := idx.Entries[q.Chart]
		has := false
		for _, v := range vs {
			if v != nil && sameVersion(v.Version, q.Version) {
				has = true
				break
			}
		}
		if !has {
			continue
		}
		matched = true
		var latest string
		for _, v := range vs { // newest first
			if v != nil && (pre || !isPrerelease(v.Version)) {
				latest = v.Version
				break
			}
		}
		if newerThan(latest, q.Version) && (best == nil || newerThan(latest, best.Latest)) {
			best = &Update{Chart: q.Chart, Installed: q.Version, Latest: latest, Source: "repo", Repo: e.Name, RepoURL: e.URL}
		}
	}
	return best, matched
}

// artifactHubUpdate finds the package of that name (among the first few
// search results) whose versions include the installed one.
func artifactHubUpdate(ctx context.Context, q ChartQuery) (*Update, bool) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	res, err := SearchArtifactHub(ctx, q.Chart, 0, 20)
	if err != nil {
		return nil, false
	}
	pre := isPrerelease(q.Version)
	checked := 0
	for _, p := range res.Packages {
		if p.Name != q.Chart || checked >= 3 {
			continue
		}
		checked++
		d, err := ArtifactHubPackage(ctx, p.Repo, p.Name, "")
		if err != nil {
			return nil, false
		}
		has := false
		for _, v := range d.Versions {
			if sameVersion(v.Version, q.Version) {
				has = true
				break
			}
		}
		if !has {
			continue
		}
		for _, v := range d.Versions { // newest first
			if pre || !v.Prerelease {
				if newerThan(v.Version, q.Version) {
					return &Update{Chart: q.Chart, Installed: q.Version, Latest: v.Version, Source: "artifacthub", Repo: d.Repo, RepoURL: d.RepoURL}, true
				}
				return nil, true
			}
		}
		return nil, true
	}
	return nil, true
}
