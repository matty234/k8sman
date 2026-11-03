package columns

// builtin holds default columns (after Name/Namespace) keyed by Key().
// Queries are plain jq; keep them null-safe (`?`, `//`) since fields are
// frequently absent.
var builtin = map[string][]Column{
	"pods": {
		{Name: "Ready", Query: `"\([.status.containerStatuses[]? | select(.ready)] | length)/\(.spec.containers | length)"`},
		{Name: "Status", Type: "status", Query: `if .metadata.deletionTimestamp then "Terminating"
else ([.status.initContainerStatuses[]? | select(((.state.terminated.exitCode // 0) != 0) or (.state.waiting != null)) | "Init:" + (.state.waiting.reason // .state.terminated.reason // "Error")] | first)
  // ([.status.containerStatuses[]? | .state.waiting.reason // (select(.state.terminated) | .state.terminated.reason) | select(.)] | first)
  // .status.phase end`},
		{Name: "Restarts", Type: "number", Query: `[.status.containerStatuses[]?.restartCount] | add // 0`},
		{Name: "Node", Query: `.spec.nodeName`},
		{Name: "IP", Query: `.status.podIP`},
		ageCol,
	},
	"deployments.apps": {
		{Name: "Ready", Query: `"\(.status.readyReplicas // 0)/\(.spec.replicas // 0)"`},
		{Name: "Up-to-date", Type: "number", Query: `.status.updatedReplicas // 0`},
		{Name: "Available", Type: "number", Query: `.status.availableReplicas // 0`},
		{Name: "Images", Query: `[.spec.template.spec.containers[].image] | join(", ")`},
		ageCol,
	},
	"statefulsets.apps": {
		{Name: "Ready", Query: `"\(.status.readyReplicas // 0)/\(.spec.replicas // 0)"`},
		{Name: "Service", Query: `.spec.serviceName`},
		{Name: "Images", Query: `[.spec.template.spec.containers[].image] | join(", ")`},
		ageCol,
	},
	"daemonsets.apps": {
		{Name: "Desired", Type: "number", Query: `.status.desiredNumberScheduled // 0`},
		{Name: "Current", Type: "number", Query: `.status.currentNumberScheduled // 0`},
		{Name: "Ready", Type: "number", Query: `.status.numberReady // 0`},
		{Name: "Up-to-date", Type: "number", Query: `.status.updatedNumberScheduled // 0`},
		{Name: "Available", Type: "number", Query: `.status.numberAvailable // 0`},
		{Name: "Node Selector", Query: `(.spec.template.spec.nodeSelector // {}) | to_entries | map("\(.key)=\(.value)") | join(",")`},
		ageCol,
	},
	"replicasets.apps": {
		{Name: "Desired", Type: "number", Query: `.spec.replicas // 0`},
		{Name: "Current", Type: "number", Query: `.status.replicas // 0`},
		{Name: "Ready", Type: "number", Query: `.status.readyReplicas // 0`},
		{Name: "Owner", Query: `[.metadata.ownerReferences[]? | "\(.kind)/\(.name)"] | join(",")`},
		ageCol,
	},
	"jobs.batch": {
		{Name: "Status", Type: "status", Query: `([.status.conditions[]? | select(.status == "True") | .type] | last) // (if (.status.active // 0) > 0 then "Running" else "Pending" end)`},
		{Name: "Completions", Query: `"\(.status.succeeded // 0)/\(.spec.completions // 1)"`},
		{Name: "Duration", Query: `if .status.startTime then (((.status.completionTime // (now | todate)) | fromdate) - (.status.startTime | fromdate) | tostring + "s") else "" end`},
		ageCol,
	},
	"cronjobs.batch": {
		{Name: "Schedule", Query: `.spec.schedule`},
		{Name: "Suspend", Type: "bool", Query: `.spec.suspend // false`},
		{Name: "Active", Type: "number", Query: `.status.active // [] | length`},
		{Name: "Last Schedule", Type: "age", Query: `.status.lastScheduleTime`},
		ageCol,
	},
	"services": {
		{Name: "Type", Query: `.spec.type`},
		{Name: "Cluster-IP", Query: `.spec.clusterIP`},
		{Name: "External-IP", Query: `([.status.loadBalancer.ingress[]? | .ip // .hostname] + (.spec.externalIPs // [])) | join(",")`},
		{Name: "Ports", Query: `[.spec.ports[]? | "\(.port)\(if .nodePort then ":\(.nodePort)" else "" end)/\(.protocol // "TCP")"] | join(",")`},
		{Name: "Selector", Query: `(.spec.selector // {}) | to_entries | map("\(.key)=\(.value)") | join(",")`},
		ageCol,
	},
	"ingresses.networking.k8s.io": {
		{Name: "Class", Query: `.spec.ingressClassName // .metadata.annotations["kubernetes.io/ingress.class"]`},
		{Name: "Hosts", Query: `[.spec.rules[]?.host // "*"] | join(",")`},
		{Name: "Address", Query: `[.status.loadBalancer.ingress[]? | .ip // .hostname] | join(",")`},
		{Name: "Ports", Query: `if (.spec.tls // []) | length > 0 then "80, 443" else "80" end`},
		ageCol,
	},
	"endpointslices.discovery.k8s.io": {
		{Name: "Address Type", Query: `.addressType`},
		{Name: "Ports", Query: `[.ports[]? | .port] | map(tostring) | join(",")`},
		{Name: "Endpoints", Query: `[.endpoints[]?.addresses[]] | join(",")`},
		ageCol,
	},
	"networkpolicies.networking.k8s.io": {
		{Name: "Pod Selector", Query: `(.spec.podSelector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(",") | if . == "" then "<all>" else . end`},
		{Name: "Policy Types", Query: `.spec.policyTypes // [] | join(",")`},
		ageCol,
	},
	"configmaps": {
		{Name: "Data", Type: "number", Query: `((.data // {}) | length) + ((.binaryData // {}) | length)`},
		ageCol,
	},
	"secrets": {
		{Name: "Type", Query: `.type`},
		{Name: "Data", Type: "number", Query: `(.data // {}) | length`},
		ageCol,
	},
	"serviceaccounts": {
		{Name: "Secrets", Type: "number", Query: `.secrets // [] | length`},
		ageCol,
	},
	"persistentvolumeclaims": {
		{Name: "Status", Type: "status", Query: `.status.phase`},
		{Name: "Volume", Query: `.spec.volumeName`},
		{Name: "Capacity", Query: `.status.capacity.storage`},
		{Name: "Access Modes", Query: `.spec.accessModes // [] | join(",")`},
		{Name: "StorageClass", Query: `.spec.storageClassName`},
		ageCol,
	},
	"persistentvolumes": {
		{Name: "Capacity", Query: `.spec.capacity.storage`},
		{Name: "Access Modes", Query: `.spec.accessModes // [] | join(",")`},
		{Name: "Reclaim Policy", Query: `.spec.persistentVolumeReclaimPolicy`},
		{Name: "Status", Type: "status", Query: `.status.phase`},
		{Name: "Claim", Query: `if .spec.claimRef then "\(.spec.claimRef.namespace)/\(.spec.claimRef.name)" else "" end`},
		{Name: "StorageClass", Query: `.spec.storageClassName`},
		ageCol,
	},
	"storageclasses.storage.k8s.io": {
		{Name: "Provisioner", Query: `.provisioner`},
		{Name: "Reclaim Policy", Query: `.reclaimPolicy // "Delete"`},
		{Name: "Binding Mode", Query: `.volumeBindingMode // "Immediate"`},
		{Name: "Default", Type: "bool", Query: `.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"`},
		ageCol,
	},
	"nodes": {
		{Name: "Status", Type: "status", Query: `([.status.conditions[]? | select(.type == "Ready") | if .status == "True" then "Ready" else "NotReady" end] | first // "Unknown") + (if .spec.unschedulable then ",SchedulingDisabled" else "" end)`},
		{Name: "Roles", Query: `[(.metadata.labels // {}) | keys[] | select(startswith("node-role.kubernetes.io/")) | ltrimstr("node-role.kubernetes.io/")] | join(",")`},
		{Name: "Version", Query: `.status.nodeInfo.kubeletVersion`},
		{Name: "Internal-IP", Query: `[.status.addresses[]? | select(.type == "InternalIP") | .address] | first`},
		{Name: "CPU", Query: `.status.allocatable.cpu`},
		{Name: "Memory", Query: `.status.allocatable.memory`},
		ageCol,
	},
	"namespaces": {
		{Name: "Status", Type: "status", Query: `.status.phase`},
		ageCol,
	},
	"events": {
		{Name: "Type", Type: "status", Query: `.type`},
		{Name: "Reason", Query: `.reason`},
		{Name: "Object", Query: `"\(.involvedObject.kind)/\(.involvedObject.name)"`},
		{Name: "Message", Query: `.message`},
		{Name: "Count", Type: "number", Query: `.count // 1`},
		{Name: "Last Seen", Type: "age", Query: `.lastTimestamp // .eventTime // .metadata.creationTimestamp`},
	},
	"events.events.k8s.io": {
		{Name: "Type", Type: "status", Query: `.type`},
		{Name: "Reason", Query: `.reason`},
		{Name: "Object", Query: `"\(.regarding.kind)/\(.regarding.name)"`},
		{Name: "Message", Query: `.note`},
		{Name: "Count", Type: "number", Query: `.series.count // .deprecatedCount // 1`},
		{Name: "Last Seen", Type: "age", Query: `.series.lastObservedTime // .deprecatedLastTimestamp // .eventTime // .metadata.creationTimestamp`},
	},
	"customresourcedefinitions.apiextensions.k8s.io": {
		{Name: "Group", Query: `.spec.group`},
		{Name: "Kind", Query: `.spec.names.kind`},
		{Name: "Scope", Query: `.spec.scope`},
		{Name: "Versions", Query: `[.spec.versions[] | .name + (if .storage then "*" else "" end)] | join(",")`},
		ageCol,
	},
	"roles.rbac.authorization.k8s.io":               {{Name: "Rules", Type: "number", Query: `.rules // [] | length`}, ageCol},
	"clusterroles.rbac.authorization.k8s.io":        {{Name: "Rules", Type: "number", Query: `.rules // [] | length`}, ageCol},
	"rolebindings.rbac.authorization.k8s.io":        {{Name: "Role", Query: `"\(.roleRef.kind)/\(.roleRef.name)"`}, {Name: "Subjects", Query: `[.subjects[]? | "\(.kind)/\(.name)"] | join(",")`}, ageCol},
	"clusterrolebindings.rbac.authorization.k8s.io": {{Name: "Role", Query: `"\(.roleRef.kind)/\(.roleRef.name)"`}, {Name: "Subjects", Query: `[.subjects[]? | "\(.kind)/\(.name)"] | join(",")`}, ageCol},
	// Prometheus Operator (monitoring.coreos.com)
	"prometheusrules.monitoring.coreos.com": {
		{Name: "Groups", Type: "number", Query: `.spec.groups // [] | length`},
		{Name: "Alerts", Type: "number", Query: `[.spec.groups[]?.rules[]? | select(.alert)] | length`},
		{Name: "Records", Type: "number", Query: `[.spec.groups[]?.rules[]? | select(.record)] | length`},
		ageCol,
	},
	"servicemonitors.monitoring.coreos.com": {
		{Name: "Selector", Query: `(.spec.selector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")`},
		{Name: "Namespaces", Query: `if .spec.namespaceSelector.any then "any" else ((.spec.namespaceSelector.matchNames // []) | join(",")) end`},
		{Name: "Endpoints", Query: `[.spec.endpoints[]? | (.port // .targetPort // "?" | tostring) + (.path // "")] | join(", ")`},
		{Name: "Interval", Query: `[.spec.endpoints[]?.interval | select(.)] | unique | join(",")`},
		ageCol,
	},
	"podmonitors.monitoring.coreos.com": {
		{Name: "Selector", Query: `(.spec.selector.matchLabels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")`},
		{Name: "Namespaces", Query: `if .spec.namespaceSelector.any then "any" else ((.spec.namespaceSelector.matchNames // []) | join(",")) end`},
		{Name: "Endpoints", Query: `[.spec.podMetricsEndpoints[]? | (.port // .targetPort // .portNumber // "?" | tostring) + (.path // "")] | join(", ")`},
		{Name: "Interval", Query: `[.spec.podMetricsEndpoints[]?.interval | select(.)] | unique | join(",")`},
		ageCol,
	},
	"prometheuses.monitoring.coreos.com": {
		{Name: "Version", Query: `.spec.version // ""`},
		{Name: "Ready", Query: `"\(.status.availableReplicas // 0)/\(.spec.replicas // 1)"`},
		{Name: "Retention", Query: `.spec.retention // "24h"`},
		{Name: "Status", Type: "status", Query: `([.status.conditions[]? | select(.type == "Available")][0] | if . == null then "" elif .status == "True" then "Available" else (.reason // "Unavailable") end)`},
		ageCol,
	},
	"alertmanagers.monitoring.coreos.com": {
		{Name: "Version", Query: `.spec.version // ""`},
		{Name: "Ready", Query: `"\(.status.availableReplicas // 0)/\(.spec.replicas // 1)"`},
		{Name: "Retention", Query: `.spec.retention // "120h"`},
		{Name: "Status", Type: "status", Query: `([.status.conditions[]? | select(.type == "Available")][0] | if . == null then "" elif .status == "True" then "Available" else (.reason // "Unavailable") end)`},
		ageCol,
	},
	"horizontalpodautoscalers.autoscaling": {
		{Name: "Reference", Query: `"\(.spec.scaleTargetRef.kind)/\(.spec.scaleTargetRef.name)"`},
		{Name: "Min", Type: "number", Query: `.spec.minReplicas // 1`},
		{Name: "Max", Type: "number", Query: `.spec.maxReplicas`},
		{Name: "Replicas", Type: "number", Query: `.status.currentReplicas // 0`},
		ageCol,
	},
	// Argo CD
	"applications.argoproj.io": {
		{Name: "Sync", Type: "status", Query: `.status.sync.status // "Unknown"`},
		{Name: "Health", Type: "status", Query: `.status.health.status // "Unknown"`},
		{Name: "Revision", Query: `(.status.sync.revision // (.status.sync.revisions // [] | map(.[0:7]) | join(",")) // "") | .[0:7]`},
		{Name: "Repo", Query: argoShortRepo},
		{Name: "Path/Chart", Query: `[(.spec.source // empty), (.spec.sources[]? | select(.ref == null))] | map(.path // .chart // "") | map(select(. != "")) | join(", ")`},
		{Name: "Destination", Query: `"\((.spec.destination.name // .spec.destination.server // "") | if . == "https://kubernetes.default.svc" then "in-cluster" else . end)/\(.spec.destination.namespace // "")"`},
		{Name: "Project", Query: `.spec.project // "default"`},
		ageCol,
	},
	"applicationsets.argoproj.io": {
		{Name: "Generators", Query: `[.spec.generators[]? | ` + argoGenerator + `] | join(", ")`},
		{Name: "Apps", Type: "number", Query: `.status.resourcesCount // (.status.resources // [] | length)`},
		{Name: "Status", Type: "status", Query: `if any(.status.conditions[]?; .type == "ErrorOccurred" and .status == "True") then "Error" elif any(.status.conditions[]?; .type == "ResourcesUpToDate" and .status == "True") then "UpToDate" else (.status.health.status // "") end`},
		ageCol,
	},
	"appprojects.argoproj.io": {
		{Name: "Destinations", Query: `[.spec.destinations[]? | "\((.name // .server // "*") | if . == "https://kubernetes.default.svc" then "in-cluster" else . end)/\(.namespace // "*")"] | join(", ")`},
		{Name: "Sources", Query: `.spec.sourceRepos // [] | join(", ")`},
		{Name: "Description", Query: `.spec.description // ""`},
		ageCol,
	},
	// Gateway API. Status cells read "True", "False: <reason>",
	// "Unknown: <reason>" or "Warning: <detail>" so they colour correctly.
	"gatewayclasses.gateway.networking.k8s.io": {
		{Name: "Controller", Query: `.spec.controllerName`},
		{Name: "Accepted", Type: "status", Query: gwCondStatus("Accepted")},
		ageCol,
	},
	"gateways.gateway.networking.k8s.io": {
		{Name: "Class", Query: `.spec.gatewayClassName`},
		{Name: "Addresses", Query: `[.status.addresses[]?.value] | join(",")`},
		{Name: "Listeners", Query: `[.spec.listeners[]? | "\(.port)/\(.protocol)"] | join(",")`},
		{Name: "Programmed", Type: "status", Query: gwCondStatus("Programmed")},
		ageCol,
	},
	"referencegrants.gateway.networking.k8s.io": {
		{Name: "From", Query: `[.spec.from[]? | "\(.kind) in \(.namespace)"] | join(",")`},
		{Name: "To", Query: `[.spec.to[]? | .kind + (if .name then "/\(.name)" else "" end)] | join(",")`},
		ageCol,
	},
	"httproutes.gateway.networking.k8s.io": {gwRouteHostnames, gwRouteParents, gwRouteAccepted, gwRouteBackends, ageCol},
	"grpcroutes.gateway.networking.k8s.io": {gwRouteHostnames, gwRouteParents, gwRouteAccepted, gwRouteBackends, ageCol},
	"tlsroutes.gateway.networking.k8s.io":  {gwRouteHostnames, gwRouteParents, gwRouteAccepted, gwRouteBackends, ageCol},
	"tcproutes.gateway.networking.k8s.io":  {gwRouteParents, gwRouteAccepted, gwRouteBackends, ageCol},
	"udproutes.gateway.networking.k8s.io":  {gwRouteParents, gwRouteAccepted, gwRouteBackends, ageCol},
}

// argoShortRepo shortens a repo URL to its last two path segments
// (`https://github.com/argoproj/argocd-example-apps.git` → `argoproj/argocd-example-apps`).
const argoShortRepo = `(.spec.source.repoURL // ([.spec.sources[]? | select(.ref == null)][0].repoURL) // .spec.sources[0]?.repoURL // "")
  | sub("\\.git$"; "") | sub("/+$"; "") | split("/") | if length > 3 then .[-2:] | join("/") else join("/") end`

// argoGenerator names one ApplicationSet generator; matrix/merge list their children.
const argoGenerator = `(to_entries | map(select(.key != "selector")) | first // {key: "?"}) as $g
  | if ($g.key == "matrix" or $g.key == "merge") then "\($g.key)(\([$g.value.generators[]? | to_entries | map(select(.key != "selector")) | first.key] | join("+")))" else $g.key end`

// gwCondStatus renders one .status.conditions entry of a Gateway API object.
func gwCondStatus(t string) string {
	return `([.status.conditions[]? | select(.type == "` + t + `")][0]) as $c
| if $c == null then "Unknown"
  elif $c.status == "True" then "True"
  else "\($c.status): \($c.reason // "")" end`
}

const gwNsPrefix = `(if .namespace then "\(.namespace)/" else "" end)`

var (
	gwRouteHostnames = Column{Name: "Hostnames", Query: `.spec.hostnames // [] | join(",")`}
	gwRouteParents   = Column{Name: "Parents", Query: `[.spec.parentRefs[]? | ` + gwNsPrefix + ` + .name + (if .sectionName then ":\(.sectionName)" else "" end)] | join(",")`}
	gwRouteBackends  = Column{Name: "Backends", Query: `[.spec.rules[]?.backendRefs[]? | ` + gwNsPrefix + ` + .name + (if .port then ":\(.port)" else "" end)] | unique | join(",")`}
	// Accepted aggregated over status.parents; unresolved refs downgrade a
	// fully accepted route to a warning.
	gwRouteAccepted = Column{Name: "Accepted", Type: "status", Query: `[.status.parents[]? | ([.conditions[]? | select(.type == "Accepted")][0])] as $a
| [.status.parents[]? | ([.conditions[]? | select(.type == "ResolvedRefs" and .status == "False")][0]) | select(. != null)] as $u
| ([$a[] | select(.status == "True")] | length) as $ok
| ([$a[] | select(.status != "True")] | first) as $bad
| if ($a | length) == 0 then "Unknown: no status"
  elif $ok == 0 then "False: \($bad.reason // "NotAccepted")"
  elif $ok < ($a | length) then "Warning: \($ok)/\($a | length) accepted (\($bad.reason // "NotAccepted"))"
  elif ($u | length) > 0 then "Warning: \($u[0].reason // "unresolved refs")"
  else "True" end`}
)
