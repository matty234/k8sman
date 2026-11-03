package cluster

import (
	"errors"
	"fmt"
	"slices"
	"sort"
	"sync"

	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

// Manager holds the active Clients and can switch contexts and kubeconfig
// files.
type Manager struct {
	mu sync.RWMutex
	// kubeconfig is the explicit kubeconfig path ("" = default loading
	// rules: $KUBECONFIG or ~/.kube/config).
	kubeconfig string
	rules      *clientcmd.ClientConfigLoadingRules
	current    *Clients
	// byName caches clients per kubeconfig path + context.
	byName map[string]*Clients
	// connectErr is why there is no current context (see NewDisconnected).
	connectErr error
}

// rulesFor returns loading rules for an explicit path ("" = default rules).
func rulesFor(kubeconfig string) *clientcmd.ClientConfigLoadingRules {
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	if kubeconfig != "" {
		rules.ExplicitPath = kubeconfig
	}
	return rules
}

func cacheKey(kubeconfig, context string) string { return kubeconfig + "\x00" + context }

// NewManager loads kubeconfig (explicit path, or default rules incl. $KUBECONFIG)
// and connects to the given context ("" = kubeconfig's current-context).
func NewManager(kubeconfig, contextName string) (*Manager, error) {
	m := &Manager{kubeconfig: kubeconfig, rules: rulesFor(kubeconfig)}
	if err := m.SwitchContext(contextName); err != nil {
		return nil, err
	}
	return m, nil
}

// NewDisconnected returns a Manager with no active context, e.g. when no
// usable kubeconfig exists yet. Clients returns nil until SwitchKubeconfig or
// SwitchContext succeeds; Err reports why.
func NewDisconnected(kubeconfig string, err error) *Manager {
	return &Manager{kubeconfig: kubeconfig, rules: rulesFor(kubeconfig), connectErr: err}
}

// Clients returns the current client snapshot, or nil when disconnected.
func (m *Manager) Clients() *Clients {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.current
}

// Err is the reason the manager has no active context (nil when connected).
func (m *Manager) Err() error {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if m.current != nil {
		return nil
	}
	if m.connectErr == nil {
		return errors.New("no kube context selected")
	}
	return m.connectErr
}

// Kubeconfig is the active kubeconfig path ("" = default loading rules).
func (m *Manager) Kubeconfig() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.kubeconfig
}

// Contexts lists the contexts in kubeconfig and the active one.
func (m *Manager) Contexts() (current string, out []ContextInfo, err error) {
	m.mu.RLock()
	rules := m.rules
	m.mu.RUnlock()
	raw, err := rules.Load()
	if err != nil {
		return "", nil, err
	}
	out = []ContextInfo{}
	for name, c := range raw.Contexts {
		out = append(out, ContextInfo{Name: name, Cluster: c.Cluster, User: c.AuthInfo, Namespace: c.Namespace})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	if c := m.Clients(); c != nil {
		current = c.Context
	}
	return current, out, nil
}

// SwitchContext makes the named context ("" = kubeconfig current-context) active.
func (m *Manager) SwitchContext(name string) error {
	c, err := m.ClientsFor(name)
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.current = c
	m.connectErr = nil
	m.mu.Unlock()
	return nil
}

// SwitchKubeconfig validates the file at path, makes it the active
// kubeconfig and connects to contextName, falling back to the file's
// current-context (or its first context) when contextName is "" or not in
// the file. Cached clients are dropped; callers already holding a *Clients
// (running watches, port-forwards) keep working.
func (m *Manager) SwitchKubeconfig(path, contextName string) error {
	info := InspectKubeconfig(path)
	if info.Error != "" {
		return errors.New(info.Error)
	}
	if len(info.Contexts) == 0 {
		return fmt.Errorf("%s has no contexts", path)
	}
	if !slices.Contains(info.Contexts, contextName) {
		contextName = info.CurrentContext
		if !slices.Contains(info.Contexts, contextName) {
			contextName = info.Contexts[0]
		}
	}
	c, err := buildClients(rulesFor(path), contextName)
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.kubeconfig = path
	m.rules = rulesFor(path)
	m.byName = map[string]*Clients{cacheKey(path, c.Context): c}
	m.current = c
	m.connectErr = nil
	m.mu.Unlock()
	return nil
}

// ClientsFor returns (cached) clients for any context of the active
// kubeconfig without changing the active one.
func (m *Manager) ClientsFor(name string) (*Clients, error) {
	return m.ClientsIn(m.Kubeconfig(), name)
}

// ClientsIn returns (cached) clients for a context of any kubeconfig file
// ("" = default loading rules) without changing the active one. Long-lived
// work such as port-forwards uses this so it keeps working after the user
// switches to another kubeconfig.
func (m *Manager) ClientsIn(kubeconfig, name string) (*Clients, error) {
	if name != "" {
		m.mu.RLock()
		cached := m.byName[cacheKey(kubeconfig, name)]
		m.mu.RUnlock()
		if cached != nil {
			return cached, nil
		}
	}
	c, err := buildClients(rulesFor(kubeconfig), name)
	if err != nil {
		return nil, err
	}
	key := cacheKey(kubeconfig, c.Context)
	m.mu.Lock()
	defer m.mu.Unlock()
	if cached := m.byName[key]; cached != nil {
		return cached, nil
	}
	if m.byName == nil {
		m.byName = map[string]*Clients{}
	}
	m.byName[key] = c
	return c, nil
}

func buildClients(rules *clientcmd.ClientConfigLoadingRules, name string) (*Clients, error) {
	overrides := &clientcmd.ConfigOverrides{}
	if name != "" {
		overrides.CurrentContext = name
	}
	cc := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, overrides)
	raw, err := cc.RawConfig()
	if err != nil {
		return nil, fmt.Errorf("load kubeconfig: %w", err)
	}
	if name == "" {
		name = raw.CurrentContext
	}
	if name == "" {
		return nil, errors.New("kubeconfig has no current-context")
	}
	if _, ok := raw.Contexts[name]; !ok {
		return nil, fmt.Errorf("context %q not found in kubeconfig", name)
	}
	cfg, err := cc.ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("client config for %q: %w", name, err)
	}
	cfg.QPS, cfg.Burst = 50, 100
	ns, _, _ := cc.Namespace()

	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, err
	}
	typed, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, err
	}
	dc, err := discovery.NewDiscoveryClientForConfig(cfg)
	if err != nil {
		return nil, err
	}
	return &Clients{
		Context:    name,
		Namespace:  ns,
		RESTConfig: cfg,
		Dynamic:    dyn,
		Typed:      typed,
		Discovery:  memory.NewMemCacheClient(dc),
	}, nil
}
