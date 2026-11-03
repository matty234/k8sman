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
		usageCPU,
		usageMemory,
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
		usageCPU,
		{Name: "CPU%", Type: "quantity", Query: `.k8sman.usage.cpuPercent // empty | tostring + "%"`},
		usageMemory,
		{Name: "Mem%", Type: "quantity", Query: `.k8sman.usage.memoryPercent // empty | tostring + "%"`},
		{Name: "Alloc CPU", Type: "quantity", Query: `.status.allocatable.cpu`},
		{Name: "Alloc Memory", Type: "quantity", Query: `.status.allocatable.memory | if test("Ki$") then (rtrimstr("Ki") | tonumber / 1024 | round | tostring) + "Mi" else . end`},
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
	"horizontalpodautoscalers.autoscaling": {
		{Name: "Reference", Query: `"\(.spec.scaleTargetRef.kind)/\(.spec.scaleTargetRef.name)"`},
		{Name: "Min", Type: "number", Query: `.spec.minReplicas // 1`},
		{Name: "Max", Type: "number", Query: `.spec.maxReplicas`},
		{Name: "Replicas", Type: "number", Query: `.status.currentReplicas // 0`},
		ageCol,
	},
}

// Live usage from metrics.k8s.io, merged into pods and nodes as
// `.k8sman.usage` before evaluation (see internal/metrics). Empty (rendered
// as "—") when metrics-server isn't installed or has no sample yet.
var (
	usageCPU    = Column{Name: "CPU", Type: "quantity", Query: `.k8sman.usage.cpu`}
	usageMemory = Column{Name: "Memory", Type: "quantity", Query: `.k8sman.usage.memoryBytes // empty | (. / 1048576 | round | tostring) + "Mi"`}
)
