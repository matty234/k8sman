package icons

import (
	"net"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// reservedSuffixes never resolve to a public website (RFC 2606/6761 and
// common in-cluster names), so they are never fetched.
var reservedSuffixes = []string{
	"local", "localhost", "internal", "svc", "cluster.local", "lan", "home", "corp",
	"example", "test", "invalid", "example.com", "example.org", "example.net",
}

// CandidateDomains derives the websites to try for a CRD API group, most
// specific first: the group itself, then parents down to the registrable
// domain (eTLD+1). E.g. monitoring.coreos.com → [monitoring.coreos.com,
// coreos.com]. Hosts under a public suffix such as github.io stop at the
// owner's site (aquasecurity.github.io), never github.io itself. Returns nil
// for groups that aren't public DNS names.
func CandidateDomains(group string) []string {
	g := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(group)), ".")
	if g == "" || !strings.Contains(g, ".") || !validHost(g) || net.ParseIP(g) != nil {
		return nil
	}
	for _, s := range reservedSuffixes {
		if g == s || strings.HasSuffix(g, "."+s) {
			return nil
		}
	}
	// Only ICANN TLDs (or private suffixes under one, like github.io).
	if suffix, icann := publicsuffix.PublicSuffix(g); !icann && !strings.Contains(suffix, ".") {
		return nil
	}
	root, err := publicsuffix.EffectiveTLDPlusOne(g)
	if err != nil {
		return nil
	}
	var chain []string
	for d := g; ; {
		chain = append(chain, d)
		if d == root {
			break
		}
		i := strings.IndexByte(d, '.')
		if i < 0 {
			break
		}
		d = d[i+1:]
	}
	// Keep it short: the group, its parent, and the registrable domain.
	if len(chain) > 3 {
		chain = []string{chain[0], chain[1], chain[len(chain)-1]}
	}
	return chain
}

func validHost(h string) bool {
	if len(h) > 253 {
		return false
	}
	for _, label := range strings.Split(h, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return false
			}
		}
	}
	return true
}

// ValidGroup reports whether s looks like an API group name (used to reject
// junk in the URL path before doing any work).
func ValidGroup(s string) bool { return s != "" && validHost(s) }

// IsKubernetesGroup reports whether the group belongs to the Kubernetes
// project itself (gateway.networking.k8s.io, snapshot.storage.k8s.io,
// cluster.x-k8s.io, …). These get the Kubernetes icon and are never
// attributed to whichever Helm chart happened to ship their CRDs.
func IsKubernetesGroup(group string) bool {
	return group == "k8s.io" || group == "x-k8s.io" ||
		strings.HasSuffix(group, ".k8s.io") || strings.HasSuffix(group, ".x-k8s.io")
}

// IsLocalCluster guesses whether a context points at a throwaway local
// cluster (kind, k3d, minikube, Docker Desktop, …), where looking up
// favicons for its CRD groups leaks nothing interesting.
func IsLocalCluster(contextName, host string) bool {
	c := strings.ToLower(contextName)
	for _, p := range []string{"kind-", "k3d-", "minikube", "docker-desktop", "docker-for-desktop", "rancher-desktop", "orbstack", "colima", "microk8s", "k3s-default"} {
		if strings.HasPrefix(c, p) {
			return true
		}
	}
	h := strings.ToLower(host)
	h = strings.TrimPrefix(strings.TrimPrefix(h, "https://"), "http://")
	if i := strings.LastIndexByte(h, ':'); i >= 0 && !strings.HasSuffix(h, "]") {
		h = h[:i]
	}
	h = strings.Trim(h, "[]")
	if h == "localhost" || strings.HasSuffix(h, ".localhost") || h == "host.docker.internal" || h == "kubernetes.docker.internal" {
		return true
	}
	if ip := net.ParseIP(h); ip != nil && ip.IsLoopback() {
		return true
	}
	return false
}
