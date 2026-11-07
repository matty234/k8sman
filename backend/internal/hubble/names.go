package hubble

import (
	"context"
	"net"
	"net/netip"
	"strings"
	"sync"
	"time"
)

// Sources of a Name.
const (
	NameCluster = "cluster"
	NameRDNS    = "rdns"
)

// Name labels a world address on the traffic map.
type Name struct {
	Name   string `json:"name"`
	Source string `json:"source"`
}

const (
	nameHitTTL   = time.Hour
	nameMissTTL  = 10 * time.Minute
	nameMaxItems = 2048
	nameWorkers  = 4
	nameTimeout  = 2 * time.Second
	nameQueue    = 256
)

// Namer resolves addresses to names by reverse DNS, in the background:
// Name never waits for a lookup. It is safe for concurrent use.
type Namer struct {
	// lookup is net.Resolver.LookupAddr unless a test replaces it.
	lookup func(ctx context.Context, ip string) ([]string, error)
	now    func() time.Time

	mu      sync.Mutex
	cache   map[string]nameEntry
	pending map[string]bool
	running int
	queue   []string
}

type nameEntry struct {
	name    string
	expires time.Time
}

// NewNamer returns a Namer using the system resolver.
func NewNamer() *Namer {
	return &Namer{
		lookup:  net.DefaultResolver.LookupAddr,
		now:     time.Now,
		cache:   map[string]nameEntry{},
		pending: map[string]bool{},
	}
}

// Name returns the cached PTR name of ip ("" when unknown, not yet
// looked up, or ip isn't a public address) and queues a lookup when
// nothing is cached.
func (n *Namer) Name(ip string) string {
	a, err := netip.ParseAddr(ip)
	if err != nil || !publicAddr(a) {
		return ""
	}
	ip = a.Unmap().String()
	n.mu.Lock()
	defer n.mu.Unlock()
	if e, ok := n.cache[ip]; ok && n.now().Before(e.expires) {
		return e.name
	}
	if !n.pending[ip] && len(n.queue) < nameQueue {
		n.pending[ip] = true
		n.queue = append(n.queue, ip)
		if n.running < nameWorkers {
			n.running++
			go n.work()
		}
	}
	return ""
}

func (n *Namer) work() {
	for {
		n.mu.Lock()
		if len(n.queue) == 0 {
			n.running--
			n.mu.Unlock()
			return
		}
		ip := n.queue[0]
		n.queue = n.queue[1:]
		n.mu.Unlock()

		ctx, cancel := context.WithTimeout(context.Background(), nameTimeout)
		names, err := n.lookup(ctx, ip)
		cancel()
		name, ttl := "", nameMissTTL
		if err == nil && len(names) > 0 {
			name, ttl = strings.TrimSuffix(names[0], "."), nameHitTTL
		}
		n.mu.Lock()
		delete(n.pending, ip)
		n.store(ip, nameEntry{name, n.now().Add(ttl)})
		n.mu.Unlock()
	}
}

// store adds e, first dropping expired entries and then the one that
// expires soonest while the cache is full. n.mu is held.
func (n *Namer) store(ip string, e nameEntry) {
	if _, ok := n.cache[ip]; !ok && len(n.cache) >= nameMaxItems {
		now := n.now()
		var oldest string
		for k, v := range n.cache {
			if !now.Before(v.expires) {
				delete(n.cache, k)
			} else if oldest == "" || v.expires.Before(n.cache[oldest].expires) {
				oldest = k
			}
		}
		if len(n.cache) >= nameMaxItems {
			delete(n.cache, oldest)
		}
	}
	n.cache[ip] = e
}

var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// publicAddr is false for addresses a PTR lookup would only leak or not
// answer: private, loopback, link-local, CGNAT (100.64.0.0/10), and so on.
func publicAddr(a netip.Addr) bool {
	a = a.Unmap()
	if !a.IsValid() || !a.IsGlobalUnicast() || a.IsPrivate() || a.IsLoopback() ||
		a.IsLinkLocalUnicast() || a.IsMulticast() || a.IsUnspecified() {
		return false
	}
	return !cgnat.Contains(a)
}

// ResolveNames labels the IP peers in peers (as in TrafficEdge.Peers;
// DNS names are skipped). A cluster object owning the address (cluster:
// IP to label) wins over reverse DNS; n may be nil, or rdns false, to skip
// PTR lookups. Returns nil when nothing is known.
func ResolveNames(peers []string, cluster map[string]string, n *Namer, rdns bool) map[string]Name {
	var out map[string]Name
	for _, p := range peers {
		a, err := netip.ParseAddr(p)
		if err != nil {
			continue
		}
		var nm Name
		if c := cluster[a.Unmap().String()]; c != "" {
			nm = Name{c, NameCluster}
		} else if r := lookupName(n, rdns, p); r != "" {
			nm = Name{r, NameRDNS}
		} else {
			continue
		}
		if out == nil {
			out = map[string]Name{}
		}
		out[p] = nm
	}
	return out
}

func lookupName(n *Namer, rdns bool, ip string) string {
	if n == nil || !rdns {
		return ""
	}
	return n.Name(ip)
}
