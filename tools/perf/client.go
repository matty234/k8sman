package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

var httpc = &http.Client{Timeout: 2 * time.Minute}

// get fetches base+path and returns the elapsed time and body size.
func get(base, path string) (time.Duration, int, error) {
	start := time.Now()
	resp, err := httpc.Get(base + path)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	n, err := io.Copy(io.Discard, resp.Body)
	d := time.Since(start)
	if err != nil {
		return d, int(n), err
	}
	if resp.StatusCode >= 300 {
		return d, int(n), fmt.Errorf("%s: HTTP %d", path, resp.StatusCode)
	}
	return d, int(n), nil
}

// frame is the subset of a /api/watch frame the harness looks at.
type frame struct {
	Type   string            `json:"type"`
	Error  string            `json:"error"`
	Events []json.RawMessage `json:"events"`
	Table  *struct {
		Rows []json.RawMessage `json:"rows"`
	} `json:"table"`
}

// watcher is one /api/watch connection counting what it receives.
type watcher struct {
	conn      *websocket.Conn
	start     time.Time
	firstSnap chan time.Duration
	frames    atomic.Int64
	events    atomic.Int64 // row deltas (a BATCH counts each event)
	bytes     atomic.Int64
	snapshots atomic.Int64
	done      chan struct{}
}

func wsURL(base, path string) string {
	return strings.Replace(base, "http", "ws", 1) + path
}

func openWatch(base, query string) (*watcher, error) {
	w := &watcher{start: time.Now(), firstSnap: make(chan time.Duration, 1), done: make(chan struct{})}
	conn, _, err := websocket.DefaultDialer.Dial(wsURL(base, "/api/watch?"+query), nil)
	if err != nil {
		return nil, err
	}
	w.conn = conn
	go func() {
		defer close(w.done)
		for {
			_, b, err := conn.ReadMessage()
			if err != nil {
				return
			}
			w.frames.Add(1)
			w.bytes.Add(int64(len(b)))
			var f frame
			if json.Unmarshal(b, &f) != nil {
				continue
			}
			switch f.Type {
			case "SNAPSHOT":
				if w.snapshots.Add(1) == 1 {
					w.firstSnap <- time.Since(w.start)
				}
			case "BATCH":
				w.events.Add(int64(len(f.Events)))
			case "ERROR":
				fmt.Printf("  watch error: %s\n", f.Error)
			default:
				w.events.Add(1)
			}
		}
	}()
	return w, nil
}

func (w *watcher) waitSnapshot(timeout time.Duration) (time.Duration, error) {
	select {
	case d := <-w.firstSnap:
		return d, nil
	case <-w.done:
		return 0, fmt.Errorf("watch closed before SNAPSHOT")
	case <-time.After(timeout):
		return 0, fmt.Errorf("no SNAPSHOT within %s", timeout)
	}
}

func (w *watcher) close() {
	_ = w.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
	_ = w.conn.Close()
	<-w.done
}

func q(kv ...string) string {
	v := url.Values{}
	for i := 0; i+1 < len(kv); i += 2 {
		if kv[i+1] != "" {
			v.Set(kv[i], kv[i+1])
		}
	}
	return v.Encode()
}

// ---- stats -----------------------------------------------------------------

type durations []time.Duration

func (d durations) pct(p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	s := append(durations(nil), d...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	i := int(float64(len(s)-1) * p)
	return s[i]
}

func ms(d time.Duration) string { return fmt.Sprintf("%.1f", float64(d.Microseconds())/1000) }

// ---- process sampling --------------------------------------------------------

// procSample is RSS (KiB) and cumulative CPU time of a process, via ps.
type procSample struct {
	at  time.Time
	rss int64
	cpu time.Duration
}

func sampleProc(pid int) (procSample, error) {
	out, err := exec.Command("ps", "-o", "rss=,time=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return procSample{}, err
	}
	f := strings.Fields(string(out))
	if len(f) < 2 {
		return procSample{}, fmt.Errorf("ps: %q", out)
	}
	rss, _ := strconv.ParseInt(f[0], 10, 64)
	return procSample{at: time.Now(), rss: rss, cpu: parseCPUTime(f[1])}, nil
}

// parseCPUTime parses ps TIME ("[[dd-]hh:]mm:ss.cc").
func parseCPUTime(s string) time.Duration {
	var total float64
	parts := strings.Split(s, ":")
	for _, p := range parts {
		v, _ := strconv.ParseFloat(p, 64)
		total = total*60 + v
	}
	return time.Duration(total * float64(time.Second))
}

// sampler records RSS/CPU every interval until stopped.
type sampler struct {
	pid     int
	samples []procSample
	stop    chan struct{}
	done    chan struct{}
}

func startSampler(pid int, every time.Duration) *sampler {
	s := &sampler{pid: pid, stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(s.done)
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			if p, err := sampleProc(pid); err == nil {
				s.samples = append(s.samples, p)
			}
			select {
			case <-s.stop:
				return
			case <-t.C:
			}
		}
	}()
	return s
}

// finish returns avg/max RSS (MiB) and average CPU% over the window.
func (s *sampler) finish() (avgRSS, maxRSS, cpuPct float64) {
	close(s.stop)
	<-s.done
	if len(s.samples) < 2 {
		return
	}
	var sum int64
	var mx int64
	for _, p := range s.samples {
		sum += p.rss
		mx = max(mx, p.rss)
	}
	first, last := s.samples[0], s.samples[len(s.samples)-1]
	wall := last.at.Sub(first.at)
	cpuPct = 100 * float64(last.cpu-first.cpu) / float64(wall)
	return float64(sum) / float64(len(s.samples)) / 1024, float64(mx) / 1024, cpuPct
}

// goroutines reads the total from /debug/pprof/goroutine?debug=1.
func goroutines(pprofAddr string) (int, error) {
	resp, err := httpc.Get("http://" + pprofAddr + "/debug/pprof/goroutine?debug=1")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	line, err := bufio.NewReader(resp.Body).ReadString('\n')
	if err != nil {
		return 0, err
	}
	// "goroutine profile: total 42"
	f := strings.Fields(line)
	return strconv.Atoi(f[len(f)-1])
}

// heapInuse reads HeapInuse (MiB) from /debug/pprof/heap?debug=1.
func heapInuse(pprofAddr string) (float64, error) {
	resp, err := httpc.Get("http://" + pprofAddr + "/debug/pprof/heap?debug=1&gc=1")
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "# HeapInuse = "); ok {
			n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
			return n / (1 << 20), err
		}
	}
	return 0, fmt.Errorf("HeapInuse not found")
}
