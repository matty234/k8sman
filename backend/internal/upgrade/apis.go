package upgrade

import (
	"strings"

	"github.com/matty234/k8sman/backend/internal/kapi"
)

// APIChange is one group/version/kind that Kubernetes deprecated and (when
// RemovedIn is set) stopped serving.
type APIChange struct {
	Group    string // "" for the core group
	Version  string
	Kind     string
	Resource string // plural, as served
	// DeprecatedIn is the release that deprecated it (zero when the guide
	// doesn't say); RemovedIn the first release that no longer serves it.
	DeprecatedIn Version
	RemovedIn    Version
	// Replacement is the apiVersion to move to ("" = none: the kind is gone).
	Replacement string
	// Note is what else changes with the move, from the guide (short).
	Note string
	// Ephemeral kinds are never stored (reviews) or are high-volume
	// (Events): live objects aren't scanned for them, manifests are.
	Ephemeral bool
}

// APIVersion is "group/version" ("version" for the core group).
func (a APIChange) APIVersion() string {
	if a.Group == "" {
		return a.Version
	}
	return a.Group + "/" + a.Version
}

// MigrationGuide is the page the table comes from.
const MigrationGuide = kapi.MigrationGuide

// APIChanges is the deprecated API table (kapi.Removed), one entry per
// kind. Edit the table in backend/internal/kapi.
var APIChanges = func() []APIChange {
	var out []APIChange
	for _, r := range kapi.Removed {
		group, version := splitAPIVersion(r.APIVersion)
		for _, kr := range r.Kinds {
			kind, res, _ := strings.Cut(kr, ":")
			c := APIChange{Group: group, Version: version, Kind: kind, Resource: res, RemovedIn: V(r.RemovedIn), Replacement: r.Replacement, Note: r.Note}
			if r.DeprecatedIn > 0 {
				c.DeprecatedIn = V(r.DeprecatedIn)
			}
			c.Ephemeral = strings.HasSuffix(kind, "Review") || kind == "Event"
			out = append(out, c)
		}
	}
	return out
}()

func splitAPIVersion(apiVersion string) (group, version string) {
	if g, v, ok := strings.Cut(apiVersion, "/"); ok {
		return g, v
	}
	return "", apiVersion
}

// apiChangeKey is "apiVersion|Kind".
func apiChangeKey(apiVersion, kind string) string { return apiVersion + "|" + kind }

var apiChangeIndex = func() map[string]APIChange {
	m := make(map[string]APIChange, len(APIChanges))
	for _, c := range APIChanges {
		m[apiChangeKey(c.APIVersion(), c.Kind)] = c
	}
	return m
}()

// LookupAPI returns the table's entry for apiVersion and kind.
func LookupAPI(apiVersion, kind string) (APIChange, bool) {
	c, ok := apiChangeIndex[apiChangeKey(apiVersion, kind)]
	return c, ok
}

// RemovalsBetween are the entries removed after from, up to and including
// to: what an upgrade from from to to stops serving.
func RemovalsBetween(from, to Version) []APIChange {
	var out []APIChange
	for _, c := range APIChanges {
		if from.Before(c.RemovedIn) && c.RemovedIn.AtMost(to) {
			out = append(out, c)
		}
	}
	return out
}
