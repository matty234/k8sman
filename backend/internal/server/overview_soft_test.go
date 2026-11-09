package server

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/matty234/k8sman/backend/internal/overview"
	"github.com/matty234/k8sman/backend/internal/prom"
)

// The soft deadline answers with what has finished and names the rest in
// pending, pods are always waited for, and a source finishing late can't
// race with the analysis of a snapshot (run with -race).
func TestOverviewSoftDeadlinePartial(t *testing.T) {
	l := newOverviewLists(context.Background(), nil, "")
	release := make(chan struct{})
	l.Go("pods", func() (func(*overview.Input), error) {
		time.Sleep(80 * time.Millisecond) // later than the soft deadline
		return func(in *overview.Input) { in.Pods = []corev1.Pod{{ObjectMeta: metav1.ObjectMeta{Name: "web", Namespace: "d"}}} }, nil
	})
	l.Go("deployments", func() (func(*overview.Input), error) {
		return func(in *overview.Input) { in.Deployments = []appsv1.Deployment{{}} }, nil
	})
	l.Go("alerts", func() (func(*overview.Input), error) {
		<-release
		return func(in *overview.Input) { in.Alerts = []prom.Alert{{}} }, nil
	})

	res, _, ok := l.respond(context.Background(), 10*time.Millisecond)
	if !ok || res.Counts.Pods.Total != 1 {
		t.Fatalf("pods must be waited for: ok=%v total=%d", ok, res.Counts.Pods.Total)
	}
	if !slices.Equal(res.Pending, []string{"alerts"}) {
		t.Fatalf("pending = %v, want [alerts]", res.Pending)
	}

	close(release)
	for range 200 { // snapshot, analyse and serialise while alerts lands
		in, _ := l.snapshot()
		if _, err := json.Marshal(overview.Analyze(in)); err != nil {
			t.Fatal(err)
		}
	}
	l.wg.Wait()
	if in, _ := l.snapshot(); len(in.Pending) != 0 || len(in.Alerts) != 1 {
		t.Fatalf("after the late source: pending=%v alerts=%d", in.Pending, len(in.Alerts))
	}
}
