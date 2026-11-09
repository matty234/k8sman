package columns

// builtin holds default columns (after Name/Namespace) keyed by Key().
// Queries are plain jq; keep them null-safe (`?`, `//`) since fields are
// frequently absent.
var builtin = map[string][]Column{
	"pods": {
		{Name: "Ready", Type: "ratio", Query: `"\([.status.containerStatuses[]? | select(.ready)] | length)/\(.spec.containers | length)"`},
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
		{Name: "Ready", Type: "ratio", Query: `"\(.status.readyReplicas // 0)/\(.spec.replicas // 0)"`},
		{Name: "Status", Type: "status", Query: deploymentStatus},
		{Name: "Up-to-date", Type: "number", Query: `.status.updatedReplicas // 0`},
		{Name: "Available", Type: "number", Query: `.status.availableReplicas // 0`},
		{Name: "Images", Query: `[.spec.template.spec.containers[].image] | join(", ")`},
		ageCol,
	},
	"statefulsets.apps": {
		{Name: "Ready", Type: "ratio", Query: `"\(.status.readyReplicas // 0)/\(.spec.replicas // 0)"`},
		{Name: "Status", Type: "status", Query: statefulSetStatus},
		{Name: "Service", Query: `.spec.serviceName`},
		{Name: "Images", Query: `[.spec.template.spec.containers[].image] | join(", ")`},
		ageCol,
	},
	"daemonsets.apps": {
		{Name: "Desired", Type: "number", Query: `.status.desiredNumberScheduled // 0`},
		{Name: "Current", Type: "number", Query: `.status.currentNumberScheduled // 0`},
		{Name: "Ready", Type: "number", Query: `.status.numberReady // 0`},
		{Name: "Status", Type: "status", Query: daemonSetStatus},
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
		// Disk usage from Prometheus or the kubelets (see metrics.ClaimUsageDecorator).
		{Name: "Used", Type: "usage", Query: `.k8sman.usage // empty | {raw: .usedBytes, base: .capacityBytes, percent: .percent, basis: "capacity", unit: "bytes"}`},
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
		// The OS image first (so it sorts and filters by it), then the other
		// signals the UI needs to name the OS and platform, tab-separated.
		{Name: "OS", Type: "nodeos", Query: `if (.status.nodeInfo.osImage // .status.nodeInfo.operatingSystem) == null then null else [.status.nodeInfo.osImage, .status.nodeInfo.operatingSystem, .status.nodeInfo.kubeletVersion, .status.nodeInfo.containerRuntimeVersion, .spec.providerID, ([(.metadata.labels // {}) | keys[] | select(test("^(eks\\.amazonaws\\.com|kubernetes\\.azure\\.com|minikube\\.k8s\\.io|node\\.openshift\\.io)/|^cloud\\.google\\.com/gke-"))] | first)] | map(. // "") | join("\t") end`},
		{Name: "Internal-IP", Query: `[.status.addresses[]? | select(.type == "InternalIP") | .address] | first`},
		usageCPU,
		usageMemory,
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
		{Name: "Ready", Type: "ratio", Query: `"\(.status.availableReplicas // 0)/\(.spec.replicas // 1)"`},
		{Name: "Retention", Query: `.spec.retention // "24h"`},
		{Name: "Status", Type: "status", Query: `([.status.conditions[]? | select(.type == "Available")][0] | if . == null then "" elif .status == "True" then "Available" else (.reason // "Unavailable") end)`},
		ageCol,
	},
	"alertmanagers.monitoring.coreos.com": {
		{Name: "Version", Query: `.spec.version // ""`},
		{Name: "Ready", Type: "ratio", Query: `"\(.status.availableReplicas // 0)/\(.spec.replicas // 1)"`},
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
	// Argo Workflows
	"workflows.argoproj.io": {
		{Name: "Status", Type: "status", Query: argoWFPhase},
		{Name: "Progress", Query: `.status.progress // ""`},
		{Name: "Started", Type: "age", Query: `.status.startedAt`},
		{Name: "Duration", Query: `if .status.startedAt then (((.status.finishedAt // (now | todate)) | fromdateiso8601) - (.status.startedAt | fromdateiso8601)) | ` + argoWFDuration + ` else "" end`},
		{Name: "From", Query: `if .spec.workflowTemplateRef then (if .spec.workflowTemplateRef.clusterScope then "cwft/" else "wft/" end) + .spec.workflowTemplateRef.name elif .metadata.labels["workflows.argoproj.io/cron-workflow"] then "cron/" + .metadata.labels["workflows.argoproj.io/cron-workflow"] else "" end`},
		{Name: "Message", Query: `.status.message // ""`},
		ageCol,
	},
	"cronworkflows.argoproj.io": {
		{Name: "Schedule", Query: `((.spec.schedules // []) + (if .spec.schedule then [.spec.schedule] else [] end) | join(", ")) + (if .spec.timezone then " (\(.spec.timezone))" else "" end)`},
		{Name: "Suspended", Type: "bool", Query: `.spec.suspend // false`},
		{Name: "Policy", Query: `.spec.concurrencyPolicy // "Allow"`},
		{Name: "Active", Type: "number", Query: `.status.active // [] | length`},
		{Name: "Last Run", Type: "age", Query: `.status.lastScheduledTime`},
		{Name: "Succeeded", Type: "number", Query: `.status.succeeded // 0`},
		{Name: "Failed", Type: "number", Query: `.status.failed // 0`},
		ageCol,
	},
	"workflowtemplates.argoproj.io":        argoWFTemplateCols,
	"clusterworkflowtemplates.argoproj.io": argoWFTemplateCols,
	"workfloweventbindings.argoproj.io": {
		{Name: "Selector", Query: `.spec.event.selector // ""`},
		{Name: "Submits", Query: `.spec.submit.workflowTemplateRef.name // ""`},
		ageCol,
	},
	// Kyverno. Newer versions keep the action per validate rule.
	"clusterpolicies.kyverno.io": kyvernoPolicyCols,
	"policies.kyverno.io":        kyvernoPolicyCols,
	"policyexceptions.kyverno.io": {
		{Name: "Policies", Query: `[.spec.exceptions[]?.policyName] | join(",")`},
		ageCol,
	},
	"updaterequests.kyverno.io": {
		{Name: "Type", Query: `.spec.requestType`},
		{Name: "Policy", Query: `.spec.policy`},
		{Name: "State", Type: "status", Query: `.status.state`},
		ageCol,
	},
	"cleanuppolicies.kyverno.io":          kyvernoCleanupCols,
	"clustercleanuppolicies.kyverno.io":   kyvernoCleanupCols,
	"policyreports.wgpolicyk8s.io":        kyvernoReportCols,
	"clusterpolicyreports.wgpolicyk8s.io": kyvernoReportCols,
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
	// Dynamic Resource Allocation (resource.k8s.io). Requests read both the
	// v1 shape (requests[].exactly.deviceClassName) and the v1beta1/v1beta2
	// flat one, plus firstAvailable sub-requests.
	"resourceclaims.resource.k8s.io": {
		{Name: "State", Type: "status", Query: `(.status.reservedFor // [] | length) as $n
| if .status.allocation == null then "Pending"
  elif $n > 0 then "Reserved: \($n)"
  else "Allocated" end`},
		{Name: "Device Classes", Query: draClasses(`.spec.devices.requests[]?`)},
		{Name: "Devices", Type: "number", Query: `.status.allocation.devices.results // [] | length`},
		{Name: "Node", Query: `[.status.allocation.nodeSelector.nodeSelectorTerms[]? | (.matchFields[]?, .matchExpressions[]?) | select(.operator == "In") | .values[]?] | unique | join(",")`},
		ageCol,
	},
	"resourceclaimtemplates.resource.k8s.io": {
		{Name: "Device Classes", Query: draClasses(`.spec.spec.devices.requests[]?`)},
		ageCol,
	},
	"deviceclasses.resource.k8s.io": {
		{Name: "Selectors", Query: `[.spec.selectors[]? | .cel.expression // empty] | join(" && ")`},
		ageCol,
	},
	"resourceslices.resource.k8s.io": {
		{Name: "Node", Query: `.spec.nodeName // (if .spec.allNodes then "(all nodes)" elif .spec.nodeSelector then "(selector)" else "" end)`},
		{Name: "Driver", Query: `.spec.driver`},
		{Name: "Pool", Query: `.spec.pool.name`},
		{Name: "Devices", Type: "number", Query: `.spec.devices // [] | length`},
		ageCol,
	},
	"devicetaintrules.resource.k8s.io": {
		{Name: "Driver", Query: `.spec.deviceSelector.driver // ""`},
		{Name: "Taint", Query: `"\(.spec.taint.key // ""):\(.spec.taint.effect // "")"`},
		ageCol,
	},
	// External Secrets Operator (external-secrets.io). v1 and v1beta1 share
	// these fields. Status is the Ready condition's reason (SecretSynced,
	// SecretSyncedError, Valid, InvalidProviderConfig, …).
	"externalsecrets.external-secrets.io": {
		{Name: "Store", Query: `"\(.spec.secretStoreRef.kind // "SecretStore")/\(.spec.secretStoreRef.name // "")"`},
		{Name: "Refresh", Query: `if (.spec.refreshPolicy // "Periodic") != "Periodic" then .spec.refreshPolicy else (.spec.refreshInterval // "1h") end`},
		{Name: "Status", Type: "status", Query: esReadyReason},
		{Name: "Last Sync", Type: "age", Query: `.status.refreshTime`},
		{Name: "Target", Query: `.spec.target.name // .metadata.name`},
		ageCol,
	},
	"clusterexternalsecrets.external-secrets.io": {
		{Name: "External Secret", Query: `.spec.externalSecretName // .metadata.name`},
		{Name: "Namespaces", Type: "number", Query: `.status.provisionedNamespaces // [] | length`},
		{Name: "Failed", Type: "number", Query: `.status.failedNamespaces // [] | length`},
		{Name: "Refresh", Query: `.spec.refreshTime // .spec.externalSecretSpec.refreshInterval // "1h"`},
		{Name: "Status", Type: "status", Query: esReadyReason},
		ageCol,
	},
	"secretstores.external-secrets.io":        esStoreCols,
	"clustersecretstores.external-secrets.io": esStoreCols,
	"pushsecrets.external-secrets.io": {
		{Name: "Stores", Query: `[.spec.secretStoreRefs[]? | "\(.kind // "SecretStore")/\(.name // "(selector)")"] | join(",")`},
		{Name: "Status", Type: "status", Query: esReadyReason},
		{Name: "Last Sync", Type: "age", Query: `.status.refreshTime`},
		ageCol,
	},
	// Admission policies and webhook configurations (admissionregistration.k8s.io).
	"validatingadmissionpolicies.admissionregistration.k8s.io": {
		{Name: "Failure Policy", Query: `.spec.failurePolicy // "Fail"`},
		{Name: "Validations", Type: "number", Query: `.spec.validations // [] | length`},
		{Name: "Matches", Query: admissionMatches},
		{Name: "Param Kind", Query: `.spec.paramKind.kind // ""`},
		ageCol,
	},
	"validatingadmissionpolicybindings.admissionregistration.k8s.io": {
		{Name: "Policy", Query: `.spec.policyName`},
		{Name: "Actions", Query: `[.spec.validationActions[]?] | join(",")`},
		{Name: "Param", Query: admissionParam},
		{Name: "Namespaces", Query: admissionNamespaces},
		ageCol,
	},
	"mutatingadmissionpolicies.admissionregistration.k8s.io": {
		{Name: "Failure Policy", Query: `.spec.failurePolicy // "Fail"`},
		{Name: "Mutations", Type: "number", Query: `.spec.mutations // [] | length`},
		{Name: "Reinvocation", Query: `.spec.reinvocationPolicy // "Never"`},
		{Name: "Matches", Query: admissionMatches},
		{Name: "Param Kind", Query: `.spec.paramKind.kind // ""`},
		ageCol,
	},
	"mutatingadmissionpolicybindings.admissionregistration.k8s.io": {
		{Name: "Policy", Query: `.spec.policyName`},
		{Name: "Param", Query: admissionParam},
		{Name: "Namespaces", Query: admissionNamespaces},
		ageCol,
	},
	"validatingwebhookconfigurations.admissionregistration.k8s.io": {admissionWebhookCount, admissionWebhookTarget, ageCol},
	"mutatingwebhookconfigurations.admissionregistration.k8s.io":   {admissionWebhookCount, admissionWebhookTarget, ageCol},
}

// esReadyReason is an ESO object's Ready condition reason ("Unknown" when
// it has none yet).
const esReadyReason = `([.status.conditions[]? | select(.type == "Ready")][0]) as $c
| if $c == null then "Unknown" else ($c.reason // $c.status) end`

var esStoreCols = []Column{
	{Name: "Provider", Query: `.spec.provider // {} | keys[0] // ""`},
	{Name: "Status", Type: "status", Query: esReadyReason},
	{Name: "Capabilities", Query: `.status.capabilities // ""`},
	ageCol,
}

// Admission column queries.
const (
	admissionMatches = `[.spec.matchConstraints.resourceRules[]? | .resources[]?] | unique | join(",")`
	admissionParam   = `.spec.paramRef | if . == null then "" elif .name then .name elif .selector then "(selector)" else "(all)" end`
	// The binding's namespace selector: matchLabels as k=v, expressions by key.
	admissionNamespaces = `.spec.matchResources.namespaceSelector // {} | [(.matchLabels // {} | to_entries[] | "\(.key)=\(.value)"), (.matchExpressions[]? | "\(.key) \(.operator)")] | join(",")`
)

var (
	admissionWebhookCount  = Column{Name: "Webhooks", Type: "number", Query: `.webhooks // [] | length`}
	admissionWebhookTarget = Column{Name: "First Target", Query: `.webhooks[0]?.clientConfig | if . == null then "" elif .service then "\(.service.namespace)/\(.service.name)" else .url // "" end`}
)

// draClasses lists the distinct device classes of the requests [reqs]
// selects.
func draClasses(reqs string) string {
	return `[` + reqs + ` | (.deviceClassName // .exactly.deviceClassName // .firstAvailable[]?.deviceClassName)] | unique | join(",")`
}

// argoWFPhase is a Workflow's phase, "Suspended" while running but
// suspended (spec.suspend or a waiting suspend step), "Pending" before the
// controller has seen it.
const argoWFPhase = `(.status.phase // "") as $p
	| if $p == "Running" and (.spec.suspend == true or any(.status.nodes[]?; .type == "Suspend" and .phase == "Running")) then "Suspended"
	elif $p == "" then "Pending" else $p end`

// argoWFDuration formats seconds as 45s / 3m20s / 2h05m / 3d4h.
const argoWFDuration = `floor | if . < 60 then "\(.)s"
	elif . < 3600 then "\(. / 60 | floor)m\(. % 60 | tostring | if length < 2 then "0" + . else . end)s"
	elif . < 86400 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor | tostring | if length < 2 then "0" + . else . end)m"
	else "\(. / 86400 | floor)d\((. % 86400) / 3600 | floor)h" end`

var argoWFTemplateCols = []Column{
	{Name: "Entrypoint", Query: `.spec.entrypoint // ""`},
	{Name: "Templates", Type: "number", Query: `.spec.templates // [] | length`},
	{Name: "Parameters", Query: `[.spec.arguments.parameters[]?.name] | join(", ")`},
	ageCol,
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

// Live usage from metrics.k8s.io, merged into pods and nodes as
// `.k8sman.usage` before evaluation (see internal/metrics), as "usage" cells:
// the value (cores or bytes) and, when known, what it's measured against
// (the pod's limit, else its request; the node's allocatable). Empty
// (rendered as "—") when metrics-server isn't installed or has no sample yet.
var (
	usageCPU    = Column{Name: "CPU", Type: "usage", Query: `.k8sman.usage // empty | {raw: (.cpuMillis / 1000), base: .cpuBase, percent: .cpuPercent, basis: .cpuBasis, unit: "cpu"}`}
	usageMemory = Column{Name: "Memory", Type: "usage", Query: `.k8sman.usage // empty | {raw: .memoryBytes, base: .memoryBase, percent: .memoryPercent, basis: .memoryBasis, unit: "bytes"}`}
)

// Workload status words, so a Ready column isn't the only signal: Paused,
// Scaled down, Stalled (progress deadline exceeded), Progressing (a rollout
// is under way), Unavailable (none available), Degraded (some short) or
// Available. The frontend colours them via severityOf.
const deploymentStatus = `(.spec.replicas // 1) as $want | (.status.availableReplicas // 0) as $avail
| if .spec.paused then "Paused"
elif $want == 0 then (if (.status.replicas // 0) > 0 then "Progressing" else "Scaled down" end)
elif any(.status.conditions[]?; .type == "Progressing" and .reason == "ProgressDeadlineExceeded") then "Stalled"
elif (.status.observedGeneration // 0) < (.metadata.generation // 0) or (.status.updatedReplicas // 0) < $want or (.status.replicas // 0) > $want then "Progressing"
elif $avail == 0 then "Unavailable"
elif $avail < $want or (.status.readyReplicas // 0) < $want then "Degraded"
else "Available" end`

const statefulSetStatus = `(.spec.replicas // 1) as $want | (.status.readyReplicas // 0) as $ready
| if $want == 0 then (if (.status.replicas // 0) > 0 then "Progressing" else "Scaled down" end)
elif (.status.observedGeneration // 0) < (.metadata.generation // 0) or (.status.updateRevision != null and .status.currentRevision != .status.updateRevision) or (.status.replicas // 0) != $want then "Progressing"
elif $ready == 0 then "Unavailable"
elif $ready < $want then "Degraded"
else "Available" end`

const daemonSetStatus = `(.status.desiredNumberScheduled // 0) as $want | (.status.numberAvailable // 0) as $avail
| if $want == 0 then "Scaled down"
elif (.status.observedGeneration // 0) < (.metadata.generation // 0) or (.status.updatedNumberScheduled // 0) < $want then "Progressing"
elif $avail == 0 then "Unavailable"
elif $avail < $want then "Degraded"
else "Available" end`
