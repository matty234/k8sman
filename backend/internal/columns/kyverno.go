package columns

// Kyverno policy, cleanup policy and policy report columns (see builtin).

var kyvernoPolicyCols = []Column{
	{Name: "Action", Query: `if .spec.validationFailureAction then .spec.validationFailureAction
else ([.spec.rules[]?.validate.failureAction | select(.)] | unique | join(",")) end`},
	{Name: "Background", Type: "bool", Query: `.spec.background != false`},
	{Name: "Ready", Type: "status", Query: `if .status.ready != null then (if .status.ready then "True" else "False" end)
else (([.status.conditions[]? | select(.type == "Ready") | .status] | first) // "") end`},
	{Name: "Rules", Type: "number", Query: `[.spec.rules[]?] | length`},
	ageCol,
}

var kyvernoCleanupCols = []Column{
	{Name: "Schedule", Query: `.spec.schedule`},
	{Name: "Last Execution", Type: "age", Query: `.status.lastExecutionTime`},
	ageCol,
}

var kyvernoReportCols = []Column{
	{Name: "Pass", Type: "number", Query: `.summary.pass // 0`},
	{Name: "Fail", Type: "number", Query: `.summary.fail // 0`},
	{Name: "Warn", Type: "number", Query: `.summary.warn // 0`},
	{Name: "Error", Type: "number", Query: `.summary.error // 0`},
	{Name: "Skip", Type: "number", Query: `.summary.skip // 0`},
	{Name: "Scope", Query: `if .scope then "\(.scope.kind)/\(.scope.name)" else "" end`},
	ageCol,
}
