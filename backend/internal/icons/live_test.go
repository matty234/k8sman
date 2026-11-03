package icons

import (
	"context"
	"os"
	"testing"
)

// TestLiveFavicons fetches real favicons. Opt in with K8SMAN_LIVE_ICONS=1.
func TestLiveFavicons(t *testing.T) {
	if os.Getenv("K8SMAN_LIVE_ICONS") == "" {
		t.Skip("set K8SMAN_LIVE_ICONS=1 to fetch real favicons")
	}
	f := NewFetcher()
	for d, want := range map[string]bool{
		"argoproj.io":     true, // meta refresh to argoproj.github.io
		"cert-manager.io": true,
		"keda.sh":         true,
		"envoyproxy.io":   true,
		"coreos.com":      true,
		// Redirects to github.com/aquasecurity: GitHub's icon is refused.
		"aquasecurity.github.io": false,
	} {
		data, ct, u, err := f.FetchFavicon(context.Background(), d)
		switch {
		case want && err != nil:
			t.Errorf("%s: %v", d, err)
		case !want && err == nil:
			t.Errorf("%s: unexpectedly got %s", d, u)
		case err == nil:
			t.Logf("%s: %s (%s, %d bytes)", d, u, ct, len(data))
		default:
			t.Logf("%s: %v (expected)", d, err)
		}
	}
}
