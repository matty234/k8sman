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
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/tools/portforward"

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
	// OpenInBrowser and HTTPS are the UI's remembered choices for this
	// forward: whether "Open" launches the browser straight away, and the
	// URL scheme.
	OpenInBrowser bool `json:"openInBrowser,omitempty"`
	HTTPS         bool `json:"https,omitempty"`
	// Ephemeral forwards run but are never written to disk, so they are gone
	// after a restart.
	Ephemeral bool `json:"ephemeral,omitempty"`
}

func (s Spec) url() string {
	scheme := "http"
	if s.HTTPS {
		scheme = "https"
	}
	return fmt.Sprintf("%s://%s:%d", scheme, hostFor(s.Address), s.LocalPort)
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
	// removedGone counts saved forwards dropped at startup because their
	// target no longer exists.
	removedGone int
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
		s.Ephemeral = false
		f := &forward{status: Status{Spec: s, State: Stopped}}
		m.forwards[s.ID] = f
		if s.AutoStart {
			m.start(f)
		}
	}
	// Saved forwards whose pod or service has been deleted are dropped
	// quietly (checked in the background; other errors leave them alone and
	// show up as the forward's own warning).
	if len(specs) > 0 {
		go m.dropGone()
	}
	return m, nil
}

// RemovedGone is how many saved forwards were dropped at startup because
// their target no longer exists.
func (m *Manager) RemovedGone() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.removedGone
}

func (m *Manager) dropGone() {
	m.mu.Lock()
	fs := make([]*forward, 0, len(m.forwards))
	for _, f := range m.forwards {
		fs = append(fs, f)
	}
	m.mu.Unlock()
	for _, f := range fs {
		f.mu.Lock()
		spec := f.status.Spec
		f.mu.Unlock()
		if !m.targetGone(spec) {
			continue
		}
		m.mu.Lock()
		_, still := m.forwards[spec.ID]
		delete(m.forwards, spec.ID)
		if still {
			m.removedGone++
		}
		m.mu.Unlock()
		m.stop(f)
	}
	_ = m.save()
}

// targetGone reports whether the forward's target definitely doesn't exist
// (a 404). Any other failure, such as an unreachable cluster, is not "gone".
func (m *Manager) targetGone(spec Spec) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c, err := m.clusters.ClientsIn(spec.Kubeconfig, spec.Context)
	if err != nil {
		return false
	}
	return isGone(getTarget(ctx, c, spec))
}

func isGone(err error) bool { return apierrors.IsNotFound(err) }

// getTarget fetches the forward's pod, service or workload.
func getTarget(ctx context.Context, c *cluster.Clients, spec Spec) error {
	var err error
	switch spec.Kind {
	case "pod":
		_, err = c.Typed.CoreV1().Pods(spec.Namespace).Get(ctx, spec.Name, metav1.GetOptions{})
	case "service":
		_, err = c.Typed.CoreV1().Services(spec.Namespace).Get(ctx, spec.Name, metav1.GetOptions{})
	default:
		_, err = c.Dynamic.Resource(workloadGVR[spec.Kind]).Namespace(spec.Namespace).Get(ctx, spec.Name, metav1.GetOptions{})
	}
	return err
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

// PortInUseError means the requested local port is taken: By is the forward
// of ours holding it, or nil when another process has it. Suggested is a free
// port nearby.
type PortInUseError struct {
	Port      int
	By        *Status
	Suggested int
}

func (e *PortInUseError) Error() string {
	if e.By != nil {
		return fmt.Sprintf("local port %d is already used by forward %s/%s/%s:%s", e.Port, e.By.Namespace, e.By.Kind, e.By.Name, e.By.Port)
	}
	return fmt.Sprintf("local port %d is in use by another process", e.Port)
}

// nextFreePort is the first port after port that is free and not taken by a
// forward of ours, falling back to any free port.
func nextFreePort(addr string, port int, taken map[int]bool) int {
	for p := port + 1; p < port+200 && p < 65536; p++ {
		if !taken[p] && portFree(addr, p) {
			return p
		}
	}
	p, _ := freePort(addr)
	return p
}

// FreeLocalPort picks a local port for a forward to remote port want (0 when
// the port is a name): want itself when it is >= 1024 and free (not held by
// another process or a running forward of ours), else the next free port.
// Privileged ports map to want+8000 (80 -> 8080). exact says want was used.
func (m *Manager) FreeLocalPort(addr string, want int) (port int, exact bool, err error) {
	if addr == "" {
		addr = "127.0.0.1"
	}
	taken := map[int]bool{}
	m.mu.Lock()
	for _, f := range m.forwards {
		f.mu.Lock()
		if f.status.State != Stopped && f.status.Address == addr {
			taken[f.status.LocalPort] = true
		}
		f.mu.Unlock()
	}
	m.mu.Unlock()
	if want >= 1024 && want < 65536 && !taken[want] && portFree(addr, want) {
		return want, true, nil
	}
	if want > 0 && want < 1024 {
		want += 8000
	}
	if want >= 1024 && want < 65536 {
		if !taken[want] && portFree(addr, want) {
			return want, false, nil
		}
		if p := nextFreePort(addr, want, taken); p != 0 {
			return p, false, nil
		}
	}
	p, err := freePort(addr)
	return p, false, err
}

var validKinds = map[string]bool{"pod": true, "service": true, "deployment": true, "statefulset": true, "daemonset": true, "replicaset": true}

// Create validates, persists and starts a new forward. LocalPort 0 picks a
// free port (and keeps it stable across reconnects/restarts).
func (m *Manager) Create(s Spec, replace bool) (Status, error) {
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
	autoPort := s.LocalPort == 0
	if autoPort {
		// Prefer the same port number locally when it's free (nicer URLs).
		n, _ := strconv.Atoi(s.Port)
		p, _, err := m.FreeLocalPort(s.Address, n)
		if err != nil {
			return Status{}, err
		}
		s.LocalPort = p
	}
	explicit := s.LocalPort != 0 && !autoPort
	m.mu.Lock()
	var clashing []*forward
	var first *Status
	taken := map[int]bool{}
	for _, f := range m.forwards {
		f.mu.Lock()
		st := f.status
		f.mu.Unlock()
		if st.State == Stopped || st.Address != s.Address {
			continue
		}
		taken[st.LocalPort] = true
		if st.LocalPort == s.LocalPort {
			clashing = append(clashing, f)
			if first == nil {
				first = &st
			}
		}
	}
	if len(clashing) > 0 && !replace {
		m.mu.Unlock()
		return Status{}, &PortInUseError{Port: s.LocalPort, By: first, Suggested: nextFreePort(s.Address, s.LocalPort, taken)}
	}
	if len(clashing) == 0 && explicit && !portFree(s.Address, s.LocalPort) {
		m.mu.Unlock()
		return Status{}, &PortInUseError{Port: s.LocalPort, Suggested: nextFreePort(s.Address, s.LocalPort, taken)}
	}
	// Replacing: forget the old forwards in the same step as adding the new
	// one, so the saved set never holds both.
	for _, o := range clashing {
		for id, f := range m.forwards {
			if f == o {
				delete(m.forwards, id)
			}
		}
	}
	s.ID = newID()
	f := &forward{status: Status{Spec: s, State: Stopped}}
	m.forwards[s.ID] = f
	m.mu.Unlock()
	for _, o := range clashing {
		m.stop(o)
	}
	if err := m.save(); err != nil {
		return Status{}, err
	}
	m.start(f)
	st, _ := m.Get(s.ID)
	return st, nil
}

// Changes are the mutable settings of a forward; nil fields are left alone.
type Changes struct {
	AutoStart     *bool
	Label         *string
	LocalPort     *int
	OpenInBrowser *bool
	HTTPS         *bool
}

// Update changes mutable settings. Changing the local port restarts a running
// forward.
func (m *Manager) Update(id string, ch Changes) (Status, error) {
	autoStart, label, localPort := ch.AutoStart, ch.Label, ch.LocalPort
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
	if ch.OpenInBrowser != nil {
		f.status.OpenInBrowser = *ch.OpenInBrowser
	}
	if ch.HTTPS != nil {
		f.status.HTTPS = *ch.HTTPS
		if f.status.State != Stopped {
			f.status.URL = f.status.Spec.url()
		}
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

// StopContext stops every running forward of a context ("" = all contexts),
// keeping them saved, and returns how many it stopped.
func (m *Manager) StopContext(contextName string) int {
	m.mu.Lock()
	var fs []*forward
	for _, f := range m.forwards {
		f.mu.Lock()
		if f.status.State != Stopped && (contextName == "" || f.status.Context == contextName) {
			fs = append(fs, f)
		}
		f.mu.Unlock()
	}
	m.mu.Unlock()
	for _, f := range fs {
		m.stop(f)
	}
	return len(fs)
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
		if !f.status.Ephemeral {
			specs = append(specs, f.status.Spec)
		}
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
	f.status.URL = f.status.Spec.url()
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

	dialer, err := podDialer(c, spec.Namespace, pod.Name)
	if err != nil {
		return err
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
