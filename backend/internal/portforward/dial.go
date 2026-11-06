package portforward

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// In-process forwarding: for integrations that talk a non-HTTP/1 protocol
// (gRPC to Hubble Relay) to an in-cluster service. The API server's
// service proxy only carries HTTP/1, so they dial a pod port through the
// same port-forward subresource as the forwards above, but get a net.Conn
// back instead of a local listener: nothing is bound on the machine.

// ResolveService picks a ready pod behind service namespace/name and the
// container port its service port (a number or name) maps to, the way
// forwards to a service do.
func ResolveService(ctx context.Context, c *cluster.Clients, namespace, name, port string) (*corev1.Pod, int, error) {
	return resolve(ctx, c, Spec{Kind: "service", Namespace: namespace, Name: name, Port: port})
}

// podDialer upgrades to the pod's portforward subresource: websockets on
// newer API servers, SPDY otherwise (like kubectl).
func podDialer(c *cluster.Clients, namespace, pod string) (httpstream.Dialer, error) {
	req := c.Typed.CoreV1().RESTClient().Post().Resource("pods").Namespace(namespace).Name(pod).SubResource("portforward")
	transport, upgrader, err := spdy.RoundTripperFor(c.RESTConfig)
	if err != nil {
		return nil, err
	}
	var dialer httpstream.Dialer = spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, req.URL())
	if ws, err := portforward.NewSPDYOverWebsocketDialer(req.URL(), c.RESTConfig); err == nil {
		dialer = portforward.NewFallbackDialer(ws, dialer, func(err error) bool {
			return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err)
		})
	}
	return dialer, nil
}

var dialRequestID atomic.Int64

// DialPod opens one connection to port on the pod, tunnelled through the
// API server. Closing the conn closes the tunnel. The conn ignores
// deadlines: callers that need timeouts use contexts (gRPC does).
func DialPod(ctx context.Context, c *cluster.Clients, namespace, pod string, port int) (net.Conn, error) {
	dialer, err := podDialer(c, namespace, pod)
	if err != nil {
		return nil, err
	}
	type result struct {
		conn httpstream.Connection
		err  error
	}
	done := make(chan result, 1)
	go func() {
		conn, _, err := dialer.Dial(portforward.PortForwardProtocolV1Name)
		done <- result{conn, err}
	}()
	var conn httpstream.Connection
	select {
	case r := <-done:
		if r.err != nil {
			return nil, fmt.Errorf("port-forward to %s/%s: %w", namespace, pod, r.err)
		}
		conn = r.conn
	case <-ctx.Done():
		go func() { // don't leak the upgrade when it finishes late
			if r := <-done; r.conn != nil {
				_ = r.conn.Close()
			}
		}()
		return nil, ctx.Err()
	}

	// The same two streams kubectl's forwarder opens per connection.
	h := http.Header{}
	h.Set(corev1.StreamType, corev1.StreamTypeError)
	h.Set(corev1.PortHeader, strconv.Itoa(port))
	h.Set(corev1.PortForwardRequestIDHeader, strconv.FormatInt(dialRequestID.Add(1), 10))
	errStream, err := conn.CreateStream(h)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = errStream.Close() // nothing is written to it
	h.Set(corev1.StreamType, corev1.StreamTypeData)
	data, err := conn.CreateStream(h)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	pc := &podConn{conn: conn, data: data, addr: podAddr(fmt.Sprintf("%s/%s:%d", namespace, pod, port)), remoteErr: make(chan struct{})}
	go func() { // the pod side reports failures (nothing listening, …) here
		b, _ := io.ReadAll(errStream)
		if len(b) > 0 {
			pc.errMsg = string(b)
		}
		close(pc.remoteErr)
	}()
	return pc, nil
}

type podConn struct {
	conn      httpstream.Connection
	data      httpstream.Stream
	addr      podAddr
	once      sync.Once
	remoteErr chan struct{}
	errMsg    string // set before remoteErr closes
}

func (p *podConn) Read(b []byte) (int, error) {
	n, err := p.data.Read(b)
	if err == io.EOF {
		select { // prefer the pod side's reason over a bare EOF
		case <-p.remoteErr:
			if p.errMsg != "" {
				return n, errors.New(p.errMsg)
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	return n, err
}

func (p *podConn) Write(b []byte) (int, error) { return p.data.Write(b) }

func (p *podConn) Close() error {
	p.once.Do(func() {
		_ = p.data.Close()
		_ = p.conn.Close()
	})
	return nil
}

func (p *podConn) LocalAddr() net.Addr              { return p.addr }
func (p *podConn) RemoteAddr() net.Addr             { return p.addr }
func (p *podConn) SetDeadline(time.Time) error      { return nil }
func (p *podConn) SetReadDeadline(time.Time) error  { return nil }
func (p *podConn) SetWriteDeadline(time.Time) error { return nil }

type podAddr string

func (a podAddr) Network() string { return "portforward" }
func (a podAddr) String() string  { return string(a) }
