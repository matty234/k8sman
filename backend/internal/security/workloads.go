package security

import (
	"fmt"
	"sort"
	"strings"

	"github.com/matty234/k8sman/backend/internal/kube"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Pod Security Standards profiles.
const (
	ProfileBaseline   = "baseline"
	ProfileRestricted = "restricted"
	// ProfileExtra marks hardening checks that aren't part of either profile
	// (readOnlyRootFilesystem).
	ProfileExtra = "extra"
)

// Violation is one failed hardening check on a pod spec.
type Violation struct {
	Check    string // stable id, e.g. "privileged"
	Profile  string
	Severity string
	Text     string // "privileged (containers: shell)"
}

// Capabilities a baseline pod may add.
var baselineCaps = map[string]bool{
	"AUDIT_WRITE": true, "CHOWN": true, "DAC_OVERRIDE": true, "FOWNER": true, "FSETID": true, "KILL": true, "MKNOD": true,
	"NET_BIND_SERVICE": true, "SETFCAP": true, "SETGID": true, "SETPCAP": true, "SETUID": true, "SYS_CHROOT": true,
}

// Capabilities that are effectively root on the node.
var criticalCaps = map[string]bool{"SYS_ADMIN": true, "ALL": true, "SYS_MODULE": true, "SYS_PTRACE": true, "BPF": true}

var safeSysctls = map[string]bool{
	"kernel.shm_rmid_forced": true, "net.ipv4.ip_local_port_range": true, "net.ipv4.ip_unprivileged_port_start": true,
	"net.ipv4.tcp_syncookies": true, "net.ipv4.ping_group_range": true, "net.ipv4.ip_local_reserved_ports": true,
	"net.ipv4.tcp_keepalive_time": true, "net.ipv4.tcp_fin_timeout": true, "net.ipv4.tcp_keepalive_intvl": true,
	"net.ipv4.tcp_keepalive_probes": true,
}

var restrictedVolumeOK = func(v corev1.Volume) bool {
	s := v.VolumeSource
	return s.ConfigMap != nil || s.CSI != nil || s.DownwardAPI != nil || s.EmptyDir != nil || s.Ephemeral != nil ||
		s.PersistentVolumeClaim != nil || s.Projected != nil || s.Secret != nil
}

func allContainers(spec *corev1.PodSpec) []corev1.Container {
	out := append([]corev1.Container{}, spec.InitContainers...)
	out = append(out, spec.Containers...)
	for _, e := range spec.EphemeralContainers {
		out = append(out, corev1.Container(e.EphemeralContainerCommon))
	}
	return out
}

// EvaluatePodSpec checks a pod spec (and its template annotations, for
// AppArmor) against the baseline and restricted Pod Security Standards.
func EvaluatePodSpec(spec *corev1.PodSpec, meta metav1.ObjectMeta) []Violation {
	var out []Violation
	addV := func(check, profile, sev, text string) {
		out = append(out, Violation{Check: check, Profile: profile, Severity: sev, Text: text})
	}
	// containers failing a predicate, as "(containers: a, b)"
	failing := func(pred func(c corev1.Container) bool) []string {
		var names []string
		for _, c := range allContainers(spec) {
			if pred(c) {
				names = append(names, c.Name)
			}
		}
		return names
	}
	in := func(names []string) string { return " (" + strings.Join(names, ", ") + ")" }
	psc := spec.SecurityContext
	if psc == nil {
		psc = &corev1.PodSecurityContext{}
	}
	sc := func(c corev1.Container) *corev1.SecurityContext {
		if c.SecurityContext == nil {
			return &corev1.SecurityContext{}
		}
		return c.SecurityContext
	}

	// ---- baseline ----
	if n := failing(func(c corev1.Container) bool { p := sc(c).Privileged; return p != nil && *p }); len(n) > 0 {
		addV("privileged", ProfileBaseline, Critical, "privileged"+in(n))
	}
	var hostNS []string
	if spec.HostPID {
		hostNS = append(hostNS, "hostPID")
	}
	if spec.HostIPC {
		hostNS = append(hostNS, "hostIPC")
	}
	if spec.HostNetwork {
		hostNS = append(hostNS, "hostNetwork")
	}
	if len(hostNS) > 0 {
		sev := High
		if spec.HostPID {
			sev = Critical
		}
		addV("host-namespaces", ProfileBaseline, sev, strings.Join(hostNS, ", "))
	}
	var hostPaths []string
	hostPathSev := High
	for _, v := range spec.Volumes {
		if v.HostPath != nil {
			hostPaths = append(hostPaths, v.HostPath.Path)
			p := strings.TrimRight(v.HostPath.Path, "/")
			if p == "" || p == "/etc" || p == "/var/run" || p == "/run" || strings.HasSuffix(p, ".sock") || p == "/var/lib/kubelet" || p == "/proc" {
				hostPathSev = Critical
			}
		}
	}
	if len(hostPaths) > 0 {
		addV("host-path", ProfileBaseline, hostPathSev, "hostPath volumes"+in(hostPaths))
	}
	var addedCaps, critAdded []string
	for _, c := range allContainers(spec) {
		if caps := sc(c).Capabilities; caps != nil {
			for _, cp := range caps.Add {
				name := strings.TrimPrefix(strings.ToUpper(string(cp)), "CAP_")
				if !baselineCaps[name] {
					addedCaps = append(addedCaps, name)
					if criticalCaps[name] {
						critAdded = append(critAdded, name)
					}
				}
			}
		}
	}
	if len(addedCaps) > 0 {
		sev := High
		if len(critAdded) > 0 {
			sev = Critical
		}
		addV("capabilities", ProfileBaseline, sev, "adds capabilities"+in(uniqSorted(addedCaps)))
	}
	var hostPorts []string
	for _, c := range allContainers(spec) {
		for _, p := range c.Ports {
			if p.HostPort != 0 {
				hostPorts = append(hostPorts, fmt.Sprint(p.HostPort))
			}
		}
	}
	if len(hostPorts) > 0 {
		addV("host-ports", ProfileBaseline, Medium, "hostPort"+in(hostPorts))
	}
	unconfinedAA := failing(func(c corev1.Container) bool {
		if p := sc(c).AppArmorProfile; p != nil && p.Type == corev1.AppArmorProfileTypeUnconfined {
			return true
		}
		return meta.Annotations[corev1.DeprecatedAppArmorBetaContainerAnnotationKeyPrefix+c.Name] == corev1.DeprecatedAppArmorBetaProfileNameUnconfined
	})
	if psc.AppArmorProfile != nil && psc.AppArmorProfile.Type == corev1.AppArmorProfileTypeUnconfined {
		unconfinedAA = append([]string{"pod"}, unconfinedAA...)
	}
	if len(unconfinedAA) > 0 {
		addV("apparmor", ProfileBaseline, High, "AppArmor unconfined"+in(unconfinedAA))
	}
	seLinuxBad := func(o *corev1.SELinuxOptions) bool {
		if o == nil {
			return false
		}
		okType := o.Type == "" || o.Type == "container_t" || o.Type == "container_init_t" || o.Type == "container_kvm_t" || o.Type == "container_engine_t"
		return !okType || o.User != "" || o.Role != ""
	}
	seBad := failing(func(c corev1.Container) bool { return seLinuxBad(sc(c).SELinuxOptions) })
	if seLinuxBad(psc.SELinuxOptions) {
		seBad = append([]string{"pod"}, seBad...)
	}
	if len(seBad) > 0 {
		addV("selinux", ProfileBaseline, Medium, "custom SELinux options"+in(seBad))
	}
	if n := failing(func(c corev1.Container) bool {
		p := sc(c).ProcMount
		return p != nil && *p != corev1.DefaultProcMount
	}); len(n) > 0 {
		addV("proc-mount", ProfileBaseline, High, "unmasked /proc"+in(n))
	}
	podSeccomp := ""
	if psc.SeccompProfile != nil {
		podSeccomp = string(psc.SeccompProfile.Type)
	}
	seccompOf := func(c corev1.Container) string {
		if p := sc(c).SeccompProfile; p != nil {
			return string(p.Type)
		}
		return podSeccomp
	}
	if n := failing(func(c corev1.Container) bool { return seccompOf(c) == string(corev1.SeccompProfileTypeUnconfined) }); len(n) > 0 {
		addV("seccomp-unconfined", ProfileBaseline, High, "seccomp Unconfined"+in(n))
	}
	var unsafeSysctls []string
	for _, s := range psc.Sysctls {
		if !safeSysctls[s.Name] {
			unsafeSysctls = append(unsafeSysctls, s.Name)
		}
	}
	if len(unsafeSysctls) > 0 {
		addV("sysctls", ProfileBaseline, Medium, "unsafe sysctls"+in(unsafeSysctls))
	}

	// ---- restricted ----
	var badVols []string
	for _, v := range spec.Volumes {
		if !restrictedVolumeOK(v) && v.HostPath == nil {
			badVols = append(badVols, v.Name)
		}
	}
	if len(badVols) > 0 {
		addV("volume-types", ProfileRestricted, Low, "volume types outside the restricted set"+in(badVols))
	}
	if n := failing(func(c corev1.Container) bool {
		p := sc(c).AllowPrivilegeEscalation
		return p == nil || *p
	}); len(n) > 0 {
		addV("allow-privilege-escalation", ProfileRestricted, Low, "allowPrivilegeEscalation not false"+in(n))
	}
	if n := failing(func(c corev1.Container) bool {
		u := sc(c).RunAsUser
		if u == nil {
			u = psc.RunAsUser
		}
		return u != nil && *u == 0
	}); len(n) > 0 {
		addV("run-as-root", ProfileRestricted, Medium, "runAsUser 0 (root)"+in(n))
	}
	if n := failing(func(c corev1.Container) bool {
		r := sc(c).RunAsNonRoot
		if r == nil {
			r = psc.RunAsNonRoot
		}
		return r == nil || !*r
	}); len(n) > 0 {
		addV("run-as-non-root", ProfileRestricted, Low, "runAsNonRoot not set"+in(n))
	}
	if n := failing(func(c corev1.Container) bool {
		t := seccompOf(c)
		return t != string(corev1.SeccompProfileTypeRuntimeDefault) && t != string(corev1.SeccompProfileTypeLocalhost) && t != string(corev1.SeccompProfileTypeUnconfined)
	}); len(n) > 0 {
		addV("seccomp", ProfileRestricted, Low, "no seccompProfile (RuntimeDefault)"+in(n))
	}
	if n := failing(func(c corev1.Container) bool {
		caps := sc(c).Capabilities
		if caps == nil {
			return true
		}
		for _, d := range caps.Drop {
			if strings.ToUpper(string(d)) == "ALL" {
				return false
			}
		}
		return true
	}); len(n) > 0 {
		addV("drop-all-capabilities", ProfileRestricted, Low, "capabilities not dropped (drop: [ALL])"+in(n))
	}

	// ---- extra ----
	if n := failing(func(c corev1.Container) bool {
		r := sc(c).ReadOnlyRootFilesystem
		return r == nil || !*r
	}); len(n) > 0 {
		addV("read-only-root", ProfileExtra, Low, "writable root filesystem"+in(n))
	}
	return out
}

func worst(vs []Violation) string {
	best := Info
	for _, v := range vs {
		if sevRank[v.Severity] < sevRank[best] {
			best = v.Severity
		}
	}
	return best
}

func (a *analyzer) workloads() {
	for _, u := range a.units {
		vs := EvaluatePodSpec(u.spec, u.meta)
		if len(vs) == 0 {
			continue
		}
		baseline := false
		checks := []string{}
		var baseTexts, restTexts []string
		for _, v := range vs {
			checks = append(checks, fmt.Sprintf("%s: %s", v.Profile, v.Text))
			switch v.Profile {
			case ProfileBaseline:
				baseline = true
				baseTexts = append(baseTexts, v.Text)
			default:
				restTexts = append(restTexts, v.Text)
			}
		}
		sev := worst(vs)
		pods := ""
		if n := u.podCount(); n > 0 && u.ref.Kind != "Pod" {
			pods = fmt.Sprintf(" (%s)", kube.Plural(n, "pod", "pods"))
		}
		var title, detail, check, remediation string
		if baseline {
			check = "workloads.pss-baseline"
			title = fmt.Sprintf("%s%s fails the baseline Pod Security profile", kindLabel(u.ref), pods)
			detail = fmt.Sprintf("Fails %s of the baseline profile", kube.Plural(len(baseTexts), "check", "checks"))
			if len(restTexts) > 0 {
				detail += fmt.Sprintf(" and %s of the restricted profile", kube.Plural(len(restTexts), "more check", "more checks"))
			}
			detail += ". Baseline blocks known privilege escalations; a pod failing it can usually take over its node."
			remediation = "Remove privileged mode, host namespaces, hostPath volumes and added capabilities unless this is a trusted node agent; then work towards the restricted profile."
		} else {
			check = "workloads.pss-restricted"
			title = fmt.Sprintf("%s%s does not meet the restricted Pod Security profile", kindLabel(u.ref), pods)
			detail = fmt.Sprintf("Meets baseline but fails %s of the restricted profile (current pod hardening best practice).", kube.Plural(len(restTexts), "check", "checks"))
			remediation = "Set `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `seccompProfile: {type: RuntimeDefault}`, `capabilities: {drop: [ALL]}` and `readOnlyRootFilesystem: true` in the securityContext."
		}
		a.add(Finding{ID: check + "/" + refKey(u.ref), Check: check, Severity: sev, Category: CatWorkloads, Namespace: u.ref.Namespace,
			Title: title, Detail: detail, Remediation: remediation, Objects: []ObjectRef{u.ref}, Checks: checks})
	}
	a.psa()
}

const psaEnforce = "pod-security.kubernetes.io/enforce"

func (a *analyzer) psaLevel(ns string) string {
	for _, n := range a.in.Namespaces {
		if n.Name == ns {
			return n.Labels[psaEnforce]
		}
	}
	return ""
}

func (a *analyzer) psa() {
	if a.in.Namespaces == nil {
		return
	}
	var none, privileged []ObjectRef
	for _, n := range a.in.Namespaces {
		if !a.inScope(n.Name) || n.Status.Phase == corev1.NamespaceTerminating {
			continue
		}
		ref := ObjectRef{Kind: "Namespace", Name: n.Name}
		switch n.Labels[psaEnforce] {
		case "":
			none = append(none, ref)
		case "privileged":
			privileged = append(privileged, ref)
		}
	}
	sort.Slice(none, func(i, j int) bool { return none[i].Name < none[j].Name })
	if len(none) > 0 {
		a.add(Finding{ID: "workloads.psa-unlabelled", Check: "workloads.psa-unlabelled", Severity: Low, Category: CatWorkloads,
			Title:       fmt.Sprintf("%s %s a Pod Security level", kube.Plural(len(none), "namespace", "namespaces"), verb(len(none), "doesn't enforce", "don't enforce")),
			Detail:      fmt.Sprintf("%s have no `%s` label, so Pod Security admission lets any pod spec in (privileged included, unless another admission controller blocks it).", joinLimit(refNames(none), 6), psaEnforce),
			Remediation: "Label namespaces with `pod-security.kubernetes.io/enforce=baseline` (or `restricted`). Try `warn`/`audit` first to see what would break.",
			Objects:     none})
	}
	if len(privileged) > 0 {
		a.add(Finding{ID: "workloads.psa-privileged", Check: "workloads.psa-privileged", Severity: Info, Category: CatWorkloads,
			Title:       fmt.Sprintf("%s explicitly %s privileged pods", kube.Plural(len(privileged), "namespace", "namespaces"), verb(len(privileged), "allows", "allow")),
			Detail:      fmt.Sprintf("%s enforce the `privileged` Pod Security level. That is expected for node agents and CNI, not for applications.", joinLimit(refNames(privileged), 6)),
			Remediation: "Keep privileged namespaces for infrastructure only.",
			Objects:     privileged})
	}
}
