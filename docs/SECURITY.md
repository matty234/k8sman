# Security overview

The **Security** page (sidebar, under Overview and Nodes) summarises a
cluster's security posture for all namespaces, or the one picked in the page
header (its own scope, independent of the table's namespace). It
is backed by `GET /api/security` (see `API.md`), implemented as a pure analysis
package in `backend/internal/security/` that is unit-tested with constructed
objects, plus a real Trivy Operator report captured from the dev cluster
(`testdata/`).

By default the analysis skips Kubernetes' own parts: the `kube-system`,
`kube-public` and `kube-node-lease` namespaces, and RBAC bindings that are
defaults (a `system:` name, the `kubernetes.io/bootstrapping=rbac-defaults`
label, or subjects that are all `system:` users/groups or kube-system
ServiceAccounts). The **System** toggle (`includeSystem=true`) includes them.

## Severities

| Severity | Meaning |
|---|---|
| critical | Cluster or node takeover is one step away: cluster-admin-equivalent grants, privileged pods, hostPID, sensitive hostPath, SYS_ADMIN |
| high | A serious, directly exploitable weakness: reading all Secrets cluster-wide, a public LoadBalancer in front of unprotected pods, fixable critical CVEs, secrets baked into images |
| medium | Weakens defence in depth: no NetworkPolicy, `:latest` images, Ingress without TLS, namespaced secret-read grants |
| low | Hardening and hygiene: restricted-profile gaps, missing limits/probes, default ServiceAccount tokens |
| info | Worth knowing, not a problem by itself: what Ingresses/Gateways expose, unrestricted egress, unbound roles |

The score is `100 · 100 / (100 + Σ weights)` with weights critical 10,
high 4, medium 1.5, low 0.3 and info 0. It is a rough trend indicator, not a
compliance measure.

## Checks

### Network exposure (`network`)

NetworkPolicy semantics follow the API: an empty `podSelector` selects every
pod in the policy's namespace; `policyTypes` defaults to Ingress (plus Egress
when egress rules exist); a listed type with no rules denies everything in
that direction; a rule with no peers allows everything; and `namespaceSelector`
plus `podSelector` in one peer are AND'ed. Policies are evaluated against each
workload's pod-template labels.

| Check | Severity |
|---|---|
| `network.no-policy`: namespaces with workloads and no NetworkPolicy (all ingress and egress open) | medium, one grouped finding |
| `network.no-default-deny`: namespaces with policies but no default-deny for both directions | low, grouped |
| `network.ingress-unrestricted`: workloads not selected by any ingress-restricting policy, or re-opened by a 0.0.0.0/0 rule (namespaces that have policies) | low, per namespace |
| `network.egress-unrestricted`: same for egress | info, per namespace |
| `network.policy-allows-any-ingress`: a policy allowing ingress from anywhere (`from` omitted or `0.0.0.0/0`/`::/0`) | medium |
| `network.policy-allows-cluster-ingress`: a peer of `namespaceSelector: {}` with no podSelector | low |
| `network.policy-allows-any-egress` | low |
| `network.loadbalancer`: LoadBalancer Services, listing the backing workloads and whether they are NetworkPolicy-protected | high if unprotected and no `loadBalancerSourceRanges`, medium if protected, low with source ranges |
| `network.nodeport` | medium if unprotected, else low |
| `network.externalips` (also CVE-2020-8554) | medium |
| `network.ingress`: each Ingress, its hosts, backends and protection | info |
| `network.gateway`: each Gateway API Gateway, its listeners, attached HTTPRoutes and backends (only when the CRDs exist) | info |
| `network.host-network`: hostNetwork or hostPort (bypasses NetworkPolicy) | medium |

The namespace matrix shows policies, ingress/egress mode (`open`, `partial`,
`restricted`, `default-deny`), exposed entry points and the PSA enforce level.

### RBAC (`rbac`)

Each rule is scored (`RuleRisks` in `rbac.go`); a role's score is its worst
risk plus 15% of the others, capped at 100:

| Risk | Points |
|---|---|
| `*` verbs on `*` resources in `*` groups (cluster-admin equivalent) | 100 |
| `*` verbs on `*` resources in specific groups | 70 |
| `escalate`/`bind` on roles, `impersonate`, `nodes/proxy` | 60 |
| create/update/patch RBAC objects | 50 |
| get/list/watch Secrets, `pods/exec`/`attach`, `serviceaccounts/token` create, CSR approval | 45 |
| register admission webhooks | 40 |
| create pods or workloads (run as any ServiceAccount in the namespace) | 35 |
| `*` verbs on specific resources | 20 |

| Check | Severity |
|---|---|
| `rbac.permissive`: a binding of a role scoring ≥ 30 | ≥ 90: critical cluster-wide / high namespaced; ≥ 45: high / medium; ≥ 30: medium / low |
| `rbac.unused-privileged`: the same, when every subject is a ServiceAccount that no pod or workload template uses | one level higher than `rbac.permissive` |
| `rbac.missing-subject`: binding to ServiceAccounts that don't exist (whoever creates one inherits the grant) | medium if the role scores ≥ 45, else low |
| `rbac.missing-role`: binding to a Role/ClusterRole that doesn't exist | low |
| `rbac.unbound-role`: Roles/ClusterRoles bound by nothing, excluding `system:`, bootstrap and aggregated roles | info |
| `rbac.trivy-assessment`: failing critical/high Trivy RbacAssessmentReport checks, for roles our own scoring doesn't already flag | low |

The **Most permissive grants** table ranks bindings by score, cluster-wide
first, unused first, and marks unused grants.

### Workload hardening (`workloads`)

Every workload's pod template (bare pods use their own spec) is checked
against the Pod Security Standards. One finding per workload lists every
failing check; its severity is the worst check.

| Profile | Check | Severity |
|---|---|---|
| baseline | privileged | critical |
| baseline | hostPID | critical (hostNetwork/hostIPC alone: high) |
| baseline | hostPath volumes | critical for `/`, `/etc`, `/proc`, `/var/lib/kubelet`, `/run`, sockets; else high |
| baseline | added capabilities beyond the baseline set | critical for SYS_ADMIN, ALL, SYS_MODULE, SYS_PTRACE, BPF; else high |
| baseline | hostPort | medium |
| baseline | AppArmor unconfined, seccomp Unconfined, unmasked procMount | high |
| baseline | custom SELinux type/user/role, unsafe sysctls | medium |
| restricted | runAsUser 0 | medium |
| restricted | allowPrivilegeEscalation not false, runAsNonRoot not true, no RuntimeDefault/Localhost seccomp, capabilities not `drop: [ALL]`, disallowed volume types | low |
| extra | writable root filesystem (`readOnlyRootFilesystem`) | low |

Also: `workloads.psa-unlabelled`, namespaces without a
`pod-security.kubernetes.io/enforce` label (low, grouped);
`workloads.psa-privileged`, namespaces enforcing `privileged` (info); and
`workloads.trivy-config-audit`, Trivy ConfigAuditReports with failing
critical checks (medium).

### Best practices (`practices`)

Grouped per namespace so many workloads with the same issue are one row.

| Check | Severity |
|---|---|
| `practices.mutable-image`: `:latest` or untagged images without a digest | medium |
| `practices.ingress-no-tls`: Ingress hosts without a `tls` entry | medium |
| `practices.privileged-nodeport`: node ports below 1024 | medium |
| `practices.no-resources`: containers without a memory limit or requests | low |
| `practices.no-probes`: long-running containers without liveness/readiness probes | low |
| `practices.default-sa-token`: pods on the `default` ServiceAccount with its token automounted | low |
| `practices.secret-env`: Secrets exposed as environment variables | low |
| `practices.default-namespace`: workloads in `default` | low |
| `practices.gateway-no-tls`: Gateway listeners using HTTP/TCP/UDP | low |
| `practices.deprecated-api`: objects last applied (per `kubectl.kubernetes.io/last-applied-configuration`) with a removed API version | low |

### Images (`images`)

| Check | Severity |
|---|---|
| `images.vulnerable`: fixable critical CVEs | high |
| critical CVEs without a fix, or fixable high CVEs | medium |
| high CVEs without a fix | low |
| `images.exposed-secret`: Trivy ExposedSecretReports (credentials baked into the image) | high |

## Inspector Security tab

Pods and pod controllers (Deployment, StatefulSet, DaemonSet, ReplicaSet, Job,
CronJob) have a **Security** tab in the inspector, backed by
`GET /api/security/object` (the same analysis, run over the object's
namespace and sharing its run with the page):

- **Findings** against the object, or for a Pod (or a ReplicaSet/Job with an
  owner) against the controller at the top of its owner chain ("From
  Deployment/web"), with Ignore… and the ignored ones (Un-ignore), as on the
  page. Image-vulnerability findings are left to the next section.
- **Image vulnerabilities** per container: the counts, the top five CVEs
  (fixable first, each with its advisory link) and "Show all"; links to the
  VulnerabilityReport and to the Security page filtered to the workload.
  "Not scanned yet" while the operator hasn't reported on an image; one quiet
  line with Add-ons… without the Trivy Operator.
- **Security context**: the effective pod and per-container settings as a
  table, risky values in the severity colours.
- **Policy results**, when Kyverno is connected (its separate tab is dropped
  for these kinds).

The tab's label counts the open findings plus critical and high CVEs (red
with anything critical, amber for high or medium). The Overview keeps one
insight, only for a critical setting (privileged, hostPID, node-level
capabilities, sensitive host paths), linking to the tab.

## Scanner integration

Two sources, both optional:

1. **Trivy Operator (in-cluster).** If `vulnerabilityreports.aquasecurity.github.io`
   is served, the backend reads VulnerabilityReports, ConfigAuditReports,
   ExposedSecretReports and (Cluster)RbacAssessmentReports. Reports are mapped
   to their workload through the `trivy-operator.resource.*` labels
   (ReplicaSet → Deployment, Pod → owner; names that aren't valid label values
   come from the annotation) and to the container's image string. When
   several reports cover one image, the most recent wins, and CVEs are
   deduplicated by ID and package. The page shows per-image critical/high and
   fixable counts, the top CVEs with fixed versions, and the images with the
   most fixable criticals first. Without the operator, the page offers
   **Install Trivy Operator** (the add-ons hook, `requestAddon`). While it is
   installed but has produced no reports yet, the page says it is scanning and
   re-checks every 20s.
2. **Local `trivy` CLI (on demand).** If `trivy` is on the backend's PATH, each
   image row has a **Scan** button (`POST /api/security/scan`). It runs
   `trivy image --format json --quiet --scanners vuln --timeout 5m0s -- <image>`
   (at most two at once; concurrent requests for one image share a run) and
   caches results for an hour. Image references are validated so they can't
   be read as flags. Without trivy the page shows
   "Install trivy (`brew install trivy`) to scan images on demand". Note that
   the CLI pulls the image from the backend's machine, so private registries
   need local credentials.

### Dev cluster

The kind dev cluster has the Trivy Operator installed (chart
`trivy-operator` 0.38.1, app 0.36.1, release `trivy-operator` in
`trivy-system`, `operator.scanJobsConcurrentLimit=3`), and
`dev/security-demo/insecure.yaml` creates deliberately insecure objects in
`security-demo`: a privileged hostPID/hostNetwork pod with a `/` hostPath and
SYS_ADMIN, a `nginx:latest` Deployment with a Secret in env and no
limits/probes, a LoadBalancer Service, an Ingress without TLS, an allow-all
ingress NetworkPolicy, a ServiceAccount `ci-deployer` with a `*/*/*`
ClusterRoleBinding but no pods, a RoleBinding to a missing Role and missing
ServiceAccount, and an unbound Role. To remove them, see the comments at the
top of that file.

## Limitations

- **Static analysis only.** Effective access also depends on admission
  controllers (Kyverno, Gatekeeper), cloud firewalls and CNI-specific policy
  CRDs (Cilium, Calico GlobalNetworkPolicy), which aren't read.
- NetworkPolicy evaluation is per workload and direction; peers are not
  resolved into a full reachability graph, named ports aren't checked, and a
  `namespaceSelector` that happens to match every namespace isn't detected as
  "cluster-wide".
- RBAC scoring is per binding; it doesn't compute the union of permissions per
  subject across bindings, or follow escalation chains (e.g. create pods →
  mount a more powerful ServiceAccount). Users and groups have unknown usage.
  "Unused" means no current pod or workload template references the
  ServiceAccount; tokens used from outside the cluster are invisible.
- Deprecated API detection only sees objects applied with `kubectl apply`.
- Pods are evaluated by their controller's template; pods that drifted from it
  (e.g. ephemeral debug containers) are only seen for bare pods.
- The Trivy CLI scan runs on the backend host and needs registry access.

## Next steps

- Per-subject effective permissions and escalation paths (reuse
  `effectivePermissions` from the ServiceAccount panel on the backend).
- Kyverno/Gatekeeper and Cilium/Calico policy awareness.
- Show Trivy ConfigAudit/RBAC assessment details inline, and ClusterComplianceReports (CIS, NSA).
- Watch-based incremental updates instead of full re-lists.
- Export findings (CSV/JSON/SARIF) and suppressions (accepted risks).
