package portforward

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/matty234/k8sman/backend/internal/cluster"
)

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
