package security

import (
	"context"
	"errors"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseTrivyJSON(t *testing.T) {
	b, err := os.ReadFile("testdata/trivy-image.json")
	if err != nil {
		t.Fatal(err)
	}
	r, err := ParseTrivyJSON(b)
	if err != nil {
		t.Fatal(err)
	}
	if r.Image != "nginx:1.25" || r.OS != "debian 12.5" {
		t.Errorf("metadata: %+v", r)
	}
	want := VulnCounts{Critical: 2, FixableCritical: 1, High: 4, FixableHigh: 3, Medium: 1, Low: 1}
	if r.Counts != want {
		t.Errorf("counts: %+v want %+v", r.Counts, want)
	}
	if r.Total != 8 || len(r.Vulnerabilities) != 8 {
		t.Errorf("total: %d", r.Total)
	}
	first := r.Vulnerabilities[0]
	if first.ID != "CVE-2024-45491" || first.Fixed != "2.5.0-1+deb12u1" || first.Score != 9.8 || first.Severity != "critical" {
		t.Errorf("fixable critical first: %+v", first)
	}
	if r.Vulnerabilities[1].ID != "CVE-2023-45853" {
		t.Errorf("then unfixable critical: %+v", r.Vulnerabilities[1])
	}
	for _, v := range r.Vulnerabilities {
		if v.ID == "CVE-2024-34156" && v.Score != 7.5 {
			t.Errorf("ghsa score fallback: %+v", v)
		}
	}
	if _, err := ParseTrivyJSON([]byte("not json")); err == nil {
		t.Error("bad json")
	}
}

func TestParseTrivyVersion(t *testing.T) {
	if v := ParseTrivyVersion([]byte(`{"Version":"0.57.1","VulnerabilityDB":{}}`)); v != "0.57.1" {
		t.Error(v)
	}
	if v := ParseTrivyVersion([]byte("Version: 0.50.0\nVulnerability DB:\n")); v != "0.50.0" {
		t.Error(v)
	}
}

func TestValidImage(t *testing.T) {
	for img, ok := range map[string]bool{
		"nginx": true, "nginx:1.27": true, "ghcr.io/a/b:v1@sha256:abc": true, "localhost:5000/x": true,
		"": false, "-rf": false, "--help": false, "a b": false, "x;rm": false, "$(id)": false,
	} {
		if ValidImage(img) != ok {
			t.Errorf("ValidImage(%q) != %v", img, ok)
		}
	}
}

type fakeTrivy struct {
	calls atomic.Int32
	args  [][]string
	mu    sync.Mutex
	gate  chan struct{}
	err   error
}

func newTestScanner(ft *fakeTrivy, installed bool, clock *time.Time) *Scanner {
	sample, _ := os.ReadFile("testdata/trivy-image.json")
	s := NewScanner()
	s.LookPath = func(string) (string, error) {
		if !installed {
			return "", errors.New("not found")
		}
		return "/opt/homebrew/bin/trivy", nil
	}
	s.Now = func() time.Time { return *clock }
	s.Run = func(ctx context.Context, bin string, args ...string) ([]byte, error) {
		ft.mu.Lock()
		ft.args = append(ft.args, args)
		ft.mu.Unlock()
		if args[0] == "version" {
			return []byte(`{"Version":"0.57.1"}`), nil
		}
		ft.calls.Add(1)
		if ft.gate != nil {
			<-ft.gate
		}
		return sample, ft.err
	}
	return s
}

func TestScannerNotInstalled(t *testing.T) {
	clock := now
	s := newTestScanner(&fakeTrivy{}, false, &clock)
	st := s.Status(context.Background())
	if st.Available || st.Hint != InstallHint {
		t.Errorf("status: %+v", st)
	}
	if _, err := s.Scan(context.Background(), "nginx:1.25", false); !errors.Is(err, ErrNoTrivy) {
		t.Errorf("err: %v", err)
	}
}

func TestScannerScanAndCache(t *testing.T) {
	clock := now
	ft := &fakeTrivy{}
	s := newTestScanner(ft, true, &clock)
	st := s.Status(context.Background())
	if !st.Available || st.Version != "0.57.1" || st.Path == "" {
		t.Errorf("status: %+v", st)
	}
	if _, err := s.Scan(context.Background(), "--config=/etc/passwd", false); !errors.Is(err, ErrBadImage) {
		t.Errorf("flag injection rejected: %v", err)
	}
	r, err := s.Scan(context.Background(), "nginx:1.25", false)
	if err != nil {
		t.Fatal(err)
	}
	if r.Cached || r.Counts.Critical != 2 || r.Image != "nginx:1.25" || r.ScannedAt == "" {
		t.Errorf("first scan: %+v", r)
	}
	args := ft.args[len(ft.args)-1]
	for _, want := range []string{"image", "--format", "json", "--quiet", "--scanners", "vuln", "--"} {
		if !slices.Contains(args, want) {
			t.Errorf("args %v missing %s", args, want)
		}
	}
	if args[len(args)-1] != "nginx:1.25" || args[len(args)-2] != "--" {
		t.Errorf("image is last, after --: %v", args)
	}
	r, _ = s.Scan(context.Background(), "nginx:1.25", false)
	if !r.Cached || ft.calls.Load() != 1 {
		t.Errorf("second scan cached: %+v calls=%d", r, ft.calls.Load())
	}
	if s.Cached("nginx:1.25") == nil || s.Cached("other") != nil {
		t.Error("Cached lookup")
	}
	if _, err := s.Scan(context.Background(), "nginx:1.25", true); err != nil || ft.calls.Load() != 2 {
		t.Errorf("force rescans: %v %d", err, ft.calls.Load())
	}
	clock = clock.Add(ScanCacheTTL + time.Minute)
	if s.Cached("nginx:1.25") != nil {
		t.Error("cache expires after the TTL")
	}
	s.Scan(context.Background(), "nginx:1.25", false)
	if ft.calls.Load() != 3 {
		t.Errorf("expired entry rescanned: %d", ft.calls.Load())
	}
}

func TestScannerSharesInflight(t *testing.T) {
	clock := now
	ft := &fakeTrivy{gate: make(chan struct{})}
	s := newTestScanner(ft, true, &clock)
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Scan(context.Background(), "nginx:1.25", false); err != nil {
				t.Error(err)
			}
		}()
	}
	// Let all three reach the scanner, then release trivy.
	deadline := time.Now().Add(2 * time.Second)
	for ft.calls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	close(ft.gate)
	wg.Wait()
	if ft.calls.Load() != 1 {
		t.Errorf("concurrent scans of one image share a run: %d", ft.calls.Load())
	}
}

func TestScannerError(t *testing.T) {
	clock := now
	ft := &fakeTrivy{err: errors.New("trivy failed: exit 1: unable to find image")}
	s := newTestScanner(ft, true, &clock)
	if _, err := s.Scan(context.Background(), "nope:1", false); err == nil {
		t.Error("error propagates")
	}
	if s.Cached("nope:1") != nil {
		t.Error("failures are not cached")
	}
}
