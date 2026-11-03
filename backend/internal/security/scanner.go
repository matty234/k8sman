package security

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// InstallHint is shown when the trivy CLI is missing.
const InstallHint = "Install trivy (`brew install trivy`) to scan images on demand."

// Scanner limits.
const (
	ScanTimeout    = 5 * time.Minute
	ScanCacheTTL   = time.Hour
	maxScanVulns   = 300
	maxConcurrency = 2
)

// ErrNoTrivy is returned when the trivy binary is not on PATH.
var ErrNoTrivy = errors.New("trivy is not installed. " + InstallHint)

// ErrBadImage rejects image references that aren't plausible (and anything
// that could be read as a flag).
var ErrBadImage = errors.New("invalid image reference")

var imageRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._\-/:@+]*$`)

// ValidImage reports whether s looks like an image reference.
func ValidImage(s string) bool { return len(s) <= 512 && imageRe.MatchString(s) }

// TrivyStatus describes the local trivy CLI.
type TrivyStatus struct {
	Available bool   `json:"available"`
	Path      string `json:"path,omitempty"`
	Version   string `json:"version,omitempty"`
	Hint      string `json:"hint,omitempty"`
}

// ScanResult is the outcome of one on-demand scan.
type ScanResult struct {
	Image     string     `json:"image"`
	ScannedAt string     `json:"scannedAt"`
	Duration  string     `json:"duration,omitempty"`
	Cached    bool       `json:"cached"`
	OS        string     `json:"os,omitempty"`
	Counts    VulnCounts `json:"counts"`
	// Vulnerabilities, most severe first (capped).
	Vulnerabilities []CVE `json:"vulnerabilities"`
	Total           int   `json:"total"`
	scannedAt       time.Time
}

// trivy's `--format json` output (the parts we use).
type trivyReport struct {
	ArtifactName string `json:"ArtifactName"`
	Metadata     struct {
		OS *struct {
			Family string `json:"Family"`
			Name   string `json:"Name"`
		} `json:"OS"`
	} `json:"Metadata"`
	Results []struct {
		Target          string `json:"Target"`
		Vulnerabilities []struct {
			VulnerabilityID  string `json:"VulnerabilityID"`
			PkgName          string `json:"PkgName"`
			InstalledVersion string `json:"InstalledVersion"`
			FixedVersion     string `json:"FixedVersion"`
			Severity         string `json:"Severity"`
			Title            string `json:"Title"`
			PrimaryURL       string `json:"PrimaryURL"`
			CVSS             map[string]struct {
				V3Score float64 `json:"V3Score"`
			} `json:"CVSS"`
		} `json:"Vulnerabilities"`
	} `json:"Results"`
}

// ParseTrivyJSON turns `trivy image --format json` output into a ScanResult.
func ParseTrivyJSON(b []byte) (*ScanResult, error) {
	var r trivyReport
	if err := json.Unmarshal(b, &r); err != nil {
		return nil, fmt.Errorf("parse trivy output: %w", err)
	}
	res := &ScanResult{Image: r.ArtifactName, Vulnerabilities: []CVE{}}
	if r.Metadata.OS != nil {
		res.OS = strings.TrimSpace(r.Metadata.OS.Family + " " + r.Metadata.OS.Name)
	}
	var all []CVE
	for _, t := range r.Results {
		for _, v := range t.Vulnerabilities {
			score := 0.0
			for _, src := range []string{"nvd", "redhat", "ghsa"} {
				if c, ok := v.CVSS[src]; ok && c.V3Score > 0 {
					score = c.V3Score
					break
				}
			}
			all = append(all, CVE{
				ID: v.VulnerabilityID, Severity: strings.ToLower(v.Severity), Package: v.PkgName,
				Installed: v.InstalledVersion, Fixed: v.FixedVersion, Title: v.Title, Link: v.PrimaryURL, Score: score,
			})
		}
	}
	res.Counts = Tally(all)
	SortCVEs(all)
	seen := map[string]bool{}
	for _, c := range all {
		k := c.ID + "|" + c.Package
		if seen[k] {
			continue
		}
		seen[k] = true
		res.Total++
		if len(res.Vulnerabilities) < maxScanVulns {
			res.Vulnerabilities = append(res.Vulnerabilities, c)
		}
	}
	return res, nil
}

// Scanner runs the local trivy CLI with a result cache.
type Scanner struct {
	// LookPath and Run are swappable for tests.
	LookPath func(string) (string, error)
	Run      func(ctx context.Context, bin string, args ...string) ([]byte, error)
	Now      func() time.Time

	mu       sync.Mutex
	cache    map[string]*ScanResult
	inflight map[string]chan struct{}
	version  map[string]string // path → version
	sem      chan struct{}
}

// NewScanner returns a Scanner that uses the real trivy on PATH.
func NewScanner() *Scanner {
	return &Scanner{
		LookPath: exec.LookPath,
		Run: func(ctx context.Context, bin string, args ...string) ([]byte, error) {
			cmd := exec.CommandContext(ctx, bin, args...)
			var stderr strings.Builder
			cmd.Stderr = &stderr
			out, err := cmd.Output()
			if err != nil {
				msg := strings.TrimSpace(stderr.String())
				if len(msg) > 600 {
					msg = msg[len(msg)-600:]
				}
				if ctx.Err() != nil {
					return nil, fmt.Errorf("trivy timed out: %w", ctx.Err())
				}
				return nil, fmt.Errorf("trivy failed: %v: %s", err, msg)
			}
			return out, nil
		},
		Now: time.Now,
	}
}

func (s *Scanner) init() {
	if s.cache == nil {
		s.cache = map[string]*ScanResult{}
		s.inflight = map[string]chan struct{}{}
		s.version = map[string]string{}
		s.sem = make(chan struct{}, maxConcurrency)
	}
}

// Status reports whether trivy is available, and its version.
func (s *Scanner) Status(ctx context.Context) TrivyStatus {
	path, err := s.LookPath("trivy")
	if err != nil {
		return TrivyStatus{Hint: InstallHint}
	}
	s.mu.Lock()
	s.init()
	v, ok := s.version[path]
	s.mu.Unlock()
	if !ok {
		vctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		if out, err := s.Run(vctx, path, "version", "--format", "json"); err == nil {
			v = ParseTrivyVersion(out)
		}
		s.mu.Lock()
		s.version[path] = v
		s.mu.Unlock()
	}
	return TrivyStatus{Available: true, Path: path, Version: v}
}

// ParseTrivyVersion reads `trivy version --format json` (or the plain
// "Version: x" text output).
func ParseTrivyVersion(b []byte) string {
	var j struct {
		Version string `json:"Version"`
	}
	if json.Unmarshal(b, &j) == nil && j.Version != "" {
		return j.Version
	}
	for _, line := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "Version:"); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// Cached returns a fresh cached result for image, or nil.
func (s *Scanner) Cached(image string) *ScanResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.init()
	r := s.cache[image]
	if r == nil || s.Now().Sub(r.scannedAt) > ScanCacheTTL {
		return nil
	}
	cp := *r
	cp.Cached = true
	return &cp
}

// Scan scans image with trivy, or returns the cached result (unless force).
// Concurrent scans of the same image share one trivy run.
func (s *Scanner) Scan(ctx context.Context, image string, force bool) (*ScanResult, error) {
	if !ValidImage(image) {
		return nil, ErrBadImage
	}
	path, err := s.LookPath("trivy")
	if err != nil {
		return nil, ErrNoTrivy
	}
	for {
		if !force {
			if r := s.Cached(image); r != nil {
				return r, nil
			}
		}
		s.mu.Lock()
		s.init()
		if ch, ok := s.inflight[image]; ok {
			s.mu.Unlock()
			select {
			case <-ch:
				force = false
				continue // pick up the other scan's result
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		ch := make(chan struct{})
		s.inflight[image] = ch
		s.mu.Unlock()
		res, err := s.run(ctx, path, image)
		s.mu.Lock()
		delete(s.inflight, image)
		if err == nil {
			s.cache[image] = res
		}
		s.mu.Unlock()
		close(ch)
		if err != nil {
			return nil, err
		}
		cp := *res
		return &cp, nil
	}
}

func (s *Scanner) run(ctx context.Context, path, image string) (*ScanResult, error) {
	select {
	case s.sem <- struct{}{}:
		defer func() { <-s.sem }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	ctx, cancel := context.WithTimeout(ctx, ScanTimeout)
	defer cancel()
	start := s.Now()
	out, err := s.Run(ctx, path, "image", "--format", "json", "--quiet", "--scanners", "vuln", "--timeout", ScanTimeout.String(), "--", image)
	if err != nil {
		return nil, err
	}
	res, err := ParseTrivyJSON(out)
	if err != nil {
		return nil, err
	}
	res.Image = image
	res.scannedAt = s.Now()
	res.ScannedAt = res.scannedAt.UTC().Format(time.RFC3339)
	res.Duration = res.scannedAt.Sub(start).Round(time.Second).String()
	return res, nil
}
