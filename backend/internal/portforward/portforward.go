// Package portforward manages persistent, self-healing port-forwards.
//
// A forward targets a pod, service or workload. The supervisor resolves it to
// a concrete ready pod, forwards, watches that pod, and re-resolves and
// reconnects (with backoff) when the pod goes away or the stream drops —
// unlike `kubectl port-forward`, which just dies. Specs are persisted so
// forwards survive backend restarts; AutoStart ones start on launch.
package portforward

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// Spec is the persisted definition of a forward.
type Spec struct {
	ID      string `json:"id"`
	Context string `json:"context"`
	// Kubeconfig is the kubeconfig file the context comes from, so forwards
	// keep working after the UI switches kubeconfig. "" = default loading
	// rules ($KUBECONFIG or ~/.kube/config).
	Kubeconfig string `json:"kubeconfig,omitempty"`
	Namespace  string `json:"namespace"`
	// Kind: pod | service | deployment | statefulset | daemonset | replicaset
	Kind string `json:"kind"`
	Name string `json:"name"`
	// Port on the target: a number or a name. For services this is the
	// *service* port (mapped through targetPort like kubectl does).
	Port      string `json:"port"`
	LocalPort int    `json:"localPort"`
	Address   string `json:"address"`
	AutoStart bool   `json:"autoStart"`
	Label     string `json:"label,omitempty"`
}

// State values.
const (
	Stopped      = "stopped"
	Starting     = "starting"
	Active       = "active"
	Reconnecting = "reconnecting"
	Failed       = "error"
)

// Status is a Spec plus live state.
type Status struct {
	Spec
	State       string    `json:"state"`
	Pod         string    `json:"pod,omitempty"`
	RemotePort  int       `json:"remotePort,omitempty"`
	Error       string    `json:"error,omitempty"`
	Since       time.Time `json:"since,omitempty"`
	Reconnects  int       `json:"reconnects"`
	Connections int64     `json:"connections"`
	URL         string    `json:"url,omitempty"`
}

type forward struct {
	mu     sync.Mutex
	status Status
	cancel context.CancelFunc
	done   chan struct{}
}

// Manager owns all forwards.
type Manager struct {
	clusters *cluster.Manager
	path     string

	mu       sync.Mutex
	forwards map[string]*forward
}

// DefaultPath is ~/.config/k8sman/portforwards.json.
func DefaultPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "k8sman", "portforwards.json")
}

// NewManager loads persisted specs and starts AutoStart ones.
func NewManager(clusters *cluster.Manager, path string) (*Manager, error) {
	m := &Manager{clusters: clusters, path: path, forwards: map[string]*forward{}}
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	var specs []Spec
	if len(b) > 0 {
		if err := json.Unmarshal(b, &specs); err != nil {
			return nil, fmt.Errorf("parse %s: %w", path, err)
		}
	}
	for _, s := range specs {
		if s.Kubeconfig == "" {
			// Saved before forwards remembered their kubeconfig: they were
			// created against whatever this backend was started with.
			s.Kubeconfig = clusters.Kubeconfig()
		}
		f := &forward{status: Status{Spec: s, State: Stopped}}
		m.forwards[s.ID] = f
		if s.AutoStart {
			m.start(f)
		}
	}
	return m, nil
}

// List returns all forwards, sorted for stable display.
func (m *Manager) List() []Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Status, 0, len(m.forwards))
	for _, f := range m.forwards {
		f.mu.Lock()
		out = append(out, f.status)
		f.mu.Unlock()
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Context != out[j].Context {
			return out[i].Context < out[j].Context
		}
		if out[i].Namespace != out[j].Namespace {
			return out[i].Namespace < out[j].Namespace
		}
		return out[i].Name+out[i].Port < out[j].Name+out[j].Port
	})
	return out
}

// Get returns one forward's status.
func (m *Manager) Get(id string) (Status, bool) {
	m.mu.Lock()
	f := m.forwards[id]
	m.mu.Unlock()
	if f == nil {
		return Status{}, false
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.status, true
}

var validKinds = map[string]bool{"pod": true, "service": true, "deployment": true, "statefulset": true, "daemonset": true, "replicaset": true}

// Create validates, persists and starts a new forward. LocalPort 0 picks a
// free port (and keeps it stable across reconnects/restarts).
func (m *Manager) Create(s Spec) (Status, error) {
	s.Kind = strings.ToLower(s.Kind)
	if !validKinds[s.Kind] {
		return Status{}, fmt.Errorf("unsupported kind %q", s.Kind)
	}
	if s.Namespace == "" || s.Name == "" || s.Port == "" {
		return Status{}, errors.New("namespace, name and port are required")
	}
	if s.Context == "" {
		c := m.clusters.Clients()
		if c == nil {
			return Status{}, fmt.Errorf("no cluster connection: %v", m.clusters.Err())
		}
		s.Context = c.Context
	}
	if s.Kubeconfig == "" {
		s.Kubeconfig = m.clusters.Kubeconfig()
	}
	if s.Address == "" {
		s.Address = "127.0.0.1"
	}
	if s.LocalPort == 0 {
		// Prefer the same port number locally when it's free (nicer URLs).
		if n, err := strconv.Atoi(s.Port); err == nil && n >= 1024 && portFree(s.Address, n) {
			s.LocalPort = n
		} else {
			p, err := freePort(s.Address)
			if err != nil {
				return Status{}, err
			}
			s.LocalPort = p
		}
	}
	m.mu.Lock()
	for _, f := range m.forwards {
		f.mu.Lock()
		clash := f.status.LocalPort == s.LocalPort && f.status.Address == s.Address && f.status.State != Stopped
		f.mu.Unlock()
		if clash {
			m.mu.Unlock()
			return Status{}, fmt.Errorf("local port %d is already used by another forward", s.LocalPort)
		}
	}
	s.ID = newID()
	f := &forward{status: Status{Spec: s, State: Stopped}}
	m.forwards[s.ID] = f
	m.mu.Unlock()
	if err := m.save(); err != nil {
		return Status{}, err
	}
	m.start(f)
	st, _ := m.Get(s.ID)
	return st, nil
}

// Update changes mutable settings (autoStart, label, localPort). Changing the
// local port restarts a running forward.
func (m *Manager) Update(id string, autoStart *bool, label *string, localPort *int) (Status, error) {
	m.mu.Lock()
	f := m.forwards[id]
	m.mu.Unlock()
	if f == nil {
		return Status{}, errNotFound
	}
	restart := false
	f.mu.Lock()
	if autoStart != nil {
		f.status.AutoStart = *autoStart
	}
	if label != nil {
		f.status.Label = *label
	}
	if localPort != nil && *localPort != f.status.LocalPort && *localPort > 0 {
		f.status.LocalPort = *localPort
		restart = f.status.State != Stopped
	}
	f.mu.Unlock()
	if err := m.save(); err != nil {
		return Status{}, err
	}
	if restart {
		m.stop(f)
		m.start(f)
	}
	st, _ := m.Get(id)
	return st, nil
}

var errNotFound = errors.New("port-forward not found")

// IsNotFound reports whether err means the id doesn't exist.
func IsNotFound(err error) bool { return errors.Is(err, errNotFound) }

// Start (re)starts a stopped forward.
func (m *Manager) Start(id string) error {
	m.mu.Lock()
	f := m.forwards[id]
	m.mu.Unlock()
	if f == nil {
		return errNotFound
	}
	m.stop(f)
	m.start(f)
	return nil
}

// Stop stops a forward but keeps it saved.
func (m *Manager) Stop(id string) error {
	m.mu.Lock()
	f := m.forwards[id]
	m.mu.Unlock()
	if f == nil {
		return errNotFound
	}
	m.stop(f)
	return nil
}

// Delete stops and forgets a forward.
func (m *Manager) Delete(id string) error {
	m.mu.Lock()
	f := m.forwards[id]
	delete(m.forwards, id)
	m.mu.Unlock()
	if f == nil {
		return errNotFound
	}
	m.stop(f)
	return m.save()
}

// StopAll is called on shutdown.
func (m *Manager) StopAll() {
	m.mu.Lock()
	fs := make([]*forward, 0, len(m.forwards))
	for _, f := range m.forwards {
		fs = append(fs, f)
	}
	m.mu.Unlock()
	for _, f := range fs {
		m.stop(f)
	}
}

func (m *Manager) save() error {
	m.mu.Lock()
	specs := make([]Spec, 0, len(m.forwards))
	for _, f := range m.forwards {
		f.mu.Lock()
		specs = append(specs, f.status.Spec)
		f.mu.Unlock()
	}
	m.mu.Unlock()
	sort.Slice(specs, func(i, j int) bool { return specs[i].ID < specs[j].ID })
	if err := os.MkdirAll(filepath.Dir(m.path), 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(specs, "", "  ")
	tmp := m.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, m.path)
}

func (m *Manager) stop(f *forward) {
	f.mu.Lock()
	cancel, done := f.cancel, f.done
	f.cancel, f.done = nil, nil
	f.mu.Unlock()
	if cancel != nil {
		cancel()
		<-done
	}
	f.set(func(s *Status) {
		s.State, s.Pod, s.Error, s.RemotePort = Stopped, "", "", 0
	})
}

func (m *Manager) start(f *forward) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	f.mu.Lock()
	f.cancel, f.done = cancel, done
	f.status.State, f.status.Error, f.status.Reconnects = Starting, "", 0
	f.status.URL = fmt.Sprintf("http://%s:%d", hostFor(f.status.Address), f.status.LocalPort)
	f.mu.Unlock()
	go func() {
		defer close(done)
		m.supervise(ctx, f)
	}()
}

func (f *forward) set(mut func(*Status)) {
	f.mu.Lock()
	mut(&f.status)
	f.mu.Unlock()
}

// supervise keeps the forward alive until ctx is cancelled.
func (m *Manager) supervise(ctx context.Context, f *forward) {
	backoff := time.Second
	for ctx.Err() == nil {
		f.mu.Lock()
		spec := f.status.Spec
		f.mu.Unlock()

		started := time.Now()
		err := m.runOnce(ctx, f, spec)
		if ctx.Err() != nil {
			return
		}
		msg := "connection closed"
		if err != nil {
			msg = err.Error()
		}
		log.Printf("port-forward %s/%s:%s → %d: %s (retrying in %s)", spec.Kind, spec.Name, spec.Port, spec.LocalPort, msg, backoff)
		f.set(func(s *Status) {
			s.State, s.Error, s.Pod = Reconnecting, msg, ""
			s.Reconnects++
		})
		// A forward that stayed up a while resets the backoff.
		if time.Since(started) > 30*time.Second {
			backoff = time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}

// runOnce resolves the target, forwards, and blocks until the forward breaks
// or the bound pod stops being usable.
func (m *Manager) runOnce(ctx context.Context, f *forward, spec Spec) error {
	c, err := m.clusters.ClientsIn(spec.Kubeconfig, spec.Context)
	if err != nil {
		return err
	}
	pod, remotePort, err := resolve(ctx, c, spec)
	if err != nil {
		return err
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Watch the chosen pod; if it's deleted or stops running, tear down so
	// we re-resolve to a healthy one.
	go func() {
		w, err := c.Typed.CoreV1().Pods(spec.Namespace).Watch(runCtx, metav1.ListOptions{
			FieldSelector:   "metadata.name=" + pod.Name,
			ResourceVersion: pod.ResourceVersion,
		})
		if err != nil {
			return
		}
		defer w.Stop()
		for ev := range w.ResultChan() {
			p, ok := ev.Object.(*corev1.Pod)
			if ev.Type == watch.Deleted || (ok && (p.DeletionTimestamp != nil || p.Status.Phase != corev1.PodRunning)) {
				cancel()
				return
			}
		}
	}()

	req := c.Typed.CoreV1().RESTClient().Post().Resource("pods").Namespace(spec.Namespace).Name(pod.Name).SubResource("portforward")
	transport, upgrader, err := spdy.RoundTripperFor(c.RESTConfig)
	if err != nil {
		return err
	}
	spdyDialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, req.URL())
	// Prefer websockets (newer API servers), fall back to SPDY like kubectl.
	dialer := spdyDialer
	if ws, err := portforward.NewSPDYOverWebsocketDialer(req.URL(), c.RESTConfig); err == nil {
		dialer = portforward.NewFallbackDialer(ws, spdyDialer, func(err error) bool {
			return httpstream.IsUpgradeFailure(err) || httpstream.IsHTTPSProxyError(err)
		})
	}

	stop := make(chan struct{})
	ready := make(chan struct{})
	counter := &connCounter{f: f}
	pf, err := portforward.NewOnAddresses(dialer, []string{spec.Address},
		[]string{fmt.Sprintf("%d:%d", spec.LocalPort, remotePort)}, stop, ready, counter, counter)
	if err != nil {
		return err
	}
	errc := make(chan error, 1)
	go func() { errc <- pf.ForwardPorts() }()

	select {
	case <-ready:
		f.set(func(s *Status) {
			s.State, s.Pod, s.RemotePort, s.Error, s.Since = Active, pod.Name, remotePort, "", time.Now()
		})
	case err := <-errc:
		if err == nil {
			err = errors.New("forward exited before becoming ready")
		}
		return err
	case <-runCtx.Done():
		close(stop)
		<-errc
		return fmt.Errorf("pod %s went away", pod.Name)
	}

	select {
	case err := <-errc:
		if err == nil {
			return errors.New("forward stopped")
		}
		return err
	case <-runCtx.Done():
		close(stop)
		<-errc
		if ctx.Err() != nil {
			return nil
		}
		return fmt.Errorf("pod %s went away", pod.Name)
	}
}

// connCounter receives the forwarder's out/err text: counts connections and
// surfaces per-connection errors (e.g. nothing listening on the remote port).
type connCounter struct{ f *forward }

func (c *connCounter) Write(p []byte) (int, error) {
	line := strings.TrimSpace(string(p))
	switch {
	case strings.HasPrefix(line, "Handling connection"):
		c.f.set(func(s *Status) { s.Connections++ })
	case strings.Contains(strings.ToLower(line), "error"):
		c.f.set(func(s *Status) { s.Error = line })
	}
	return len(p), nil
}

var _ io.Writer = (*connCounter)(nil)

var workloadGVR = map[string]schema.GroupVersionResource{
	"deployment":  {Group: "apps", Version: "v1", Resource: "deployments"},
	"statefulset": {Group: "apps", Version: "v1", Resource: "statefulsets"},
	"daemonset":   {Group: "apps", Version: "v1", Resource: "daemonsets"},
	"replicaset":  {Group: "apps", Version: "v1", Resource: "replicasets"},
}

// resolve picks a ready pod and the numeric container port, mirroring
// kubectl's behaviour for services and workloads.
func resolve(ctx context.Context, c *cluster.Clients, spec Spec) (*corev1.Pod, int, error) {
	pods := c.Typed.CoreV1().Pods(spec.Namespace)
	switch spec.Kind {
	case "pod":
		p, err := pods.Get(ctx, spec.Name, metav1.GetOptions{})
		if err != nil {
			return nil, 0, err
		}
		if p.Status.Phase != corev1.PodRunning {
			return nil, 0, fmt.Errorf("pod %s is %s, not Running", p.Name, p.Status.Phase)
		}
		port, err := containerPort(p, intstr.Parse(spec.Port))
		return p, port, err

	case "service":
		svc, err := c.Typed.CoreV1().Services(spec.Namespace).Get(ctx, spec.Name, metav1.GetOptions{})
		if err != nil {
			return nil, 0, err
		}
		if len(svc.Spec.Selector) == 0 {
			return nil, 0, fmt.Errorf("service %s has no selector; forward to a pod instead", svc.Name)
		}
		var sp *corev1.ServicePort
		for i := range svc.Spec.Ports {
			p := &svc.Spec.Ports[i]
			if strconv.Itoa(int(p.Port)) == spec.Port || (p.Name != "" && p.Name == spec.Port) {
				sp = p
				break
			}
		}
		if sp == nil {
			return nil, 0, fmt.Errorf("service %s has no port %q", svc.Name, spec.Port)
		}
		p, err := pickPod(ctx, c, spec.Namespace, metav1.FormatLabelSelector(&metav1.LabelSelector{MatchLabels: svc.Spec.Selector}))
		if err != nil {
			return nil, 0, fmt.Errorf("service %s: %w", svc.Name, err)
		}
		target := sp.TargetPort
		if target.Type == intstr.Int && target.IntVal == 0 {
			target = intstr.FromInt32(sp.Port)
		}
		port, err := containerPort(p, target)
		return p, port, err

	default:
		obj, err := c.Dynamic.Resource(workloadGVR[spec.Kind]).Namespace(spec.Namespace).Get(ctx, spec.Name, metav1.GetOptions{})
		if err != nil {
			return nil, 0, err
		}
		raw, _, _ := unstructuredSelector(obj.Object)
		if raw == nil {
			return nil, 0, fmt.Errorf("%s %s has no selector", spec.Kind, spec.Name)
		}
		sel, err := metav1.LabelSelectorAsSelector(raw)
		if err != nil {
			return nil, 0, err
		}
		p, err := pickPod(ctx, c, spec.Namespace, sel.String())
		if err != nil {
			return nil, 0, fmt.Errorf("%s %s: %w", spec.Kind, spec.Name, err)
		}
		port, err := containerPort(p, intstr.Parse(spec.Port))
		return p, port, err
	}
}

func unstructuredSelector(obj map[string]any) (*metav1.LabelSelector, bool, error) {
	spec, _ := obj["spec"].(map[string]any)
	raw, ok := spec["selector"]
	if !ok {
		return nil, false, nil
	}
	b, err := json.Marshal(raw)
	if err != nil {
		return nil, false, err
	}
	var sel metav1.LabelSelector
	if err := json.Unmarshal(b, &sel); err != nil {
		return nil, false, err
	}
	return &sel, true, nil
}

// pickPod prefers Ready, non-terminating, most recently started pods.
func pickPod(ctx context.Context, c *cluster.Clients, ns, selector string) (*corev1.Pod, error) {
	list, err := c.Typed.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: selector})
	if err != nil {
		return nil, err
	}
	var best *corev1.Pod
	score := func(p *corev1.Pod) int {
		s := 0
		if p.DeletionTimestamp == nil {
			s += 4
		}
		if p.Status.Phase == corev1.PodRunning {
			s += 2
		}
		for _, cnd := range p.Status.Conditions {
			if cnd.Type == corev1.PodReady && cnd.Status == corev1.ConditionTrue {
				s++
			}
		}
		return s
	}
	for i := range list.Items {
		p := &list.Items[i]
		if best == nil || score(p) > score(best) ||
			(score(p) == score(best) && p.CreationTimestamp.After(best.CreationTimestamp.Time)) {
			best = p
		}
	}
	if best == nil || best.Status.Phase != corev1.PodRunning || best.DeletionTimestamp != nil {
		return nil, fmt.Errorf("no running pods match %q", selector)
	}
	return best, nil
}

// containerPort resolves a numeric or named port against the pod's containers.
func containerPort(p *corev1.Pod, port intstr.IntOrString) (int, error) {
	if port.Type == intstr.Int {
		return int(port.IntVal), nil
	}
	for _, ctr := range p.Spec.Containers {
		for _, cp := range ctr.Ports {
			if cp.Name == port.StrVal {
				return int(cp.ContainerPort), nil
			}
		}
	}
	return 0, fmt.Errorf("pod %s has no container port named %q", p.Name, port.StrVal)
}

func freePort(addr string) (int, error) {
	l, err := net.Listen("tcp", net.JoinHostPort(addr, "0"))
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func portFree(addr string, port int) bool {
	l, err := net.Listen("tcp", net.JoinHostPort(addr, strconv.Itoa(port)))
	if err != nil {
		return false
	}
	l.Close()
	return true
}

func hostFor(addr string) string {
	if addr == "" || addr == "0.0.0.0" || addr == "127.0.0.1" {
		return "localhost"
	}
	return addr
}

func newID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
