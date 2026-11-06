package hubble

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/matty234/k8sman/backend/internal/cluster"
	observerpb "github.com/matty234/k8sman/backend/internal/hubble/pb/observer"
	"github.com/matty234/k8sman/backend/internal/portforward"
)

// States of Status.State.
const (
	StateNotInstalled = "notInstalled" // no Cilium, or Hubble turned off
	StateNoRelay      = "noRelay"      // Hubble on, but no relay Service
	StateConnected    = "connected"
	StateUnreachable  = "unreachable" // relay found, but no answer
)

// Status is the GET /api/hubble/status payload.
type Status struct {
	State   string `json:"state"`
	Message string `json:"message,omitempty"`
	Discovery
	Server    *ServerInfo `json:"server,omitempty"`
	CheckedAt time.Time   `json:"checkedAt"`
}

// ServerInfo is the relay's ServerStatus.
type ServerInfo struct {
	Version          string   `json:"version,omitempty"`
	NumFlows         uint64   `json:"numFlows"`
	MaxFlows         uint64   `json:"maxFlows"`
	SeenFlows        uint64   `json:"seenFlows"`
	FlowsRate        float64  `json:"flowsRate"`
	UptimeSeconds    float64  `json:"uptimeSeconds"`
	ConnectedNodes   *uint32  `json:"connectedNodes,omitempty"`
	UnavailableNodes []string `json:"unavailableNodes,omitempty"`
}

const (
	statusTTL       = 30 * time.Second
	failedStatusTTL = 10 * time.Second
	// DefaultServerName is covered by the certificates Cilium issues to
	// the relay (*.hubble-relay.cilium.io).
	DefaultServerName = "ui.hubble-relay.cilium.io"
)

// Hub holds the gRPC connection to the current context's relay and caches
// its status. One per backend.
type Hub struct {
	mu     sync.Mutex
	conn   *grpc.ClientConn
	key    string // what conn was made for
	status map[string]*statusEntry
}

type statusEntry struct {
	at   time.Time
	s    *Status
	wait chan struct{}
}

func NewHub() *Hub { return &Hub{status: map[string]*statusEntry{}} }

// Observer returns a client for the relay of c, connecting when the relay
// (or the context) changed since the last call.
func (h *Hub) Observer(ctx context.Context, c *cluster.Clients, s Settings) (observerpb.ObserverClient, *Relay, error) {
	st := h.Status(ctx, c, s, false)
	if st.Relay == nil {
		return nil, nil, errors.New(st.Message)
	}
	cc, err := h.connFor(ctx, c, st.Relay, s)
	if err != nil {
		return nil, st.Relay, err
	}
	return observerpb.NewObserverClient(cc), st.Relay, nil
}

// idleTimeout is how long the relay connection stays open with no calls.
var idleTimeout = time.Minute

func (h *Hub) connFor(ctx context.Context, c *cluster.Clients, r *Relay, s Settings) (*grpc.ClientConn, error) {
	key := fmt.Sprintf("%p|%s/%s:%s|%v|%s", c, r.Namespace, r.Service, r.Port, r.TLS, s.ServerName)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conn != nil && h.key == key {
		return h.conn, nil
	}
	if h.conn != nil {
		_ = h.conn.Close()
		h.conn = nil
	}
	creds := insecure.NewCredentials()
	if r.TLS {
		cfg, err := tlsConfig(ctx, c, r, s)
		if err != nil {
			return nil, err
		}
		creds = credentials.NewTLS(cfg)
	}
	ns, svc, port := r.Namespace, r.Service, r.Port
	// Every (re)connect resolves the Service to a ready pod again, so a
	// restarted relay is picked up.
	dial := func(ctx context.Context, _ string) (net.Conn, error) {
		pod, target, err := portforward.ResolveService(ctx, c, ns, svc, port)
		if err != nil {
			return nil, err
		}
		return portforward.DialPod(ctx, c, ns, pod.Name, target)
	}
	cc, err := grpc.NewClient("passthrough:///hubble-relay",
		grpc.WithContextDialer(dial),
		grpc.WithTransportCredentials(creds),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20)),
		// Close the tunnel to the relay soon after the last stream or query
		// ends (gRPC's default keeps it for 30 minutes); the next call
		// reconnects.
		grpc.WithIdleTimeout(idleTimeout),
	)
	if err != nil {
		return nil, err
	}
	h.conn, h.key = cc, key
	return cc, nil
}

// tlsConfig trusts the relay's CA and presents a client certificate when
// the cluster has one for Hubble's clients (mTLS). Secrets are read into
// memory only.
func tlsConfig(ctx context.Context, c *cluster.Clients, r *Relay, s Settings) (*tls.Config, error) {
	secrets := c.Typed.CoreV1().Secrets(r.Namespace)
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: s.ServerName}
	if cfg.ServerName == "" {
		cfg.ServerName = DefaultServerName
	}
	ca, err := secrets.Get(ctx, "hubble-relay-server-certs", metav1.GetOptions{})
	if err != nil {
		return nil, fmt.Errorf("relay uses TLS; reading its CA (secret %s/hubble-relay-server-certs): %w", r.Namespace, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca.Data["ca.crt"]) {
		return nil, fmt.Errorf("secret %s/hubble-relay-server-certs has no ca.crt", r.Namespace)
	}
	cfg.RootCAs = pool
	for _, name := range []string{"hubble-ui-client-certs", "hubble-relay-client-certs"} {
		sec, err := secrets.Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			continue
		}
		if cert, err := tls.X509KeyPair(sec.Data["tls.crt"], sec.Data["tls.key"]); err == nil {
			cfg.Certificates = []tls.Certificate{cert}
			break
		}
	}
	return cfg, nil
}

// Status discovers the relay and asks it for its ServerStatus, cached per
// context (30s; 10s after a failure). Concurrent callers share one check.
func (h *Hub) Status(ctx context.Context, c *cluster.Clients, s Settings, refresh bool) *Status {
	key := fmt.Sprintf("%p|%+v", c, s)
	h.mu.Lock()
	e := h.status[key]
	if e != nil && e.wait != nil {
		w := e.wait
		h.mu.Unlock()
		select {
		case <-w:
		case <-ctx.Done():
			return &Status{State: StateUnreachable, Message: ctx.Err().Error(), CheckedAt: time.Now()}
		}
		h.mu.Lock()
		e = h.status[key]
	}
	if e != nil && e.s != nil && !refresh {
		ttl := statusTTL
		if e.s.State != StateConnected {
			ttl = failedStatusTTL
		}
		if time.Since(e.at) < ttl {
			h.mu.Unlock()
			return e.s
		}
	}
	wait := make(chan struct{})
	h.status[key] = &statusEntry{wait: wait}
	h.mu.Unlock()

	// Detached so a cancelled caller doesn't poison the cache.
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	st := h.check(cctx, c, s)
	cancel()

	h.mu.Lock()
	h.status[key] = &statusEntry{at: time.Now(), s: st}
	close(wait)
	h.mu.Unlock()
	return st
}

// Peek returns the last status checked for the context (nil when none
// yet) without waiting, and starts a check in the background when it is
// stale. For the overview, which must not wait on the relay.
func (h *Hub) Peek(c *cluster.Clients, s Settings) *Status {
	key := fmt.Sprintf("%p|%+v", c, s)
	h.mu.Lock()
	e := h.status[key]
	h.mu.Unlock()
	if e != nil && e.wait != nil {
		return nil // a check is running
	}
	if e == nil || time.Since(e.at) >= statusTTL {
		go h.Status(context.Background(), c, s, false)
	}
	if e == nil {
		return nil
	}
	return e.s
}

func (h *Hub) check(ctx context.Context, c *cluster.Clients, s Settings) *Status {
	st := &Status{Discovery: Discover(ctx, c.Typed, s), CheckedAt: time.Now()}
	switch {
	case st.Relay == nil && (!st.Cilium || (st.HubbleEnabled != nil && !*st.HubbleEnabled)) && st.Errors == nil:
		st.State = StateNotInstalled
		st.Message = "Cilium with Hubble isn't installed on this cluster"
		if st.Cilium {
			st.Message = "Hubble is turned off in Cilium's config (enable-hubble)"
		}
		return st
	case st.Relay == nil:
		st.State = StateNoRelay
		st.Message = "no Hubble Relay Service found"
		if e := st.Errors["services"] + st.Errors["relay"]; e != "" {
			st.Message += ": " + e
		}
		return st
	}
	cc, err := h.connFor(ctx, c, st.Relay, s)
	if err == nil {
		var res *observerpb.ServerStatusResponse
		res, err = observerpb.NewObserverClient(cc).ServerStatus(ctx, &observerpb.ServerStatusRequest{})
		if err == nil {
			st.State = StateConnected
			st.Server = &ServerInfo{
				Version: res.GetVersion(), NumFlows: res.GetNumFlows(), MaxFlows: res.GetMaxFlows(),
				SeenFlows: res.GetSeenFlows(), FlowsRate: res.GetFlowsRate(),
				UptimeSeconds: float64(res.GetUptimeNs()) / 1e9, UnavailableNodes: res.GetUnavailableNodes(),
			}
			if n := res.GetNumConnectedNodes(); n != nil {
				v := n.GetValue()
				st.Server.ConnectedNodes = &v
			}
			return st
		}
	}
	st.State = StateUnreachable
	st.Message = ErrorMessage(err)
	return st
}

// ErrorMessage is err without gRPC's "rpc error: code = …" wrapping.
func ErrorMessage(err error) string {
	if s, ok := status.FromError(err); ok {
		return s.Message()
	}
	return err.Error()
}

// Close drops the connection (on shutdown).
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conn != nil {
		_ = h.conn.Close()
		h.conn = nil
	}
}
