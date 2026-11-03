package security

import (
	"fmt"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// CVE is one vulnerability, summarised.
type CVE struct {
	ID        string   `json:"id"`
	Severity  string   `json:"severity"` // critical|high|medium|low|unknown
	Package   string   `json:"package"`
	Installed string   `json:"installed"`
	Fixed     string   `json:"fixed,omitempty"`
	Title     string   `json:"title,omitempty"`
	Link      string   `json:"link,omitempty"`
	Score     float64  `json:"score,omitempty"`
	Images    []string `json:"images,omitempty"`
}

// VulnCounts tallies vulnerabilities by severity, and the fixable ones.
type VulnCounts struct {
	Critical        int `json:"critical"`
	High            int `json:"high"`
	Medium          int `json:"medium"`
	Low             int `json:"low"`
	Unknown         int `json:"unknown"`
	FixableCritical int `json:"fixableCritical"`
	FixableHigh     int `json:"fixableHigh"`
}

// ImageSummary is one image in use, with its scan result if any.
type ImageSummary struct {
	Image     string      `json:"image"`
	Workloads []ObjectRef `json:"workloads"`
	Scanned   bool        `json:"scanned"`
	Source    string      `json:"source,omitempty"` // trivy-operator | trivy-cli
	ScannedAt string      `json:"scannedAt,omitempty"`
	Counts    VulnCounts  `json:"counts"`
	TopCVEs   []CVE       `json:"topCVEs"`
}

const (
	topCVEsPerImage = 5
	topCVEsGlobal   = 15
)

var cveSevRank = map[string]int{"critical": 0, "high": 1, "medium": 2, "low": 3, "unknown": 4}

// SortCVEs orders by severity, fixable first, then CVSS score.
func SortCVEs(cs []CVE) {
	sort.SliceStable(cs, func(i, j int) bool {
		a, b := cs[i], cs[j]
		if cveSevRank[a.Severity] != cveSevRank[b.Severity] {
			return cveSevRank[a.Severity] < cveSevRank[b.Severity]
		}
		if (a.Fixed != "") != (b.Fixed != "") {
			return a.Fixed != ""
		}
		if len(a.Images) != len(b.Images) {
			return len(a.Images) > len(b.Images)
		}
		if a.Score != b.Score {
			return a.Score > b.Score
		}
		return a.ID < b.ID
	})
}

// Tally counts vulnerabilities (deduplicated by ID and package).
func Tally(cs []CVE) VulnCounts {
	var c VulnCounts
	seen := map[string]bool{}
	for _, v := range cs {
		k := v.ID + "|" + v.Package
		if seen[k] {
			continue
		}
		seen[k] = true
		switch v.Severity {
		case "critical":
			c.Critical++
			if v.Fixed != "" {
				c.FixableCritical++
			}
		case "high":
			c.High++
			if v.Fixed != "" {
				c.FixableHigh++
			}
		case "medium":
			c.Medium++
		case "low":
			c.Low++
		default:
			c.Unknown++
		}
	}
	return c
}

func str(m map[string]any, path ...string) string {
	s, _, _ := unstructured.NestedString(m, path...)
	return s
}

// reportVulns reads report.vulnerabilities from a VulnerabilityReport.
func reportVulns(r *unstructured.Unstructured) []CVE {
	list, _, _ := unstructured.NestedSlice(r.Object, "report", "vulnerabilities")
	out := make([]CVE, 0, len(list))
	for _, v := range list {
		m, ok := v.(map[string]any)
		if !ok {
			continue
		}
		score, _, _ := unstructured.NestedFloat64(m, "score")
		if score == 0 {
			if i, ok, _ := unstructured.NestedInt64(m, "score"); ok {
				score = float64(i)
			}
		}
		out = append(out, CVE{
			ID:        str(m, "vulnerabilityID"),
			Severity:  strings.ToLower(str(m, "severity")),
			Package:   str(m, "resource"),
			Installed: str(m, "installedVersion"),
			Fixed:     str(m, "fixedVersion"),
			Title:     str(m, "title"),
			Link:      str(m, "primaryLink"),
			Score:     score,
		})
	}
	return out
}

// reportImage is "registry/repository:tag" from a VulnerabilityReport.
func reportImage(r *unstructured.Unstructured) string {
	repo := str(r.Object, "report", "artifact", "repository")
	tag := str(r.Object, "report", "artifact", "tag")
	server := str(r.Object, "report", "registry", "server")
	img := repo
	if server != "" && server != "index.docker.io" {
		img = server + "/" + repo
	}
	if tag != "" {
		img += ":" + tag
	}
	return img
}

// reportTarget resolves the trivy-operator.resource.* labels to the unit
// (workload) it belongs to: ReplicaSet → Deployment, Pod → its owner.
func (a *analyzer) reportTarget(r *unstructured.Unstructured) *unit {
	kind, name, ns := reportResource(r)
	var ref ObjectRef
	switch kind {
	case "ReplicaSet":
		if o := a.rsOwn[key(ns, name)]; o != nil {
			ref = *o
		} else {
			ref = ObjectRef{Group: "apps", Kind: kind, Name: name, Namespace: ns}
		}
	case "Job":
		if o := a.jobOwn[key(ns, name)]; o != nil {
			ref = *o
		} else {
			ref = ObjectRef{Group: "batch", Kind: kind, Name: name, Namespace: ns}
		}
	case "Pod":
		for i := range a.in.Pods {
			if p := &a.in.Pods[i]; p.Namespace == ns && p.Name == name {
				if o := a.topOwner(ns, p.OwnerReferences); o != nil {
					ref = *o
				} else {
					ref = ObjectRef{Kind: "Pod", Name: name, Namespace: ns}
				}
			}
		}
	default:
		ref = ObjectRef{Kind: kind, Name: name, Namespace: ns}
	}
	for _, u := range a.units {
		if u.ref.Namespace == ns && u.ref.Kind == ref.Kind && u.ref.Name == ref.Name {
			return u
		}
	}
	return nil
}

// reportResource reads the trivy-operator.resource.* labels. Names that
// aren't valid label values (e.g. "system:foo") are in an annotation.
func reportResource(r *unstructured.Unstructured) (kind, name, ns string) {
	l := r.GetLabels()
	kind, name, ns = l["trivy-operator.resource.kind"], l["trivy-operator.resource.name"], l["trivy-operator.resource.namespace"]
	if name == "" {
		name = r.GetAnnotations()["trivy-operator.resource.name"]
	}
	if ns == "" {
		ns = r.GetNamespace()
	}
	return
}

// containerImage finds the image string a unit's container uses.
func (u *unit) containerImage(name string) string {
	for _, c := range allContainers(u.spec) {
		if c.Name == name {
			return c.Image
		}
	}
	return ""
}

type imageAgg struct {
	sum       *ImageSummary
	cves      []CVE
	workloads map[string]bool
	updated   string
}

func (a *analyzer) images() {
	aggs := map[string]*imageAgg{}
	var order []string
	get := func(img string) *imageAgg {
		g := aggs[img]
		if g == nil {
			g = &imageAgg{sum: &ImageSummary{Image: img, Workloads: []ObjectRef{}, TopCVEs: []CVE{}}, workloads: map[string]bool{}}
			aggs[img] = g
			order = append(order, img)
		}
		return g
	}
	addWorkload := func(g *imageAgg, r ObjectRef) {
		if !g.workloads[refKey(r)] {
			g.workloads[refKey(r)] = true
			g.sum.Workloads = append(g.sum.Workloads, r)
		}
	}
	for _, u := range a.units {
		for _, c := range allContainers(u.spec) {
			if c.Image != "" {
				addWorkload(get(c.Image), u.ref)
			}
		}
	}
	a.res.Sources.Reports["vulnerabilityreports"] = len(a.in.VulnerabilityReports)
	for i := range a.in.VulnerabilityReports {
		r := &a.in.VulnerabilityReports[i]
		if !a.inScope(r.GetNamespace()) {
			continue
		}
		u := a.reportTarget(r)
		img := ""
		if u != nil {
			img = u.containerImage(r.GetLabels()["trivy-operator.container.name"])
		}
		if img == "" {
			img = reportImage(r)
		}
		g := get(img)
		if u != nil {
			addWorkload(g, u.ref)
		}
		// Several reports can cover one image (one per ReplicaSet revision
		// or pod); keep the most recently updated.
		updated := str(r.Object, "report", "updateTimestamp")
		if !g.sum.Scanned || updated > g.updated {
			g.sum.Scanned, g.sum.Source, g.sum.ScannedAt, g.updated = true, "trivy-operator", updated, updated
			g.cves = reportVulns(r)
		}
	}
	global := map[string]*CVE{}
	for _, img := range order {
		g := aggs[img]
		s := g.sum
		if len(s.Workloads) == 0 {
			continue
		}
		if s.Scanned {
			s.Counts = Tally(g.cves)
			cs := append([]CVE{}, g.cves...)
			SortCVEs(cs)
			for _, c := range cs {
				if c.Severity != "critical" && c.Severity != "high" {
					break
				}
				gc := global[c.ID]
				if gc == nil {
					cp := c
					cp.Images = nil
					gc = &cp
					global[c.ID] = gc
				}
				if len(gc.Images) == 0 || gc.Images[len(gc.Images)-1] != img {
					gc.Images = append(gc.Images, img)
				}
			}
			s.TopCVEs = dedupeCVEs(cs, topCVEsPerImage)
			a.imageFinding(s)
		}
		a.res.Images = append(a.res.Images, *s)
	}
	sort.SliceStable(a.res.Images, func(i, j int) bool {
		x, y := a.res.Images[i], a.res.Images[j]
		if x.Counts.FixableCritical != y.Counts.FixableCritical {
			return x.Counts.FixableCritical > y.Counts.FixableCritical
		}
		if x.Counts.Critical != y.Counts.Critical {
			return x.Counts.Critical > y.Counts.Critical
		}
		if x.Counts.High != y.Counts.High {
			return x.Counts.High > y.Counts.High
		}
		if x.Scanned != y.Scanned {
			return x.Scanned
		}
		return x.Image < y.Image
	})
	top := make([]CVE, 0, len(global))
	for _, c := range global {
		top = append(top, *c)
	}
	SortCVEs(top)
	if len(top) > topCVEsGlobal {
		top = top[:topCVEsGlobal]
	}
	a.res.TopCVEs = top
	a.exposedSecrets()
	a.configAudits()
	a.rbacAssessments()
}

func dedupeCVEs(cs []CVE, n int) []CVE {
	out := []CVE{}
	seen := map[string]bool{}
	for _, c := range cs {
		if seen[c.ID] {
			continue
		}
		seen[c.ID] = true
		out = append(out, c)
		if len(out) == n {
			break
		}
	}
	return out
}

// ImageSeverity maps vulnerability counts to a finding severity ("" = none).
func ImageSeverity(c VulnCounts) string {
	switch {
	case c.FixableCritical > 0:
		return High
	case c.Critical > 0 || c.FixableHigh > 0:
		return Medium
	case c.High > 0:
		return Low
	}
	return ""
}

func (a *analyzer) imageFinding(s *ImageSummary) {
	sev := ImageSeverity(s.Counts)
	if sev == "" {
		return
	}
	c := s.Counts
	var title string
	switch {
	case c.FixableCritical > 0:
		title = fmt.Sprintf("%s has %s with a fix available", s.Image, plural(c.FixableCritical, "critical CVE", "critical CVEs"))
	case c.Critical > 0:
		title = fmt.Sprintf("%s has %s (no fix yet)", s.Image, plural(c.Critical, "critical CVE", "critical CVEs"))
	case c.FixableHigh > 0:
		title = fmt.Sprintf("%s has %s with a fix available", s.Image, plural(c.FixableHigh, "high CVE", "high CVEs"))
	default:
		title = fmt.Sprintf("%s has %s (no fix yet)", s.Image, plural(c.High, "high CVE", "high CVEs"))
	}
	tops := []string{}
	for _, v := range s.TopCVEs {
		t := fmt.Sprintf("%s (%s %s", v.ID, v.Package, v.Installed)
		if v.Fixed != "" {
			t += " → " + v.Fixed
		}
		tops = append(tops, t+")")
	}
	detail := fmt.Sprintf("%d critical (%d fixable), %d high (%d fixable), %d medium, %d low. Top: %s. Used by %s.",
		c.Critical, c.FixableCritical, c.High, c.FixableHigh, c.Medium, c.Low, strings.Join(tops, ", "), joinLimit(refNames(s.Workloads), 4))
	a.add(Finding{ID: "images.vulnerable/" + s.Image, Check: "images.vulnerable", Severity: sev, Category: CatImages,
		Title: title, Detail: detail,
		Remediation: "Rebuild on a patched base image or bump to a release that includes the fixed package versions, then redeploy.",
		Objects:     s.Workloads})
}

func failingChecks(r *unstructured.Unstructured, field string) (crit, high []string) {
	list, _, _ := unstructured.NestedSlice(r.Object, "report", field)
	for _, c := range list {
		m, ok := c.(map[string]any)
		if !ok {
			continue
		}
		if ok, found, _ := unstructured.NestedBool(m, "success"); found && ok {
			continue
		}
		t := str(m, "title")
		if id := str(m, "checkID"); id != "" {
			t = id + " " + t
		}
		switch strings.ToUpper(str(m, "severity")) {
		case "CRITICAL":
			crit = append(crit, t)
		case "HIGH":
			high = append(high, t)
		}
	}
	return
}

func (a *analyzer) exposedSecrets() {
	a.res.Sources.Reports["exposedsecretreports"] = len(a.in.ExposedSecretReports)
	for i := range a.in.ExposedSecretReports {
		r := &a.in.ExposedSecretReports[i]
		if !a.inScope(r.GetNamespace()) {
			continue
		}
		secrets, _, _ := unstructured.NestedSlice(r.Object, "report", "secrets")
		if len(secrets) == 0 {
			continue
		}
		titles := []string{}
		for _, s := range secrets {
			if m, ok := s.(map[string]any); ok {
				titles = append(titles, fmt.Sprintf("%s in %s", str(m, "title"), str(m, "target")))
			}
		}
		img := reportImage(r)
		objs := []ObjectRef{}
		if u := a.reportTarget(r); u != nil {
			objs = append(objs, u.ref)
			if ci := u.containerImage(r.GetLabels()["trivy-operator.container.name"]); ci != "" {
				img = ci
			}
		}
		a.add(Finding{ID: "images.exposed-secret/" + r.GetNamespace() + "/" + r.GetName(), Check: "images.exposed-secret", Severity: High, Category: CatImages, Namespace: r.GetNamespace(),
			Title:       fmt.Sprintf("%s contains %s", img, plural(len(secrets), "embedded secret", "embedded secrets")),
			Detail:      fmt.Sprintf("Trivy found credentials baked into the image: %s.", joinLimit(titles, 4)),
			Remediation: "Remove the secret from the image, rotate it, and inject it at runtime from a Secret.",
			Objects:     objs})
	}
}

func (a *analyzer) configAudits() {
	a.res.Sources.Reports["configauditreports"] = len(a.in.ConfigAuditReports)
	for i := range a.in.ConfigAuditReports {
		r := &a.in.ConfigAuditReports[i]
		if !a.inScope(r.GetNamespace()) {
			continue
		}
		crit, high := failingChecks(r, "checks")
		if len(crit) == 0 {
			continue // high-only results largely repeat the Pod Security checks above
		}
		u := a.reportTarget(r)
		kind, name, _ := reportResource(r)
		ref := ObjectRef{Kind: kind, Name: name, Namespace: r.GetNamespace()}
		if u != nil {
			ref = u.ref
		}
		a.add(Finding{ID: "workloads.trivy-config-audit/" + refKey(ref), Check: "workloads.trivy-config-audit", Severity: Medium, Category: CatWorkloads, Namespace: r.GetNamespace(),
			Title:       fmt.Sprintf("Trivy config audit: %s fails %s", kindLabel(ref), plural(len(crit), "critical check", "critical checks")),
			Detail:      fmt.Sprintf("Critical: %s. High: %d more.", joinLimit(crit, 4), len(high)),
			Remediation: "See the ConfigAuditReport for each check's remediation.",
			Objects:     []ObjectRef{ref}})
	}
}

func (a *analyzer) rbacAssessments() {
	a.res.Sources.Reports["rbacassessmentreports"] = len(a.in.RbacAssessmentReports)
	a.res.Sources.Reports["clusterrbacassessmentreports"] = len(a.in.ClusterRbacAssessmentReports)
	// Roles our own scoring already flags are skipped (their findings carry
	// more context), as are Kubernetes' default roles unless IncludeSystem.
	handle := func(r *unstructured.Unstructured, cluster bool) {
		kind, name, _ := reportResource(r)
		k := "ClusterRole//" + name
		if !cluster {
			k = "Role/" + r.GetNamespace() + "/" + name
		}
		if ri := a.roles[k]; ri != nil && (ri.score > 0 || (ri.system && !a.in.IncludeSystem)) {
			return
		}
		if !a.in.IncludeSystem && (strings.HasPrefix(name, "system:") || IsSystemNamespace(r.GetNamespace())) {
			return
		}
		crit, high := failingChecks(r, "checks")
		if len(crit) == 0 && len(high) == 0 {
			return
		}
		sev := Low
		ref := ObjectRef{Group: "rbac.authorization.k8s.io", Kind: kind, Name: name}
		if !cluster {
			ref.Namespace = r.GetNamespace()
		}
		a.add(Finding{ID: "rbac.trivy-assessment/" + refKey(ref), Check: "rbac.trivy-assessment", Severity: sev, Category: CatRBAC, Namespace: ref.Namespace,
			Title:       fmt.Sprintf("Trivy RBAC assessment: %s %s has %s", kind, name, plural(len(crit)+len(high), "critical/high issue", "critical/high issues")),
			Detail:      fmt.Sprintf("%s.", joinLimit(append(crit, high...), 4)),
			Remediation: "See the RbacAssessmentReport for each check's remediation.",
			Objects:     []ObjectRef{ref}})
	}
	for i := range a.in.RbacAssessmentReports {
		if r := &a.in.RbacAssessmentReports[i]; a.inScope(r.GetNamespace()) {
			handle(r, false)
		}
	}
	if a.in.Namespace == "" {
		for i := range a.in.ClusterRbacAssessmentReports {
			handle(&a.in.ClusterRbacAssessmentReports[i], true)
		}
	}
}
