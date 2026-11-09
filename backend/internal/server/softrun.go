package server

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"time"

	"github.com/matty234/k8sman/backend/internal/httpx"
)

// Progressive pages (Overview, Security) list many sources for one answer.
// Rather than wait for the slowest, a request answers after a soft deadline
// with what has finished and names the rest as pending; the sources keep
// running, detached from the request under a hard limit, so the page's quick
// re-fetch finds them done (and the shared watch cache warm). The pieces:
//
//   - sourceRun[In]: named sources run in parallel, each storing its result
//     into a shared In under a lock; snap copies In with the labels still
//     running; await waits for all, or the soft deadline, then (always) for
//     the one required source.
//   - runRegistry[R]: one run per key (context + scope) in flight or just
//     finished; requests attach to it instead of starting the sources again.
//   - parseSoftWait: the `wait` query parameter.

// parseSoftWait reads the `wait` query parameter (a duration), defaulting to
// def and capped at max.
func parseSoftWait(r *http.Request, def, max time.Duration) (time.Duration, error) {
	v := r.URL.Query().Get("wait")
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil || d < 0 {
		return 0, httpx.BadRequest("wait: want a duration such as 1s")
	}
	return min(d, max), nil
}

// sourceRun runs named sources in parallel and collects their results into
// one In. Sources keep running after a request has answered: each stores its
// result under mu, and snap copies In under the same lock, so a late source
// never writes into an In that is being analysed or serialised (apply funcs
// replace a field, they never modify a slice that was already stored).
type sourceRun[In any] struct {
	// Ctx is the sources' context: detached from any request, cancelled at
	// the hard limit or once every source is done.
	Ctx context.Context

	in       In
	mu       sync.Mutex
	wg       sync.WaitGroup
	errs     map[string]error
	pending  map[string]int // label -> goroutines still running
	label    func(name string) string
	required string
	// requiredDone is closed when the required source has finished.
	requiredDone chan struct{}
	hard, reuse  time.Duration
	// started, and finished once every source is done (zero until then).
	started  time.Time
	finished time.Time
}

// newSourceRun: required names the source every answer waits for (it must be
// started); label maps a source name onto the label reported as pending (nil
// = the name itself). The run is reusable for reuse after it has finished,
// and is given up hard after it started.
func newSourceRun[In any](ctx context.Context, required string, label func(string) string, hard, reuse time.Duration) *sourceRun[In] {
	if label == nil {
		label = func(n string) string { return n }
	}
	return &sourceRun[In]{Ctx: ctx, errs: map[string]error{}, pending: map[string]int{}, label: label,
		required: required, requiredDone: make(chan struct{}), hard: hard, reuse: reuse, started: time.Now()}
}

// Go runs list in the background. When it returns an apply func, that is
// called (under the lock, so it may write to the shared In) to store the
// result; an error is reported under name.
func (l *sourceRun[In]) Go(name string, list func() (apply func(in *In), err error)) {
	label := l.label(name)
	l.mu.Lock()
	l.pending[label]++
	l.mu.Unlock()
	l.wg.Add(1)
	go func() {
		defer l.wg.Done()
		apply, err := list()
		l.mu.Lock()
		defer l.mu.Unlock()
		if apply != nil {
			apply(&l.in)
		}
		if err != nil {
			l.errs[name] = fmt.Errorf("list %s: %w", name, err)
		}
		if l.pending[label]--; l.pending[label] == 0 {
			delete(l.pending, label)
		}
		if name == l.required {
			close(l.requiredDone)
		}
	}()
}

// Set changes the input right away (under the lock).
func (l *sourceRun[In]) Set(f func(in *In)) {
	l.mu.Lock()
	defer l.mu.Unlock()
	f(&l.in)
}

// sealed starts the bookkeeping that ends the run: once every source has
// finished, finished is set and cancel called. Call it after the last Go of
// the start func.
func (l *sourceRun[In]) sealed(cancel context.CancelFunc) {
	go func() {
		l.wg.Wait()
		l.mu.Lock()
		l.finished = time.Now()
		l.mu.Unlock()
		cancel()
	}()
}

// snap copies what has completed so far: the input, the sorted labels of the
// sources still running, and the errors.
func (l *sourceRun[In]) snap() (In, []string, map[string]error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	pending := make([]string, 0, len(l.pending))
	for k := range l.pending {
		pending = append(pending, k)
	}
	sort.Strings(pending)
	errs := make(map[string]error, len(l.errs))
	for k, v := range l.errs {
		errs[k] = v
	}
	return l.in, pending, errs
}

// await waits for every source up to soft, then (always) for the required
// one. It is false when reqCtx ended first.
func (l *sourceRun[In]) await(reqCtx context.Context, soft time.Duration) bool {
	all := make(chan struct{})
	go func() {
		l.wg.Wait()
		close(all)
	}()
	t := time.NewTimer(soft)
	defer t.Stop()
	select {
	case <-all:
	case <-t.C:
	case <-reqCtx.Done():
		return false
	}
	select {
	case <-l.requiredDone:
		return true
	case <-reqCtx.Done():
		return false
	}
}

// expired: finished more than reuse ago, or past the hard limit (a source
// that ignores its context never finishes).
func (l *sourceRun[In]) expired() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.finished.IsZero() {
		return time.Since(l.finished) > l.reuse
	}
	return time.Since(l.started) > l.hard+time.Second
}

// runRegistry holds the run in flight (or just finished) per key; requests
// attach to it instead of starting the same slow sources again.
type runRegistry[R interface{ expired() bool }] struct {
	mu sync.Mutex
	m  map[string]*registryEntry[R]
}

// registryEntry is one key's run; ready closes once start has returned, so
// start runs outside the map lock (a slow first start only holds up
// requests for the same key).
type registryEntry[R any] struct {
	ready chan struct{}
	run   R
}

// get returns the run for key, calling start (once per key, so only one
// request starts it) when there is none or the last one has expired.
func (o *runRegistry[R]) get(key string, start func() R) R {
	o.mu.Lock()
	if o.m == nil {
		o.m = map[string]*registryEntry[R]{}
	}
	for k, e := range o.m {
		select {
		case <-e.ready:
			if e.run.expired() {
				delete(o.m, k)
			}
		default: // still starting
		}
	}
	if e := o.m[key]; e != nil {
		o.mu.Unlock()
		<-e.ready
		return e.run
	}
	e := &registryEntry[R]{ready: make(chan struct{})}
	o.m[key] = e
	o.mu.Unlock()
	e.run = start()
	close(e.ready)
	return e.run
}
