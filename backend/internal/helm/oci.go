package helm

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Masterminds/semver/v3"
	"helm.sh/helm/v3/pkg/registry"
	"oras.land/oras-go/v2/registry/remote/errcode"
)

// OCIVersions is the result of listing a chart's registry tags.
type OCIVersions struct {
	// Versions is every tag, semver newest first, non-semver tags last.
	Versions []string `json:"versions"`
	// Latest is the newest stable version (or the newest of all when only
	// pre-releases exist); empty when there are no versions.
	Latest string `json:"latest"`
}

const (
	ociTimeout  = 10 * time.Second
	ociCacheTTL = 5 * time.Minute
)

var ociCache = struct {
	sync.Mutex
	m map[string]ociEntry
}{m: map[string]ociEntry{}}

type ociEntry struct {
	at  time.Time
	res OCIVersions
}

// ListOCIVersions lists the tags of an oci:// chart reference with the
// user's registry credentials (helm registry login / docker credential
// helpers). Results are cached per reference for a few minutes.
func ListOCIVersions(ref string) (*OCIVersions, error) {
	ref = strings.TrimSuffix(strings.TrimSpace(ref), "/")
	if !registry.IsOCI(ref) {
		return nil, invalid("ref must be an oci:// chart reference")
	}
	ociCache.Lock()
	e, ok := ociCache.m[ref]
	ociCache.Unlock()
	if ok && time.Since(e.at) < ociCacheTTL {
		return &e.res, nil
	}
	rc, err := newRegistryClient(envSettings())
	if err != nil {
		return nil, err
	}
	res, err := listOCIVersions(rc, ref)
	if err != nil {
		return nil, err
	}
	ociCache.Lock()
	ociCache.m[ref] = ociEntry{time.Now(), *res}
	ociCache.Unlock()
	return res, nil
}

func listOCIVersions(rc *registry.Client, ref string) (*OCIVersions, error) {
	type result struct {
		tags []string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		tags, err := rc.Tags(strings.TrimPrefix(ref, registry.OCIScheme+"://"))
		ch <- result{tags, err}
	}()
	select {
	case r := <-ch:
		if r.err != nil {
			return nil, ociError(ref, r.err)
		}
		return sortOCIVersions(r.tags), nil
	case <-time.After(ociTimeout):
		return nil, fmt.Errorf("timed out after %s listing versions of %s", ociTimeout, ref)
	}
}

// sortOCIVersions orders semver tags newest first; other tags go last.
func sortOCIVersions(tags []string) *OCIVersions {
	type sv struct {
		s string
		v *semver.Version
	}
	var good []sv
	var bad []string
	for _, t := range tags {
		if v, err := semver.NewVersion(strings.ReplaceAll(t, "_", "+")); err == nil {
			good = append(good, sv{t, v})
		} else {
			bad = append(bad, t)
		}
	}
	for i := 1; i < len(good); i++ { // insertion sort, descending
		for j := i; j > 0 && good[j].v.GreaterThan(good[j-1].v); j-- {
			good[j], good[j-1] = good[j-1], good[j]
		}
	}
	out := &OCIVersions{Versions: []string{}}
	for _, g := range good {
		out.Versions = append(out.Versions, g.s)
		if out.Latest == "" && g.v.Prerelease() == "" {
			out.Latest = g.s
		}
	}
	out.Versions = append(out.Versions, bad...)
	if out.Latest == "" && len(out.Versions) > 0 {
		out.Latest = out.Versions[0]
	}
	return out
}

// ociError turns registry failures into messages a user can act on.
func ociError(ref string, err error) error {
	host := strings.SplitN(strings.TrimPrefix(ref, registry.OCIScheme+"://"), "/", 2)[0]
	var er *errcode.ErrorResponse
	status := 0
	if errors.As(err, &er) {
		status = er.StatusCode
	}
	msg := err.Error()
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden ||
		strings.Contains(msg, "401") || strings.Contains(msg, "403") || strings.Contains(msg, "UNAUTHORIZED") || strings.Contains(msg, "DENIED"):
		return fmt.Errorf("not logged in to %s (or no access to %s): run helm registry login %s", host, ref, host)
	case status == http.StatusNotFound || strings.Contains(msg, "404") || strings.Contains(msg, "NAME_UNKNOWN"):
		return fmt.Errorf("%w: %s was not found in the registry", ErrNotFound, ref)
	}
	var ne net.Error
	if errors.As(err, &ne) || strings.Contains(msg, "no such host") || strings.Contains(msg, "connection refused") {
		return fmt.Errorf("cannot reach registry %s: %v", host, err)
	}
	return fmt.Errorf("list versions of %s: %w", ref, err)
}
