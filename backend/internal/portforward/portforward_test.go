package portforward

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"k8s.io/client-go/kubernetes/fake"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

// A forward defaults its local port to the remote one when free (or the next
// free port), remembers its browser choices, and an ephemeral forward is not
// saved. Only a 404 from the target counts as "gone".
func TestDefaultsEphemeralAndGoneTargets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pf.json")
	m, err := NewManager(cluster.NewDisconnected("", errors.New("no cluster")), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.StopAll)
	if p, same, _ := m.FreeLocalPort("127.0.0.1", 18090); p != 18090 || !same {
		t.Fatalf("free remote port should be reused, got %d %v", p, same)
	}
	if p, same, _ := m.FreeLocalPort("127.0.0.1", 80); p != 8080 || same {
		t.Fatalf("privileged port should map to 8080, got %d %v", p, same)
	}
	st, err := m.Create(Spec{Context: "a", Kubeconfig: "k", Namespace: "ns", Kind: "pod", Name: "p", Port: "18090", OpenInBrowser: true, HTTPS: true}, false)
	if err != nil || st.LocalPort != 18090 || st.URL != "https://localhost:18090" {
		t.Fatalf("create: %+v %v", st, err)
	}
	if p, same, _ := m.FreeLocalPort("127.0.0.1", 18090); p == 18090 || same {
		t.Fatalf("a port held by our forward must be skipped, got %d", p)
	}
	if _, err := m.Create(Spec{Context: "a", Kubeconfig: "k", Namespace: "ns", Kind: "pod", Name: "tmp", Port: "80", Ephemeral: true}, false); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if !strings.Contains(string(b), `"openInBrowser": true`) || strings.Contains(string(b), `"tmp"`) {
		t.Fatalf("saved set wrong: %s", b)
	}

	c := &cluster.Clients{Typed: fake.NewSimpleClientset()}
	if err := getTarget(context.Background(), c, Spec{Kind: "service", Namespace: "ns", Name: "gone"}); !isGone(err) {
		t.Fatalf("missing service should be gone: %v", err)
	}
	if isGone(errors.New("connection refused")) {
		t.Fatal("other errors are not gone")
	}
}

// Bulk stop keeps forwards saved, and replacing a forward on a used local
// port frees the port for the new one and updates the saved set.
func TestStopContextAndReplace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "pf.json")
	m, err := NewManager(cluster.NewDisconnected("", errors.New("no cluster")), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.StopAll)
	spec := func(name string, port int) Spec {
		return Spec{Context: "a", Kubeconfig: "k", Namespace: "ns", Kind: "pod", Name: name, Port: "80", LocalPort: port}
	}
	old, err := m.Create(spec("old", 18080), false)
	if err != nil {
		t.Fatal(err)
	}
	var inUse *PortInUseError
	if _, err := m.Create(spec("new", 18080), false); !errors.As(err, &inUse) || inUse.By == nil || inUse.By.Name != "old" || inUse.Suggested == 18080 {
		t.Fatalf("want PortInUseError held by old with a suggestion, got %v", err)
	}
	nw, err := m.Create(spec("new", 18080), true)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m.Get(old.ID); ok || len(m.List()) != 1 || nw.LocalPort != 18080 {
		t.Fatalf("old forward should be gone: %+v", m.List())
	}
	if b, _ := os.ReadFile(path); strings.Contains(string(b), `"old"`) || !strings.Contains(string(b), `"new"`) {
		t.Fatalf("saved set not updated: %s", b)
	}
	if n := m.StopContext("b"); n != 0 {
		t.Fatalf("other context stopped %d", n)
	}
	if n := m.StopContext("a"); n != 1 || m.List()[0].State != Stopped {
		t.Fatalf("StopContext(a) = %d, %+v", n, m.List())
	}
}
