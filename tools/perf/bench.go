package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// heapCmd prints the live heap (after a forced GC) and goroutine count.
func heapCmd(fs *flag.FlagSet) func() error {
	pp := fs.String("pprof", "127.0.0.1:7575", "backend pprof address")
	label := fs.String("label", "", "row label")
	return func() error {
		h, err := heapInuse(*pp)
		if err != nil {
			return err
		}
		g, err := goroutines(*pp)
		if err != nil {
			return err
		}
		fmt.Printf("| heap in use %s | %.1f MiB | goroutines %d |\n", *label, h, g)
		return nil
	}
}

// latencyCmd times the UI-facing endpoints at scale.
func latencyCmd(fs *flag.FlagSet) func() error {
	base := fs.String("base", "http://127.0.0.1:7574", "backend URL")
	n := fs.Int("n", 10, "requests per endpoint")
	ns := fs.String("ns", "perf-load", "load namespace")
	warm := fs.Bool("warm", false, "keep watches open on configmaps (ns) and pods (all) while measuring, like an open table")
	return func() error {
		if *warm {
			for _, qs := range []string{q("version", "v1", "resource", "configmaps", "namespace", *ns, "batch", "true"), q("version", "v1", "resource", "pods", "batch", "true")} {
				w, err := openWatch(*base, qs)
				if err != nil {
					return err
				}
				if _, err := w.waitSnapshot(time.Minute); err != nil {
					return err
				}
				defer w.close()
			}
		}
		eps := []struct{ name, path string }{
			{"resources", "/api/resources"},
			{"resources?refresh=true (re-discover)", "/api/resources?refresh=true"},
			{"table configmaps (ns, 1.5k)", "/api/table?" + q("version", "v1", "resource", "configmaps", "namespace", *ns)},
			{"table pods (all ns)", "/api/table?" + q("version", "v1", "resource", "pods")},
			{"items configmaps (ns)", "/api/items?" + q("version", "v1", "resource", "configmaps", "namespace", *ns)},
			{"overview (all ns)", "/api/overview"},
			{"overview (ns)", "/api/overview?" + q("namespace", *ns)},
			{"security (ns)", "/api/security?" + q("namespace", *ns)},
			{"security (all ns)", "/api/security"},
		}
		fmt.Printf("| endpoint | p50 ms | p95 ms | min ms | KiB |\n|---|---|---|---|---|\n")
		for _, e := range eps {
			var ds durations
			size := 0
			for range *n {
				d, b, err := get(*base, e.path)
				if err != nil {
					return err
				}
				ds = append(ds, d)
				size = b
			}
			fmt.Printf("| %s | %s | %s | %s | %d |\n", e.name, ms(ds.pct(.5)), ms(ds.pct(.95)), ms(ds.pct(0)), size/1024)
		}
		for _, wq := range []struct{ name, query string }{
			{"watch first SNAPSHOT configmaps (ns)", q("version", "v1", "resource", "configmaps", "namespace", *ns, "batch", "true")},
			{"watch first SNAPSHOT pods (all ns)", q("version", "v1", "resource", "pods", "batch", "true")},
		} {
			var ds durations
			for range *n {
				w, err := openWatch(*base, wq.query)
				if err != nil {
					return err
				}
				d, err := w.waitSnapshot(time.Minute)
				w.close()
				if err != nil {
					return err
				}
				ds = append(ds, d)
			}
			fmt.Printf("| %s | %s | %s | %s | |\n", wq.name, ms(ds.pct(.5)), ms(ds.pct(.95)), ms(ds.pct(0)))
		}
		return nil
	}
}

// firstPod returns a running pod name in ns via the backend.
func firstPod(base, ns string) (string, error) {
	resp, err := httpc.Get(base + "/api/items?" + q("version", "v1", "resource", "pods", "namespace", ns, "fieldSelector", "status.phase=Running"))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var body struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		} `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	if len(body.Items) == 0 {
		return "", fmt.Errorf("no running pod in %s", ns)
	}
	return body.Items[0].Metadata.Name, nil
}

// typicalCmd: one table watch (pods, all namespaces) + the inspector's
// single-object watch + the Overview poll every 10s + the alerts badge every
// 30s, sampling the backend's RSS and CPU.
func typicalCmd(fs *flag.FlagSet) func() error {
	base := fs.String("base", "http://127.0.0.1:7574", "backend URL")
	pid := fs.Int("pid", 0, "backend pid")
	dur := fs.Duration("dur", 60*time.Second, "duration")
	ns := fs.String("ns", "perf-load", "load namespace")
	return func() error {
		pod, err := firstPod(*base, *ns)
		if err != nil {
			return err
		}
		smp := startSampler(*pid, time.Second)
		table, err := openWatch(*base, q("version", "v1", "resource", "pods", "batch", "true"))
		if err != nil {
			return err
		}
		inspector, err := openWatch(*base, q("version", "v1", "resource", "pods", "namespace", *ns, "fieldSelector", "metadata.name="+pod, "includeObject", "true", "batch", "true"))
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), *dur)
		defer cancel()
		var ovr durations
		poll := func(every time.Duration, path string, rec *durations) {
			t := time.NewTicker(every)
			defer t.Stop()
			for {
				d, _, err := get(*base, path)
				if err == nil && rec != nil {
					*rec = append(*rec, d)
				}
				select {
				case <-ctx.Done():
					return
				case <-t.C:
				}
			}
		}
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); poll(10*time.Second, "/api/overview", &ovr) }()
		go func() { defer wg.Done(); poll(30*time.Second, "/api/prometheus/alerts", nil) }()
		wg.Wait()
		avg, mx, cpu := smp.finish()
		table.close()
		inspector.close()
		fmt.Printf("| typical use %s | RSS avg %.0f MiB | RSS max %.0f MiB | CPU %.1f%% | overview p50 %s ms | table frames %d (events %d, %d KiB) |\n",
			*dur, avg, mx, cpu, ms(ovr.pct(.5)), table.frames.Load(), table.events.Load(), table.bytes.Load()/1024)
		return nil
	}
}

func idleCmd(fs *flag.FlagSet) func() error {
	pid := fs.Int("pid", 0, "backend pid")
	dur := fs.Duration("dur", 30*time.Second, "duration")
	return func() error {
		smp := startSampler(*pid, time.Second)
		time.Sleep(*dur)
		avg, mx, cpu := smp.finish()
		fmt.Printf("| idle %s | RSS avg %.0f MiB | RSS max %.0f MiB | CPU %.2f%% |\n", *dur, avg, mx, cpu)
		return nil
	}
}

// upstreamWatches counts WATCH requests for a resource registered at the API
// server (apiserver_longrunning_requests / apiserver_registered_watchers).
func upstreamWatches(kubeconfig, kctx, resource string) (int, error) {
	out, err := exec.Command("kubectl", "--kubeconfig", kubeconfig, "--context", kctx, "get", "--raw", "/metrics").Output()
	if err != nil {
		return 0, err
	}
	total := 0
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		l := sc.Text()
		if strings.HasPrefix(l, "apiserver_longrunning_requests{") && strings.Contains(l, `resource="`+resource+`"`) &&
			strings.Contains(l, `verb="WATCH"`) && strings.Contains(l, `scope="namespace"`) {
			var v float64
			fmt.Sscan(l[strings.LastIndex(l, " ")+1:], &v)
			total += int(v)
		}
	}
	return total, nil
}

// fanoutCmd opens N watches on the same resource and reports the upstream
// watch count, time to all snapshots and backend memory while they receive
// churn (run `perf churn` alongside).
func fanoutCmd(fs *flag.FlagSet) func() error {
	base := fs.String("base", "http://127.0.0.1:7574", "backend URL")
	pid := fs.Int("pid", 0, "backend pid")
	n := fs.Int("n", 10, "watchers")
	ns := fs.String("ns", "perf-load", "load namespace")
	kc := fs.String("kubeconfig", "", "kubeconfig for apiserver metrics")
	kctx := fs.String("context", "", "context for apiserver metrics")
	hold := fs.Duration("hold", 20*time.Second, "how long to keep the watchers open")
	return func() error {
		before, err := upstreamWatches(*kc, *kctx, "configmaps")
		if err != nil {
			return err
		}
		start := time.Now()
		ws := make([]*watcher, *n)
		var wg sync.WaitGroup
		var firstErr error
		var mu sync.Mutex
		for i := range ws {
			wg.Add(1)
			go func() {
				defer wg.Done()
				w, err := openWatch(*base, q("version", "v1", "resource", "configmaps", "namespace", *ns, "batch", "true"))
				if err == nil {
					_, err = w.waitSnapshot(2 * time.Minute)
				}
				mu.Lock()
				defer mu.Unlock()
				if err != nil && firstErr == nil {
					firstErr = err
				}
				ws[i] = w
			}()
		}
		wg.Wait()
		if firstErr != nil {
			return firstErr
		}
		all := time.Since(start)
		smp := startSampler(*pid, time.Second)
		time.Sleep(*hold)
		during, err := upstreamWatches(*kc, *kctx, "configmaps")
		if err != nil {
			return err
		}
		avg, mx, cpu := smp.finish()
		var frames, events, kib int64
		for _, w := range ws {
			frames += w.frames.Load()
			events += w.events.Load()
			kib += w.bytes.Load() / 1024
			w.close()
		}
		fmt.Printf("| %d watchers | all SNAPSHOTs %s ms | upstream configmap watches +%d | RSS avg %.0f / max %.0f MiB | CPU %.1f%% | frames %d, events %d, %d KiB |\n",
			*n, ms(all), during-before, avg, mx, cpu, frames, events, kib)
		return nil
	}
}

// leakCmd opens and closes N watches and N log streams and checks that the
// goroutine count returns to its baseline.
func leakCmd(fs *flag.FlagSet) func() error {
	base := fs.String("base", "http://127.0.0.1:7574", "backend URL")
	pp := fs.String("pprof", "127.0.0.1:7575", "backend pprof address")
	n := fs.Int("n", 100, "watches and log streams to open")
	ns := fs.String("ns", "perf-load", "load namespace")
	return func() error {
		pod, err := firstPod(*base, *ns)
		if err != nil {
			return err
		}
		time.Sleep(2 * time.Second)
		g0, err := goroutines(*pp)
		if err != nil {
			return err
		}
		peak := g0
		var opened []*watcher
		for i := range *n {
			w, err := openWatch(*base, q("version", "v1", "resource", "configmaps", "namespace", *ns, "fieldSelector", fmt.Sprintf("metadata.name=perf-cm-%d", i), "includeObject", "true", "batch", "true"))
			if err != nil {
				return err
			}
			if _, err := w.waitSnapshot(time.Minute); err != nil {
				return err
			}
			opened = append(opened, w)
		}
		var logs []*websocket.Conn
		for range *n {
			c, _, err := websocket.DefaultDialer.Dial(wsURL(*base, "/api/logs?"+q("namespace", *ns, "pod", pod, "tailLines", "10")), nil)
			if err != nil {
				return err
			}
			_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
			_, _, _ = c.ReadMessage()
			logs = append(logs, c)
		}
		if g, err := goroutines(*pp); err == nil {
			peak = g
		}
		for _, w := range opened {
			w.close()
		}
		for _, c := range logs {
			_ = c.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
			_ = c.Close()
		}
		var after int
		for range 20 { // allow up to 10s for teardown
			time.Sleep(500 * time.Millisecond)
			if after, err = goroutines(*pp); err != nil {
				return err
			}
			if after <= g0+2 {
				break
			}
		}
		verdict := "ok"
		if after > g0+2 {
			verdict = "LEAK"
		}
		fmt.Printf("| leak: %d watches + %d log streams | goroutines baseline %d | with all open %d | after close %d | %s |\n", *n, *n, g0, peak, after, verdict)
		return nil
	}
}

// coldstartCmd starts the server and times: listening, /api/resources, and
// the first SNAPSHOT of the pods table (what the UI does at launch).
func coldstartCmd(fs *flag.FlagSet) func() error {
	bin := fs.String("bin", "", "k8sman-server binary")
	runs := fs.Int("runs", 3, "runs")
	label := fs.String("label", "", "row label")
	before := fs.String("before-each", "", "shell command run before each start (e.g. clear a cache dir)")
	return func() error {
		args := fs.Args()
		var listen, res, snap durations
		for range *runs {
			if *before != "" {
				if err := exec.Command("sh", "-c", *before).Run(); err != nil {
					return err
				}
			}
			start := time.Now()
			cmd := exec.Command(*bin, args...)
			cmd.Stderr = nil
			out, err := cmd.StdoutPipe()
			if err != nil {
				return err
			}
			if err := cmd.Start(); err != nil {
				return err
			}
			sc := bufio.NewScanner(out)
			addr := ""
			for sc.Scan() {
				if a, ok := strings.CutPrefix(sc.Text(), "K8SMAN_LISTENING "); ok {
					addr = a
					break
				}
			}
			if addr == "" {
				_ = cmd.Process.Kill()
				return fmt.Errorf("server did not start")
			}
			go func() { _, _ = bufio.NewReader(out).WriteTo(nopWriter{}) }()
			listen = append(listen, time.Since(start))
			base := "http://" + addr
			if _, _, err := get(base, "/api/health"); err != nil {
				return err
			}
			if _, _, err := get(base, "/api/resources"); err != nil {
				return err
			}
			res = append(res, time.Since(start))
			w, err := openWatch(base, q("version", "v1", "resource", "pods", "namespace", "perf-load", "batch", "true"))
			if err != nil {
				return err
			}
			if _, err := w.waitSnapshot(time.Minute); err != nil {
				return err
			}
			snap = append(snap, time.Since(start))
			w.close()
			_ = cmd.Process.Signal(os.Interrupt)
			_ = cmd.Wait()
		}
		fmt.Printf("| cold start %s | listening %s ms | /api/resources %s ms | first table rows %s ms |\n", *label, ms(listen.pct(.5)), ms(res.pct(.5)), ms(snap.pct(.5)))
		return nil
	}
}

type nopWriter struct{}

func (nopWriter) Write(p []byte) (int, error) { return len(p), nil }

// ctxswitchCmd alternates between contexts: POST the switch, then load
// resources and the first pods SNAPSHOT (what the UI does).
func ctxswitchCmd(fs *flag.FlagSet) func() error {
	base := fs.String("base", "http://127.0.0.1:7574", "backend URL")
	ctxs := fs.String("contexts", "", "comma-separated contexts to alternate between")
	n := fs.Int("n", 6, "switches")
	return func() error {
		names := strings.Split(*ctxs, ",")
		var sw, total durations
		for i := range *n {
			name := names[i%len(names)]
			start := time.Now()
			body, _ := json.Marshal(map[string]string{"name": name})
			resp, err := httpc.Post(*base+"/api/contexts/current", "application/json", bytes.NewReader(body))
			if err != nil {
				return err
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return fmt.Errorf("switch: HTTP %d", resp.StatusCode)
			}
			sw = append(sw, time.Since(start))
			if _, _, err := get(*base, "/api/resources"); err != nil {
				return err
			}
			w, err := openWatch(*base, q("version", "v1", "resource", "pods", "namespace", "perf-load", "batch", "true"))
			if err != nil {
				return err
			}
			if _, err := w.waitSnapshot(time.Minute); err != nil {
				return err
			}
			w.close()
			total = append(total, time.Since(start))
		}
		fmt.Printf("| context switch | POST %s ms | to first table rows p50 %s ms (p95 %s) |\n", ms(sw.pct(.5)), ms(total.pct(.5)), ms(total.pct(.95)))
		return nil
	}
}
