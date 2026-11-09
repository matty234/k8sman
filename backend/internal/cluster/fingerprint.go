package cluster

import (
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/url"
	"strings"
)

// NormalizeServer rewrites an API server URL so that spellings of the same
// address compare equal across machines: scheme and host lowercased, the
// scheme's default port dropped (443 for https, 80 for http), trailing
// slashes dropped. The path is kept as written, because some proxies
// (Rancher, Teleport) name the cluster in it. Userinfo, query and fragment
// are dropped. A URL without a scheme is taken as https, as client-go does.
// "" when there is no host.
func NormalizeServer(server string) string {
	s := strings.TrimSpace(server)
	if s == "" {
		return ""
	}
	if !strings.Contains(s, "://") {
		s = "https://" + s
	}
	u, err := url.Parse(s)
	if err != nil || u.Host == "" {
		return ""
	}
	scheme := strings.ToLower(u.Scheme)
	host, port := strings.ToLower(u.Hostname()), u.Port()
	if (scheme == "https" && port == "443") || (scheme == "http" && port == "80") {
		port = ""
	}
	hostport := host
	if port != "" {
		hostport = net.JoinHostPort(host, port)
	} else if strings.Contains(host, ":") {
		hostport = "[" + host + "]" // IPv6 literal
	}
	return scheme + "://" + hostport + strings.TrimRight(u.EscapedPath(), "/")
}

// Fingerprint identifies a cluster by its API server, privately enough for
// shareable links: the first 12 hex characters of SHA-256 over
// NormalizeServer(server). Not secret: anyone who can guess a server
// address can check it. "" when the server has no host.
func Fingerprint(server string) string {
	n := NormalizeServer(server)
	if n == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(n))
	return hex.EncodeToString(sum[:])[:12]
}
