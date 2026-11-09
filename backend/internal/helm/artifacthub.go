package helm

// A small client for Artifact Hub's public API (https://artifacthub.io/docs/api/):
// package search, package detail (readme, versions, repository URL) and
// default values. Search terms go to a third party, so the server only
// calls it when the user opted in. Responses are cached in memory.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/Masterminds/semver/v3"
)

// ArtifactHubURL is the API host. A variable so tests can use a fake server.
var ArtifactHubURL = "https://artifacthub.io"

const (
	ahTimeout  = 15 * time.Second
	ahCacheTTL = 10 * time.Minute
	ahMaxBody  = 16 << 20
	ahMaxCache = 256
	// ahKindHelm is the repository kind of Helm charts.
	ahKindHelm = 0
)

var ahHTTP = &http.Client{Timeout: ahTimeout}

type ahCached struct {
	at    time.Time
	body  []byte
	total int
}

var ahCache = struct {
	sync.Mutex
	m map[string]ahCached
}{m: map[string]ahCached{}}

// ahGet fetches path?query from Artifact Hub (cached for ahCacheTTL). total
// is the Pagination-Total-Count header, when present.
func ahGet(ctx context.Context, path string, query url.Values) (body []byte, total int, err error) {
	u := ArtifactHubURL + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	ahCache.Lock()
	c, ok := ahCache.m[u]
	ahCache.Unlock()
	if ok && time.Since(c.at) < ahCacheTTL {
		return c.body, c.total, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("User-Agent", UserAgent)
	req.Header.Set("Accept", "application/json, application/yaml;q=0.9")
	res, err := ahHTTP.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("cannot reach Artifact Hub: %w", err)
	}
	defer res.Body.Close()
	body, err = io.ReadAll(io.LimitReader(res.Body, ahMaxBody))
	if err != nil {
		return nil, 0, fmt.Errorf("read Artifact Hub response: %w", err)
	}
	switch {
	case res.StatusCode == http.StatusNotFound:
		return nil, 0, fmt.Errorf("%w: not on Artifact Hub", ErrNotFound)
	case res.StatusCode == http.StatusTooManyRequests:
		return nil, 0, fmt.Errorf("Artifact Hub is rate limiting requests; try again in a minute")
	case res.StatusCode >= 400:
		return nil, 0, fmt.Errorf("Artifact Hub answered %s", res.Status)
	}
	total, _ = strconv.Atoi(res.Header.Get("Pagination-Total-Count"))
	ahCache.Lock()
	if len(ahCache.m) >= ahMaxCache {
		for k, v := range ahCache.m {
			if time.Since(v.at) >= ahCacheTTL || len(ahCache.m) >= ahMaxCache {
				delete(ahCache.m, k)
			}
		}
	}
	ahCache.m[u] = ahCached{time.Now(), body, total}
	ahCache.Unlock()
	return body, total, nil
}

// ---- wire shapes (snake_case, as documented) --------------------------------

type ahRepository struct {
	RepositoryID            string `json:"repository_id"`
	Name                    string `json:"name"`
	DisplayName             string `json:"display_name"`
	URL                     string `json:"url"`
	Kind                    int    `json:"kind"`
	Official                bool   `json:"official"`
	VerifiedPublisher       bool   `json:"verified_publisher"`
	OrganizationName        string `json:"organization_name"`
	OrganizationDisplayName string `json:"organization_display_name"`
	UserAlias               string `json:"user_alias"`
}

type ahPackageSummary struct {
	PackageID   string       `json:"package_id"`
	Name        string       `json:"name"`
	Description string       `json:"description"`
	LogoImageID string       `json:"logo_image_id"`
	Version     string       `json:"version"`
	AppVersion  string       `json:"app_version"`
	Deprecated  bool         `json:"deprecated"`
	Stars       int          `json:"stars"`
	Official    bool         `json:"official"`
	Repository  ahRepository `json:"repository"`
}

type ahPackage struct {
	ahPackageSummary
	Readme            string       `json:"readme"`
	HomeURL           string       `json:"home_url"`
	License           string       `json:"license"`
	Keywords          []string     `json:"keywords"`
	ContentURL        string       `json:"content_url"`
	Links             []Link       `json:"links"`
	Maintainers       []Maintainer `json:"maintainers"`
	AvailableVersions []struct {
		Version    string `json:"version"`
		AppVersion string `json:"app_version"`
		Prerelease bool   `json:"prerelease"`
		TS         int64  `json:"ts"`
	} `json:"available_versions"`
	Data struct {
		Type        string `json:"type"`
		KubeVersion string `json:"kubeVersion"`
	} `json:"data"`
}

func ahLogo(id string) string {
	if id == "" {
		return ""
	}
	return ArtifactHubURL + "/image/" + url.PathEscape(id)
}

// ---- API -------------------------------------------------------------------

// AHPackage is one search result of GET /api/helm/artifacthub/search.
type AHPackage struct {
	PackageID   string `json:"packageId"`
	Name        string `json:"name"`
	Version     string `json:"version"`
	AppVersion  string `json:"appVersion,omitempty"`
	Description string `json:"description,omitempty"`
	Icon        string `json:"icon,omitempty"`
	Stars       int    `json:"stars"`
	Deprecated  bool   `json:"deprecated,omitempty"`
	Repo        string `json:"repo"`
	RepoDisplay string `json:"repoDisplay,omitempty"`
	RepoURL     string `json:"repoURL"`
	Publisher   string `json:"publisher,omitempty"`
	Official    bool   `json:"official,omitempty"`
	Verified    bool   `json:"verified,omitempty"`
}

// AHSearch is GET /api/helm/artifacthub/search.
type AHSearch struct {
	Packages []AHPackage `json:"packages"`
	Total    int         `json:"total"`
}

// SearchArtifactHub searches Helm charts (kind 0) on Artifact Hub.
func SearchArtifactHub(ctx context.Context, q string, offset, limit int) (*AHSearch, error) {
	if limit <= 0 || limit > 60 {
		limit = 60
	}
	params := url.Values{
		"kind": {strconv.Itoa(ahKindHelm)}, "facets": {"false"},
		"limit": {strconv.Itoa(limit)}, "offset": {strconv.Itoa(max(offset, 0))},
	}
	if q != "" {
		params.Set("ts_query_web", q)
	} else {
		params.Set("sort", "stars")
	}
	body, total, err := ahGet(ctx, "/api/v1/packages/search", params)
	if err != nil {
		return nil, err
	}
	var raw struct {
		Packages []ahPackageSummary `json:"packages"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("unexpected Artifact Hub search response: %w", err)
	}
	out := &AHSearch{Packages: []AHPackage{}, Total: total}
	for _, p := range raw.Packages {
		if p.Name == "" || p.Repository.Name == "" {
			continue
		}
		out.Packages = append(out.Packages, ahSummary(p))
	}
	if out.Total < len(out.Packages) {
		out.Total = len(out.Packages)
	}
	return out, nil
}

func ahSummary(p ahPackageSummary) AHPackage {
	r := p.Repository
	pub := r.OrganizationDisplayName
	if pub == "" {
		pub = r.OrganizationName
	}
	if pub == "" {
		pub = r.UserAlias
	}
	return AHPackage{
		PackageID: p.PackageID, Name: p.Name, Version: p.Version, AppVersion: p.AppVersion, Description: p.Description,
		Icon: ahLogo(p.LogoImageID), Stars: p.Stars, Deprecated: p.Deprecated, Repo: r.Name, RepoDisplay: r.DisplayName,
		RepoURL: r.URL, Publisher: pub, Official: r.Official || p.Official, Verified: r.VerifiedPublisher,
	}
}

var ahSegment = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]*$`)

// ArtifactHubPackage returns a Helm package's detail (version "" = latest).
func ArtifactHubPackage(ctx context.Context, repoName, name, version string) (*ChartDetail, error) {
	if !ahSegment.MatchString(repoName) || !ahSegment.MatchString(name) || (version != "" && !ahSegment.MatchString(version)) {
		return nil, invalid("invalid Artifact Hub repository, package or version")
	}
	path := "/api/v1/packages/helm/" + url.PathEscape(repoName) + "/" + url.PathEscape(name)
	if version != "" {
		path += "/" + url.PathEscape(version)
	}
	body, _, err := ahGet(ctx, path, nil)
	if err != nil {
		return nil, err
	}
	var p ahPackage
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, fmt.Errorf("unexpected Artifact Hub package response: %w", err)
	}
	s := ahSummary(p.ahPackageSummary)
	d := &ChartDetail{
		Source: "artifacthub", Repo: s.Repo, RepoDisplay: s.RepoDisplay, RepoURL: s.RepoURL, Name: p.Name,
		Version: p.Version, AppVersion: p.AppVersion, Description: p.Description, Icon: s.Icon, Home: p.HomeURL,
		Keywords: p.Keywords, Deprecated: p.Deprecated, KubeVersion: p.Data.KubeVersion, Type: p.Data.Type,
		License: p.License, PackageID: p.PackageID, Readme: p.Readme, Official: s.Official, Verified: s.Verified,
		Maintainers: []Maintainer{}, Links: []Link{}, Versions: []ChartVersion{},
	}
	for _, m := range p.Maintainers {
		if m.Name != "" {
			d.Maintainers = append(d.Maintainers, m)
		}
	}
	if p.HomeURL != "" {
		d.Links = append(d.Links, Link{Name: "Home", URL: p.HomeURL})
	}
	for _, l := range p.Links {
		if l.URL != "" {
			d.Links = append(d.Links, l)
		}
	}
	for _, v := range p.AvailableVersions {
		cv := ChartVersion{Version: v.Version, AppVersion: v.AppVersion, Prerelease: v.Prerelease || isPrerelease(v.Version)}
		if v.TS > 0 {
			cv.Created = time.Unix(v.TS, 0).UTC().Format(time.RFC3339)
		}
		d.Versions = append(d.Versions, cv)
	}
	sortChartVersions(d.Versions)
	return d, nil
}

// sortChartVersions orders semver versions newest first (others last).
func sortChartVersions(vs []ChartVersion) {
	parse := func(s string) *semver.Version {
		v, err := semver.NewVersion(s)
		if err != nil {
			return nil
		}
		return v
	}
	sort.SliceStable(vs, func(i, j int) bool {
		a, b := parse(vs[i].Version), parse(vs[j].Version)
		switch {
		case a == nil:
			return false
		case b == nil:
			return true
		}
		return a.GreaterThan(b)
	})
}

var ahPackageID = regexp.MustCompile(`^[0-9a-fA-F-]{8,64}$`)

// ArtifactHubValues returns a package version's default values.yaml.
func ArtifactHubValues(ctx context.Context, packageID, version string) (string, error) {
	if !ahPackageID.MatchString(packageID) || !ahSegment.MatchString(version) {
		return "", invalid("invalid package id or version")
	}
	body, _, err := ahGet(ctx, "/api/v1/packages/"+packageID+"/"+url.PathEscape(version)+"/values", nil)
	if err != nil {
		return "", err
	}
	return string(body), nil
}
