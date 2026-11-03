package security

import (
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
)

// Openness of a direction for a pod, from least to most open.
const (
	OpenNone     = ""         // not allowed by any rule
	OpenCluster  = "cluster"  // all pods in all namespaces
	OpenInternet = "internet" // any source, including outside the cluster
)

// Direction modes for a namespace in the network matrix.
const (
	ModeOpen       = "open"       // no pod is isolated in this direction
	ModePartial    = "partial"    // some pods are isolated
	ModeRestricted = "restricted" // every pod is isolated
	ModeDenyAll    = "default-deny"
)

// NamespaceNetwork is one row of the network matrix.
type NamespaceNetwork struct {
	Namespace   string `json:"namespace"`
	Policies    int    `json:"policies"`
	Workloads   int    `json:"workloads"`
	Ingress     string `json:"ingress"`
	Egress      string `json:"egress"`
	IngressOpen int    `json:"ingressOpen"` // workloads not ingress-isolated
	EgressOpen  int    `json:"egressOpen"`
	Exposed     int    `json:"exposed"` // LoadBalancer/NodePort/externalIPs services, Ingresses, Gateways
	PSA         string `json:"psa,omitempty"`
}

// EffectivePolicyTypes returns the explicit policyTypes, or the API server's
// default: Ingress, plus Egress when the spec has egress rules.
func EffectivePolicyTypes(np *networkingv1.NetworkPolicy) (ingress, egress bool) {
	if len(np.Spec.PolicyTypes) == 0 {
		return true, len(np.Spec.Egress) > 0
	}
	for _, t := range np.Spec.PolicyTypes {
		switch t {
		case networkingv1.PolicyTypeIngress:
			ingress = true
		case networkingv1.PolicyTypeEgress:
			egress = true
		}
	}
	return
}

// selectorMatches evaluates a LabelSelector; an empty selector matches
// everything and an invalid one matches nothing.
func selectorMatches(sel *metav1.LabelSelector, l map[string]string) bool {
	if sel == nil {
		return true
	}
	s, err := metav1.LabelSelectorAsSelector(sel)
	if err != nil {
		return false
	}
	return s.Matches(labels.Set(l))
}

// PolicySelects reports whether np applies to a pod with labels l in ns.
// An empty podSelector selects every pod in the policy's namespace.
func PolicySelects(np *networkingv1.NetworkPolicy, ns string, l map[string]string) bool {
	return np.Namespace == ns && selectorMatches(&np.Spec.PodSelector, l)
}

func isEmptySelector(s *metav1.LabelSelector) bool {
	return s != nil && len(s.MatchLabels) == 0 && len(s.MatchExpressions) == 0
}

func anyCIDR(c string) bool { return c == "0.0.0.0/0" || c == "::/0" }

// PeerOpenness classifies one peer: an ipBlock of 0.0.0.0/0 is the
// internet; `namespaceSelector: {}` with no (or an empty) podSelector is
// every pod in the cluster. namespaceSelector and podSelector in the same
// peer are AND'ed, so a non-empty podSelector narrows it to specific pods.
func PeerOpenness(p networkingv1.NetworkPolicyPeer) string {
	if p.IPBlock != nil {
		if anyCIDR(p.IPBlock.CIDR) {
			return OpenInternet
		}
		return OpenNone
	}
	if p.NamespaceSelector != nil && isEmptySelector(p.NamespaceSelector) && (p.PodSelector == nil || isEmptySelector(p.PodSelector)) {
		return OpenCluster
	}
	return OpenNone
}

// rulesOpenness returns the most open reach across rules. A rule with no
// peers allows every source (or destination), including the internet.
func rulesOpenness(peerLists [][]networkingv1.NetworkPolicyPeer) string {
	best := OpenNone
	for _, peers := range peerLists {
		if len(peers) == 0 {
			return OpenInternet
		}
		for _, p := range peers {
			switch PeerOpenness(p) {
			case OpenInternet:
				return OpenInternet
			case OpenCluster:
				best = OpenCluster
			}
		}
	}
	return best
}

// IngressOpenness is how open the policy's ingress rules are ("" when the
// policy doesn't restrict ingress or allows only specific peers).
func IngressOpenness(np *networkingv1.NetworkPolicy) string {
	if in, _ := EffectivePolicyTypes(np); !in {
		return OpenNone
	}
	var lists [][]networkingv1.NetworkPolicyPeer
	for _, r := range np.Spec.Ingress {
		lists = append(lists, r.From)
	}
	return rulesOpenness(lists)
}

// EgressOpenness is IngressOpenness for egress.
func EgressOpenness(np *networkingv1.NetworkPolicy) string {
	if _, eg := EffectivePolicyTypes(np); !eg {
		return OpenNone
	}
	var lists [][]networkingv1.NetworkPolicyPeer
	for _, r := range np.Spec.Egress {
		lists = append(lists, r.To)
	}
	return rulesOpenness(lists)
}

// IsDefaultDeny reports whether np is a default-deny for ingress / egress:
// it selects every pod and has the policy type with no rules.
func IsDefaultDeny(np *networkingv1.NetworkPolicy) (ingress, egress bool) {
	if !isEmptySelector(&np.Spec.PodSelector) {
		return false, false
	}
	in, eg := EffectivePolicyTypes(np)
	return in && len(np.Spec.Ingress) == 0, eg && len(np.Spec.Egress) == 0
}

// Protection summarises the policies that select a pod.
type Protection struct {
	IngressIsolated bool   // selected by some policy with the Ingress type
	EgressIsolated  bool   // selected by some policy with the Egress type
	IngressOpen     string // most open ingress allowed by a selecting policy
	EgressOpen      string
}

// ProtectionFor evaluates every policy against a pod with labels l in ns.
func ProtectionFor(policies []networkingv1.NetworkPolicy, ns string, l map[string]string) Protection {
	var p Protection
	for i := range policies {
		np := &policies[i]
		if !PolicySelects(np, ns, l) {
			continue
		}
		in, eg := EffectivePolicyTypes(np)
		if in {
			p.IngressIsolated = true
			p.IngressOpen = maxOpen(p.IngressOpen, IngressOpenness(np))
		}
		if eg {
			p.EgressIsolated = true
			p.EgressOpen = maxOpen(p.EgressOpen, EgressOpenness(np))
		}
	}
	return p
}

func maxOpen(a, b string) string {
	rank := map[string]int{OpenNone: 0, OpenCluster: 1, OpenInternet: 2}
	if rank[b] > rank[a] {
		return b
	}
	return a
}

// IngressProtected: isolated, and no selecting policy re-opens it to the internet.
func (p Protection) IngressProtected() bool {
	return p.IngressIsolated && p.IngressOpen != OpenInternet
}

type netIndex struct {
	byNS       map[string][]networkingv1.NetworkPolicy
	protection map[*unit]Protection
}

func (a *analyzer) unitsIn(ns string) []*unit {
	var out []*unit
	for _, u := range a.units {
		if u.ref.Namespace == ns {
			out = append(out, u)
		}
	}
	return out
}

// backing returns the units in ns whose pod labels match a Service selector.
func (a *analyzer) backing(ns string, sel map[string]string) []*unit {
	if len(sel) == 0 {
		return nil
	}
	var out []*unit
	s := labels.SelectorFromSet(sel)
	for _, u := range a.unitsIn(ns) {
		if s.Matches(labels.Set(u.meta.Labels)) {
			out = append(out, u)
		}
	}
	return out
}

func (a *analyzer) describeBacking(us []*unit) (string, bool, []ObjectRef) {
	if len(us) == 0 {
		return "no matching workloads", false, nil
	}
	names := []string{}
	refs := []ObjectRef{}
	protected := true
	for _, u := range us {
		names = append(names, kindLabel(u.ref))
		refs = append(refs, u.ref)
		if !a.net.protection[u].IngressProtected() {
			protected = false
		}
	}
	return joinLimit(names, 4), protected, refs
}

func protectionText(protected bool) string {
	if protected {
		return "Its pods are protected by an ingress NetworkPolicy."
	}
	return "Its pods are not protected by any ingress NetworkPolicy, so every port they listen on is reachable."
}

func (a *analyzer) network() {
	a.net = &netIndex{byNS: map[string][]networkingv1.NetworkPolicy{}, protection: map[*unit]Protection{}}
	for _, np := range a.in.NetworkPolicies {
		a.net.byNS[np.Namespace] = append(a.net.byNS[np.Namespace], np)
	}
	for _, u := range a.units {
		a.net.protection[u] = ProtectionFor(a.net.byNS[u.ref.Namespace], u.ref.Namespace, u.meta.Labels)
	}

	exposedPerNS := map[string]int{}
	a.services(exposedPerNS)
	a.ingresses(exposedPerNS)
	a.gateways(exposedPerNS)
	a.policies()
	a.hostNetworking()
	a.namespaceMatrix(exposedPerNS)
}

func (a *analyzer) policies() {
	for i := range a.in.NetworkPolicies {
		np := &a.in.NetworkPolicies[i]
		if !a.inScope(np.Namespace) {
			continue
		}
		ref := ObjectRef{Group: "networking.k8s.io", Kind: "NetworkPolicy", Name: np.Name, Namespace: np.Namespace}
		applies := "pods matching " + selectorText(&np.Spec.PodSelector)
		if isEmptySelector(&np.Spec.PodSelector) {
			applies = "every pod in " + np.Namespace
		}
		switch IngressOpenness(np) {
		case OpenInternet:
			a.add(Finding{ID: "network.policy-allows-any-ingress/" + refKey(ref), Check: "network.policy-allows-any-ingress", Severity: Medium, Category: CatNetwork, Namespace: np.Namespace,
				Title:       fmt.Sprintf("NetworkPolicy %s allows ingress from anywhere", np.Name),
				Detail:      fmt.Sprintf("A rule with no `from` peers or an ipBlock of 0.0.0.0/0 lets any source, including outside the cluster, reach %s.", applies),
				Remediation: "Restrict `from` to the namespaces/pods (or CIDRs) that need access, and the `ports` they need.",
				Objects:     []ObjectRef{ref}})
		case OpenCluster:
			a.add(Finding{ID: "network.policy-allows-cluster-ingress/" + refKey(ref), Check: "network.policy-allows-cluster-ingress", Severity: Low, Category: CatNetwork, Namespace: np.Namespace,
				Title:       fmt.Sprintf("NetworkPolicy %s allows ingress from every namespace", np.Name),
				Detail:      fmt.Sprintf("A peer with `namespaceSelector: {}` and no podSelector lets every pod in the cluster reach %s.", applies),
				Remediation: "Narrow the namespaceSelector (e.g. `kubernetes.io/metadata.name`) and add a podSelector in the same peer.",
				Objects:     []ObjectRef{ref}})
		}
		if EgressOpenness(np) == OpenInternet {
			a.add(Finding{ID: "network.policy-allows-any-egress/" + refKey(ref), Check: "network.policy-allows-any-egress", Severity: Low, Category: CatNetwork, Namespace: np.Namespace,
				Title:       fmt.Sprintf("NetworkPolicy %s allows egress to anywhere", np.Name),
				Detail:      fmt.Sprintf("A rule with no `to` peers or an ipBlock of 0.0.0.0/0 lets %s connect to any destination, which eases data exfiltration.", applies),
				Remediation: "Allow DNS and the specific destinations the workload needs instead of 0.0.0.0/0.",
				Objects:     []ObjectRef{ref}})
		}
	}
}

func selectorText(s *metav1.LabelSelector) string {
	if s == nil {
		return "anything"
	}
	parts := []string{}
	for k, v := range s.MatchLabels {
		parts = append(parts, k+"="+v)
	}
	sort.Strings(parts)
	for _, e := range s.MatchExpressions {
		parts = append(parts, fmt.Sprintf("%s %s (%s)", e.Key, strings.ToLower(string(e.Operator)), strings.Join(e.Values, ", ")))
	}
	if len(parts) == 0 {
		return "anything"
	}
	return strings.Join(parts, ", ")
}

func (a *analyzer) services(exposed map[string]int) {
	for i := range a.in.Services {
		s := &a.in.Services[i]
		if !a.inScope(s.Namespace) {
			continue
		}
		ref := ObjectRef{Kind: "Service", Name: s.Name, Namespace: s.Namespace}
		us := a.backing(s.Namespace, s.Spec.Selector)
		what, protected, refs := a.describeBacking(us)
		objs := append([]ObjectRef{ref}, refs...)
		ports := []string{}
		lowNodePorts := []string{}
		for _, p := range s.Spec.Ports {
			if p.NodePort != 0 {
				ports = append(ports, fmt.Sprintf("%d→%d", p.NodePort, p.Port))
				if p.NodePort < 1024 {
					lowNodePorts = append(lowNodePorts, fmt.Sprint(p.NodePort))
				}
			} else {
				ports = append(ports, fmt.Sprint(p.Port))
			}
		}
		isExposed := false
		switch s.Spec.Type {
		case corev1.ServiceTypeLoadBalancer:
			isExposed = true
			sev, src := Medium, "any source"
			if len(s.Spec.LoadBalancerSourceRanges) > 0 {
				sev, src = Low, strings.Join(s.Spec.LoadBalancerSourceRanges, ", ")
			} else if !protected {
				sev = High
			}
			addr := "pending address"
			for _, ing := range s.Status.LoadBalancer.Ingress {
				addr = ing.IP + ing.Hostname
			}
			a.add(Finding{ID: "network.loadbalancer/" + refKey(ref), Check: "network.loadbalancer", Severity: sev, Category: CatNetwork, Namespace: s.Namespace,
				Title:       fmt.Sprintf("LoadBalancer Service %s is exposed externally", s.Name),
				Detail:      fmt.Sprintf("Exposes %s (ports %s, %s) to %s, backed by %s. %s", what, strings.Join(ports, ", "), addr, src, what, protectionText(protected)),
				Remediation: "Set `loadBalancerSourceRanges` to the client CIDRs, use an internal load balancer, or put it behind an Ingress/Gateway with TLS and auth. Add an ingress NetworkPolicy for the backing pods.",
				Objects:     objs})
		case corev1.ServiceTypeNodePort:
			isExposed = true
			sev := Low
			if !protected {
				sev = Medium
			}
			a.add(Finding{ID: "network.nodeport/" + refKey(ref), Check: "network.nodeport", Severity: sev, Category: CatNetwork, Namespace: s.Namespace,
				Title:       fmt.Sprintf("NodePort Service %s opens ports on every node", s.Name),
				Detail:      fmt.Sprintf("Node ports %s reach %s from anything that can reach a node. %s", strings.Join(ports, ", "), what, protectionText(protected)),
				Remediation: "Use ClusterIP behind an Ingress or Gateway, or restrict node access with firewall rules.",
				Objects:     objs})
		}
		if len(s.Spec.ExternalIPs) > 0 {
			isExposed = true
			a.add(Finding{ID: "network.externalips/" + refKey(ref), Check: "network.externalips", Severity: Medium, Category: CatNetwork, Namespace: s.Namespace,
				Title:       fmt.Sprintf("Service %s uses externalIPs", s.Name),
				Detail:      fmt.Sprintf("Traffic to %s is routed to %s. externalIPs can also be used to intercept traffic (CVE-2020-8554). %s", strings.Join(s.Spec.ExternalIPs, ", "), what, protectionText(protected)),
				Remediation: "Prefer a LoadBalancer or Ingress; block externalIPs cluster-wide with an admission policy if unused.",
				Objects:     objs})
		}
		if len(lowNodePorts) > 0 {
			a.add(Finding{ID: "practices.privileged-nodeport/" + refKey(ref), Check: "practices.privileged-nodeport", Severity: Medium, Category: CatPractices, Namespace: s.Namespace,
				Title:       fmt.Sprintf("Service %s uses a privileged node port", s.Name),
				Detail:      fmt.Sprintf("Node ports %s are below 1024, which means the API server's --service-node-port-range was widened; they can collide with host services such as SSH or the kubelet.", strings.Join(lowNodePorts, ", ")),
				Remediation: "Keep the default 30000-32767 node port range.",
				Objects:     []ObjectRef{ref}})
		}
		if isExposed {
			exposed[s.Namespace]++
		}
	}
}

func (a *analyzer) serviceByName(ns, name string) *corev1.Service {
	for i := range a.in.Services {
		if a.in.Services[i].Namespace == ns && a.in.Services[i].Name == name {
			return &a.in.Services[i]
		}
	}
	return nil
}

// serviceTargets resolves service names to the services and their backing units.
func (a *analyzer) serviceTargets(ns string, names []string) (string, bool, []ObjectRef) {
	refs := []ObjectRef{}
	var us []*unit
	seen := map[string]bool{}
	for _, n := range uniqSorted(names) {
		refs = append(refs, ObjectRef{Kind: "Service", Name: n, Namespace: ns})
		if s := a.serviceByName(ns, n); s != nil {
			for _, u := range a.backing(ns, s.Spec.Selector) {
				if !seen[refKey(u.ref)] {
					seen[refKey(u.ref)] = true
					us = append(us, u)
				}
			}
		}
	}
	what, protected, urefs := a.describeBacking(us)
	return what, protected, append(refs, urefs...)
}

func (a *analyzer) ingresses(exposed map[string]int) {
	for i := range a.in.Ingresses {
		ing := &a.in.Ingresses[i]
		if !a.inScope(ing.Namespace) {
			continue
		}
		exposed[ing.Namespace]++
		ref := ObjectRef{Group: "networking.k8s.io", Kind: "Ingress", Name: ing.Name, Namespace: ing.Namespace}
		hosts := []string{}
		svcs := []string{}
		if b := ing.Spec.DefaultBackend; b != nil && b.Service != nil {
			svcs = append(svcs, b.Service.Name)
			hosts = append(hosts, "*")
		}
		for _, r := range ing.Spec.Rules {
			h := r.Host
			if h == "" {
				h = "*"
			}
			hosts = append(hosts, h)
			if r.HTTP != nil {
				for _, p := range r.HTTP.Paths {
					if p.Backend.Service != nil {
						svcs = append(svcs, p.Backend.Service.Name)
					}
				}
			}
		}
		hosts = uniqSorted(hosts)
		what, protected, objs := a.serviceTargets(ing.Namespace, svcs)
		tlsHosts := map[string]bool{}
		for _, t := range ing.Spec.TLS {
			for _, h := range t.Hosts {
				tlsHosts[h] = true
			}
		}
		a.add(Finding{ID: "network.ingress/" + refKey(ref), Check: "network.ingress", Severity: Info, Category: CatNetwork, Namespace: ing.Namespace,
			Title:       fmt.Sprintf("Ingress %s exposes %s", ing.Name, joinLimit(hosts, 3)),
			Detail:      fmt.Sprintf("Routes %s to services %s, backed by %s. %s", strings.Join(hosts, ", "), joinLimit(uniqSorted(svcs), 4), what, protectionText(protected)),
			Remediation: "Confirm these hosts are meant to be public; add authentication at the ingress controller where needed.",
			Objects:     append([]ObjectRef{ref}, objs...)})
		var plain []string
		for _, h := range hosts {
			if !tlsHosts[h] {
				plain = append(plain, h)
			}
		}
		if len(plain) > 0 {
			a.add(Finding{ID: "practices.ingress-no-tls/" + refKey(ref), Check: "practices.ingress-no-tls", Severity: Medium, Category: CatPractices, Namespace: ing.Namespace,
				Title:       fmt.Sprintf("Ingress %s serves %s without TLS", ing.Name, joinLimit(plain, 3)),
				Detail:      "Hosts without a `tls` entry are served over plain HTTP, so credentials and cookies travel unencrypted.",
				Remediation: "Add a `spec.tls` entry with a certificate (e.g. from cert-manager) and redirect HTTP to HTTPS.",
				Objects:     []ObjectRef{ref}})
		}
	}
}

func (a *analyzer) gateways(exposed map[string]int) {
	// Routes by parent gateway (ns/name).
	routes := map[string][]*unstructured.Unstructured{}
	for i := range a.in.HTTPRoutes {
		r := &a.in.HTTPRoutes[i]
		parents, _, _ := unstructured.NestedSlice(r.Object, "spec", "parentRefs")
		for _, p := range parents {
			pm, _ := p.(map[string]any)
			name, _ := pm["name"].(string)
			ns, _ := pm["namespace"].(string)
			if ns == "" {
				ns = r.GetNamespace()
			}
			routes[key(ns, name)] = append(routes[key(ns, name)], r)
		}
	}
	for i := range a.in.Gateways {
		g := &a.in.Gateways[i]
		if !a.inScope(g.GetNamespace()) {
			continue
		}
		exposed[g.GetNamespace()]++
		ref := ObjectRef{Group: "gateway.networking.k8s.io", Kind: "Gateway", Name: g.GetName(), Namespace: g.GetNamespace()}
		listeners, _, _ := unstructured.NestedSlice(g.Object, "spec", "listeners")
		ls := []string{}
		plain := []string{}
		for _, l := range listeners {
			lm, _ := l.(map[string]any)
			proto, _ := lm["protocol"].(string)
			host, _ := lm["hostname"].(string)
			if host == "" {
				host = "*"
			}
			port, _, _ := unstructured.NestedFieldNoCopy(lm, "port")
			ls = append(ls, fmt.Sprintf("%s %s:%v", proto, host, port))
			if proto == "HTTP" || proto == "TCP" || proto == "UDP" {
				plain = append(plain, fmt.Sprintf("%s:%v", host, port))
			}
		}
		objs := []ObjectRef{ref}
		routeNames := []string{}
		backendsByNS := map[string][]string{}
		for _, r := range routes[key(g.GetNamespace(), g.GetName())] {
			routeNames = append(routeNames, r.GetName())
			objs = append(objs, ObjectRef{Group: "gateway.networking.k8s.io", Kind: "HTTPRoute", Name: r.GetName(), Namespace: r.GetNamespace()})
			rules, _, _ := unstructured.NestedSlice(r.Object, "spec", "rules")
			for _, rule := range rules {
				rm, _ := rule.(map[string]any)
				brefs, _, _ := unstructured.NestedSlice(rm, "backendRefs")
				for _, b := range brefs {
					bm, _ := b.(map[string]any)
					kind, _ := bm["kind"].(string)
					if kind != "" && kind != "Service" {
						continue
					}
					name, _ := bm["name"].(string)
					ns, _ := bm["namespace"].(string)
					if ns == "" {
						ns = r.GetNamespace()
					}
					backendsByNS[ns] = append(backendsByNS[ns], name)
				}
			}
		}
		detail := fmt.Sprintf("Listeners: %s.", joinLimit(ls, 5))
		if len(routeNames) == 0 {
			detail += " No HTTPRoutes are attached."
		} else {
			allProtected := true
			whats := []string{}
			nss := make([]string, 0, len(backendsByNS))
			for ns := range backendsByNS {
				nss = append(nss, ns)
			}
			sort.Strings(nss)
			for _, ns := range nss {
				what, protected, refs := a.serviceTargets(ns, backendsByNS[ns])
				whats = append(whats, what)
				allProtected = allProtected && protected
				objs = append(objs, refs...)
			}
			detail += fmt.Sprintf(" HTTPRoutes %s send traffic to %s. %s", joinLimit(routeNames, 4), joinLimit(whats, 3), protectionText(allProtected))
		}
		a.add(Finding{ID: "network.gateway/" + refKey(ref), Check: "network.gateway", Severity: Info, Category: CatNetwork, Namespace: g.GetNamespace(),
			Title:       fmt.Sprintf("Gateway %s accepts traffic on %s", g.GetName(), plural(len(ls), "listener", "listeners")),
			Detail:      detail,
			Remediation: "Confirm each listener and route is meant to be reachable; restrict `allowedRoutes` to the namespaces that should attach.",
			Objects:     objs})
		if len(plain) > 0 {
			a.add(Finding{ID: "practices.gateway-no-tls/" + refKey(ref), Check: "practices.gateway-no-tls", Severity: Low, Category: CatPractices, Namespace: g.GetNamespace(),
				Title:       fmt.Sprintf("Gateway %s has listeners without TLS", g.GetName()),
				Detail:      fmt.Sprintf("Plain-text listeners: %s.", joinLimit(plain, 5)),
				Remediation: "Use HTTPS/TLS listeners with a certificateRef, and redirect HTTP to HTTPS.",
				Objects:     []ObjectRef{ref}})
		}
	}
}

func (a *analyzer) hostNetworking() {
	for _, u := range a.units {
		hostPorts := []string{}
		for _, c := range allContainers(u.spec) {
			for _, p := range c.Ports {
				if p.HostPort != 0 {
					hostPorts = append(hostPorts, fmt.Sprint(p.HostPort))
				}
			}
		}
		if !u.spec.HostNetwork && len(hostPorts) == 0 {
			continue
		}
		var what string
		switch {
		case u.spec.HostNetwork && len(hostPorts) > 0:
			what = fmt.Sprintf("uses the node's network namespace and host ports %s", strings.Join(hostPorts, ", "))
		case u.spec.HostNetwork:
			what = "uses the node's network namespace"
		default:
			what = fmt.Sprintf("binds host ports %s", strings.Join(hostPorts, ", "))
		}
		a.add(Finding{ID: "network.host-network/" + refKey(u.ref), Check: "network.host-network", Severity: Medium, Category: CatNetwork, Namespace: u.ref.Namespace,
			Title:       fmt.Sprintf("%s %s", kindLabel(u.ref), what),
			Detail:      "Host networking bypasses NetworkPolicy and exposes ports directly on the node; with hostNetwork the pod can also see all node traffic and reach node-local services.",
			Remediation: "Use a Service instead of hostPort, and drop hostNetwork unless this is a CNI/node agent.",
			Objects:     []ObjectRef{u.ref}})
	}
}

func (a *analyzer) namespaceNames() []string {
	names := []string{}
	if a.in.Namespaces != nil {
		for _, n := range a.in.Namespaces {
			if a.inScope(n.Name) {
				names = append(names, n.Name)
			}
		}
	} else {
		for _, u := range a.units {
			names = append(names, u.ref.Namespace)
		}
		if a.in.Namespace != "" {
			names = append(names, a.in.Namespace)
		}
	}
	return uniqSorted(names)
}

func (a *analyzer) namespaceMatrix(exposed map[string]int) {
	var noPolicy, noDefaultDeny []ObjectRef
	for _, ns := range a.namespaceNames() {
		pols := a.net.byNS[ns]
		us := a.unitsIn(ns)
		row := NamespaceNetwork{Namespace: ns, Policies: len(pols), Workloads: len(us), Exposed: exposed[ns], PSA: a.psaLevel(ns)}
		denyIn, denyEg := false, false
		for i := range pols {
			in, eg := IsDefaultDeny(&pols[i])
			denyIn, denyEg = denyIn || in, denyEg || eg
		}
		var inOpen, egOpen []ObjectRef
		for _, u := range us {
			p := a.net.protection[u]
			if !p.IngressProtected() {
				inOpen = append(inOpen, u.ref)
			}
			if !p.EgressIsolated || p.EgressOpen == OpenInternet {
				egOpen = append(egOpen, u.ref)
			}
		}
		row.IngressOpen, row.EgressOpen = len(inOpen), len(egOpen)
		row.Ingress = directionMode(denyIn, len(inOpen), len(us), len(pols))
		row.Egress = directionMode(denyEg, len(egOpen), len(us), len(pols))
		a.res.Network = append(a.res.Network, row)

		nsRef := ObjectRef{Kind: "Namespace", Name: ns}
		if len(us) == 0 {
			continue
		}
		if len(pols) == 0 {
			noPolicy = append(noPolicy, nsRef)
			continue
		}
		if !denyIn || !denyEg {
			noDefaultDeny = append(noDefaultDeny, nsRef)
		}
		if len(inOpen) > 0 {
			a.add(Finding{ID: "network.ingress-unrestricted/" + ns, Check: "network.ingress-unrestricted", Severity: Low, Category: CatNetwork, Namespace: ns,
				Title:       fmt.Sprintf("%s in %s %s ingress from anywhere", plural(len(inOpen), "workload", "workloads"), ns, verb(len(inOpen), "accepts", "accept")),
				Detail:      fmt.Sprintf("%s has NetworkPolicies, but %s %s not selected by any policy that restricts ingress (or a policy re-opens it to 0.0.0.0/0).", ns, joinLimit(refNames(inOpen), 5), isAre(len(inOpen))),
				Remediation: "Add a default-deny ingress policy (`podSelector: {}`, `policyTypes: [Ingress]`) and allow only the traffic each workload needs.",
				Objects:     inOpen})
		}
		if len(egOpen) > 0 {
			a.add(Finding{ID: "network.egress-unrestricted/" + ns, Check: "network.egress-unrestricted", Severity: Info, Category: CatNetwork, Namespace: ns,
				Title:       fmt.Sprintf("%s in %s %s unrestricted egress", plural(len(egOpen), "workload", "workloads"), ns, verb(len(egOpen), "has", "have")),
				Detail:      fmt.Sprintf("%s %s not selected by any policy that restricts egress, so they can connect anywhere, including the internet and the cloud metadata endpoint.", joinLimit(refNames(egOpen), 5), isAre(len(egOpen))),
				Remediation: "Add a default-deny egress policy and allow DNS plus the destinations each workload needs.",
				Objects:     egOpen})
		}
	}
	if len(noPolicy) > 0 {
		a.add(Finding{ID: "network.no-policy", Check: "network.no-policy", Severity: Medium, Category: CatNetwork,
			Title:       fmt.Sprintf("%s %s no NetworkPolicy", plural(len(noPolicy), "namespace", "namespaces"), verb(len(noPolicy), "has", "have")),
			Detail:      fmt.Sprintf("All ingress and egress is open for every pod in %s: any pod in the cluster can reach them, and they can reach anything.", joinLimit(refNames(noPolicy), 6)),
			Remediation: "Start with a default-deny policy per namespace (`podSelector: {}` with `policyTypes: [Ingress, Egress]`), then allow the flows you need.",
			Objects:     noPolicy})
	}
	if len(noDefaultDeny) > 0 {
		a.add(Finding{ID: "network.no-default-deny", Check: "network.no-default-deny", Severity: Low, Category: CatNetwork,
			Title:       fmt.Sprintf("%s %s no default-deny policy", plural(len(noDefaultDeny), "namespace", "namespaces"), verb(len(noDefaultDeny), "has", "have")),
			Detail:      fmt.Sprintf("%s have NetworkPolicies but no default-deny for ingress and egress, so new workloads start out unrestricted.", joinLimit(refNames(noDefaultDeny), 6)),
			Remediation: "Add a policy with `podSelector: {}` and no rules for each direction.",
			Objects:     noDefaultDeny})
	}
}

func directionMode(defaultDeny bool, open, total, policies int) string {
	switch {
	case defaultDeny:
		return ModeDenyAll
	case policies == 0 || open == total:
		return ModeOpen
	case open == 0:
		return ModeRestricted
	default:
		return ModePartial
	}
}

func refNames(refs []ObjectRef) []string {
	out := make([]string, len(refs))
	for i, r := range refs {
		out[i] = r.Name
	}
	return out
}

func verb(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}

func isAre(n int) string {
	if n == 1 {
		return "is"
	}
	return "are"
}
