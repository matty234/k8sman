package security

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/matty234/k8sman/backend/internal/kube"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ImageTag splits an image reference into repository, tag and digest.
// "nginx" → ("nginx", "", ""); "reg:5000/a/b:1.2@sha256:…" → ("reg:5000/a/b", "1.2", "sha256:…").
func ImageTag(image string) (repo, tag, digest string) {
	repo = image
	if i := strings.Index(repo, "@"); i >= 0 {
		repo, digest = repo[:i], repo[i+1:]
	}
	slash := strings.LastIndex(repo, "/")
	if i := strings.LastIndex(repo, ":"); i > slash {
		repo, tag = repo[:i], repo[i+1:]
	}
	return
}

// MutableImage reports whether an image floats: `:latest` or no tag, and no digest.
func MutableImage(image string) bool {
	_, tag, digest := ImageTag(image)
	return digest == "" && (tag == "" || tag == "latest")
}

type practiceHit struct {
	u    *unit
	note string
}

// groupPractice emits one finding per namespace for a check, listing the
// workloads (so 40 workloads without limits are one row per namespace).
func (a *analyzer) groupPractice(check, sev, whatOne, whatMany, detail, remediation string, hits []practiceHit) {
	byNS := map[string][]practiceHit{}
	for _, h := range hits {
		byNS[h.u.ref.Namespace] = append(byNS[h.u.ref.Namespace], h)
	}
	nss := make([]string, 0, len(byNS))
	for ns := range byNS {
		nss = append(nss, ns)
	}
	sort.Strings(nss)
	for _, ns := range nss {
		hs := byNS[ns]
		objs := []ObjectRef{}
		notes := []string{}
		for _, h := range hs {
			objs = append(objs, h.u.ref)
			n := kindLabel(h.u.ref)
			if h.note != "" {
				n += " (" + h.note + ")"
			}
			notes = append(notes, n)
		}
		a.add(Finding{ID: check + "/" + ns, Check: check, Severity: sev, Category: CatPractices, Namespace: ns,
			Title:       fmt.Sprintf("%s in %s %s", kube.Plural(len(hs), "workload", "workloads"), ns, map[bool]string{true: whatOne, false: whatMany}[len(hs) == 1]),
			Detail:      detail + " Affected: " + joinLimit(notes, 6) + ".",
			Remediation: remediation,
			Objects:     objs})
	}
}

func (a *analyzer) defaultSAAutomounts(ns string) bool {
	for _, sa := range a.in.ServiceAccounts {
		if sa.Namespace == ns && sa.Name == "default" {
			return sa.AutomountServiceAccountToken == nil || *sa.AutomountServiceAccountToken
		}
	}
	return true
}

func (a *analyzer) practices() {
	var latest, noResources, noProbes, defaultSA, secretEnv, defaultNS []practiceHit
	for _, u := range a.units {
		var imgs, noRes, noProbe, envSecrets []string
		for _, c := range u.spec.Containers {
			if MutableImage(c.Image) {
				imgs = append(imgs, c.Image)
			}
			missing := []string{}
			if c.Resources.Limits.Memory().IsZero() {
				missing = append(missing, "memory limit")
			}
			if c.Resources.Requests.Cpu().IsZero() && c.Resources.Requests.Memory().IsZero() {
				missing = append(missing, "requests")
			}
			if len(missing) > 0 {
				noRes = append(noRes, c.Name+": "+strings.Join(missing, ", "))
			}
			if c.ReadinessProbe == nil && c.LivenessProbe == nil {
				noProbe = append(noProbe, c.Name)
			}
			for _, e := range c.Env {
				if e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil {
					envSecrets = append(envSecrets, e.Name)
				}
			}
			for _, e := range c.EnvFrom {
				if e.SecretRef != nil {
					envSecrets = append(envSecrets, "envFrom "+e.SecretRef.Name)
				}
			}
		}
		for _, c := range u.spec.InitContainers {
			if MutableImage(c.Image) {
				imgs = append(imgs, c.Image)
			}
		}
		if len(imgs) > 0 {
			latest = append(latest, practiceHit{u, strings.Join(uniqSorted(imgs), ", ")})
		}
		if len(noRes) > 0 {
			noResources = append(noResources, practiceHit{u, strings.Join(noRes, "; ")})
		}
		if len(noProbe) > 0 && !u.isJob && u.ref.Kind != "Pod" {
			noProbes = append(noProbes, practiceHit{u, strings.Join(noProbe, ", ")})
		}
		sa := u.spec.ServiceAccountName
		if (sa == "" || sa == "default") && (u.spec.AutomountServiceAccountToken == nil || *u.spec.AutomountServiceAccountToken) && a.defaultSAAutomounts(u.ref.Namespace) {
			defaultSA = append(defaultSA, practiceHit{u, ""})
		}
		if len(envSecrets) > 0 {
			secretEnv = append(secretEnv, practiceHit{u, strings.Join(envSecrets, ", ")})
		}
		if u.ref.Namespace == "default" {
			defaultNS = append(defaultNS, practiceHit{u, ""})
		}
	}
	a.groupPractice("practices.mutable-image", Medium, "uses :latest or untagged images", "use :latest or untagged images",
		"Floating tags make deployments unreproducible and can silently pull a different (possibly compromised) image on the next restart.",
		"Pin images to a version tag, ideally with a digest (`image@sha256:…`).", latest)
	a.groupPractice("practices.no-resources", Low, "has containers without resource limits or requests", "have containers without resource limits or requests",
		"Without a memory limit one container can exhaust the node (a noisy-neighbour or denial-of-service risk); without requests the scheduler can't place it sensibly.",
		"Set `resources.requests` for CPU and memory and a memory limit; a LimitRange can provide namespace defaults.", noResources)
	a.groupPractice("practices.no-probes", Low, "has containers without liveness or readiness probes", "have containers without liveness or readiness probes",
		"Without probes, Kubernetes sends traffic to containers that aren't ready and never restarts hung ones.",
		"Add a readinessProbe (and a livenessProbe for processes that can hang).", noProbes)
	a.groupPractice("practices.default-sa-token", Low, "mounts the default ServiceAccount token", "mount the default ServiceAccount token",
		"These pods run as the namespace's `default` ServiceAccount with its API token mounted. Any permissions granted to `default` are shared by every such pod, and a compromised container gets an API credential for free.",
		"Set `automountServiceAccountToken: false` on the pod (or the default ServiceAccount), or use a dedicated ServiceAccount.", defaultSA)
	a.groupPractice("practices.secret-env", Low, "exposes Secrets as environment variables", "expose Secrets as environment variables",
		"Environment variables leak into crash dumps, `/proc/<pid>/environ`, child processes and logs more easily than mounted files.",
		"Mount Secrets as files (a `secret` volume) instead of env vars.", secretEnv)
	a.groupPractice("practices.default-namespace", Low, "runs in the default namespace", "run in the default namespace",
		"The `default` namespace is shared by convention, so RBAC, quotas and NetworkPolicies there tend to be loose.",
		"Move applications into their own namespaces.", defaultNS)
	a.deprecatedAPIs()
}

// removedAPIs maps apiVersion (or apiVersion/Kind) to the Kubernetes
// version that removed it.
var removedAPIs = map[string]string{
	"extensions/v1beta1":                     "1.16/1.22",
	"apps/v1beta1":                           "1.16",
	"apps/v1beta2":                           "1.16",
	"networking.k8s.io/v1beta1":              "1.22",
	"rbac.authorization.k8s.io/v1beta1":      "1.22",
	"rbac.authorization.k8s.io/v1alpha1":     "1.22",
	"batch/v1beta1":                          "1.25",
	"batch/v2alpha1":                         "1.21",
	"policy/v1beta1":                         "1.25",
	"autoscaling/v2beta1":                    "1.25",
	"autoscaling/v2beta2":                    "1.26",
	"discovery.k8s.io/v1beta1":               "1.25",
	"admissionregistration.k8s.io/v1beta1":   "1.22",
	"apiextensions.k8s.io/v1beta1":           "1.22",
	"scheduling.k8s.io/v1beta1":              "1.22",
	"storage.k8s.io/v1beta1":                 "1.22/1.27",
	"flowcontrol.apiserver.k8s.io/v1beta1":   "1.26",
	"flowcontrol.apiserver.k8s.io/v1beta2":   "1.29",
	"flowcontrol.apiserver.k8s.io/v1beta3":   "1.32",
	"certificates.k8s.io/v1beta1":            "1.22",
	"coordination.k8s.io/v1beta1":            "1.22",
	"networking.k8s.io/v1beta1/IngressClass": "1.22",
	"node.k8s.io/v1beta1":                    "1.25",
	"events.k8s.io/v1beta1":                  "1.25",
}

// DeprecatedAPIVersion reads the apiVersion the object was last applied
// with (kubectl's last-applied annotation) and returns it with the
// release that removed it, if that version is gone or going.
func DeprecatedAPIVersion(m metav1.ObjectMeta) (apiVersion, removedIn string) {
	raw := m.Annotations[corev1.LastAppliedConfigAnnotation]
	if raw == "" {
		return "", ""
	}
	var tm metav1.TypeMeta
	if json.Unmarshal([]byte(raw), &tm) != nil {
		return "", ""
	}
	if r, ok := removedAPIs[tm.APIVersion+"/"+tm.Kind]; ok {
		return tm.APIVersion, r
	}
	if r, ok := removedAPIs[tm.APIVersion]; ok {
		return tm.APIVersion, r
	}
	return "", ""
}

func (a *analyzer) deprecatedAPIs() {
	type obj struct {
		ref  ObjectRef
		meta metav1.ObjectMeta
	}
	var objs []obj
	addObj := func(group, kind string, m metav1.ObjectMeta) {
		if m.Namespace == "" || a.inScope(m.Namespace) {
			objs = append(objs, obj{ObjectRef{Group: group, Kind: kind, Name: m.Name, Namespace: m.Namespace}, m})
		}
	}
	for _, d := range a.in.Deployments {
		addObj("apps", "Deployment", d.ObjectMeta)
	}
	for _, d := range a.in.StatefulSets {
		addObj("apps", "StatefulSet", d.ObjectMeta)
	}
	for _, d := range a.in.DaemonSets {
		addObj("apps", "DaemonSet", d.ObjectMeta)
	}
	for _, c := range a.in.CronJobs {
		addObj("batch", "CronJob", c.ObjectMeta)
	}
	for _, i := range a.in.Ingresses {
		addObj("networking.k8s.io", "Ingress", i.ObjectMeta)
	}
	for _, n := range a.in.NetworkPolicies {
		addObj("networking.k8s.io", "NetworkPolicy", n.ObjectMeta)
	}
	for _, r := range a.in.Roles {
		addObj("rbac.authorization.k8s.io", "Role", r.ObjectMeta)
	}
	for _, r := range a.in.RoleBindings {
		addObj("rbac.authorization.k8s.io", "RoleBinding", r.ObjectMeta)
	}
	if a.in.Namespace == "" {
		for _, r := range a.in.ClusterRoles {
			addObj("rbac.authorization.k8s.io", "ClusterRole", r.ObjectMeta)
		}
		for _, r := range a.in.ClusterRoleBindings {
			addObj("rbac.authorization.k8s.io", "ClusterRoleBinding", r.ObjectMeta)
		}
	}
	var refs []ObjectRef
	var notes []string
	for _, o := range objs {
		if v, removed := DeprecatedAPIVersion(o.meta); v != "" {
			refs = append(refs, o.ref)
			notes = append(notes, fmt.Sprintf("%s (%s, removed in %s)", kindLabel(o.ref), v, removed))
		}
	}
	if len(refs) == 0 {
		return
	}
	a.add(Finding{ID: "practices.deprecated-api", Check: "practices.deprecated-api", Severity: Low, Category: CatPractices, Namespace: a.in.Namespace,
		Title:       fmt.Sprintf("%s %s last applied with removed API versions", kube.Plural(len(refs), "object", "objects"), verb(len(refs), "was", "were")),
		Detail:      fmt.Sprintf("Their `kubectl apply` manifests use API versions that newer Kubernetes releases no longer serve, so re-applying them will fail after an upgrade: %s. (Detected from the last-applied-configuration annotation only.)", joinLimit(notes, 6)),
		Remediation: "Update the source manifests or charts to the current API versions (e.g. with `kubectl convert` or `pluto`).",
		Objects:     refs})
}
