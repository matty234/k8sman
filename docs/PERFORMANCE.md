# Performance

How fast the backend and the UI are at realistic scale, what changed in the
performance pass, and how to re-run the measurements.

**Setup.** Dev kind cluster (Kubernetes v1.25, one node, no aggregated
discovery: one discovery request per group version), on an M1 Pro laptop that
also runs Docker, the kind VM and the app. Load namespace `perf-load`: 1,500
ConfigMaps, a 300-replica pause Deployment (kind runs ~45 of them, the rest
stay Pending, so the pods table has ~370 rows and a steady stream of
FailedScheduling events), 200 custom resources, and a logging pod. The dev
cluster also holds Argo CD, Prometheus, Gateway API, Trivy and KEDA.
"+150ms RTT" runs put a TCP proxy between the backend and the API server that
adds 75ms each way. Numbers are p50 of 10 requests (5 with RTT); expect ±20%
or worse between runs on a busy laptop (the kind VM alone used 3+ cores
during some runs), so read the large ratios, not the last digit.

## Results

### Endpoint latency (ms, p50)

| | before | after | before, +150ms RTT | after, +150ms RTT |
|---|---|---|---|---|
| `/api/watch` first SNAPSHOT, 1,500 ConfigMaps | 90 | 10 | 270 | 10 |
| `/api/watch` first SNAPSHOT, pods (all ns) | 142 | 10 | 338 | 6 |
| `/api/table` ConfigMaps, table open | 81 | 15 | 311 | 4 |
| `/api/table` pods, table open | 151 | 7 | 458 | 2 |
| `/api/items` ConfigMaps, table open | 77 | 33 | 288 | 11 |
| `/api/table` ConfigMaps, nothing open (direct LIST, unchanged path) | 160 | 80–465 * | 269 | 336 |
| `/api/overview` (all ns), repeat poll | 163 | 77 | 278 | 200 ** |
| `/api/overview?namespace=perf-load` | 80 | 30 | 192 | 210 ** |
| `/api/security?namespace=perf-load` | 309 | 4 | 180 | 159 *** |
| `/api/security` (all ns) | 573 | 10 | 851 | 9 |
| `/api/resources` (cached) | 0.7 | 0.2 | 0.8 | 0.2 |
| `/api/resources?refresh=true` (full re-discovery) | 1,057 † | 799 / 217 | – | 527 |

\* Same code as before (a cold one-off read still LISTs); the spread is run-to-run noise.
\*\* Overview also asks Alertmanager for firing alerts through the API
server's service proxy: one round trip that the cache can't remove. All
Kubernetes lists in it are now served from memory.
\*\*\* The single-namespace view GETs that namespace when no namespaces watch
is open (listing all namespaces may be forbidden): one round trip.
† From the second baseline run (the row was added to the harness after the first).

"First SNAPSHOT" after includes joining an already-warm stream (another
watcher, or one closed less than 90s ago); a truly cold first watch costs one
LIST, as before (RV=0, from the API server's watch cache).

### Kubernetes connection responsiveness

| | before | after | before, +150ms RTT | after, +150ms RTT |
|---|---|---|---|---|
| Cold start → `/api/resources` (empty disk cache) | 1,150 ms | 120 ms | 2,337 ms | 500 ms |
| Cold start → `/api/resources` (warm disk cache) | n/a | 50 ms | n/a | – ‡ |
| Cold start → first table rows (pods, empty cache) | 1,322 ms | 249 ms | 2,980 ms | 1,313 ms |
| Cold start → first table rows (warm disk cache) | n/a | 166 ms | n/a | – ‡ |
| Context switch → first table rows, p50 | 100 ms | 6.5 ms | 258 ms | 25 ms |
| Context switch → first table rows, p95 (first visit) | 707 ms | 31 ms | 612 ms | 387 ms |

‡ That row didn't complete in the final RTT run; the warm-cache start skips
all discovery requests (one ~20ms disk read instead), so it saves the
discovery round trips on top of the empty-cache number.

The big cold-start win is not the disk cache but the CRD list: the backend
fetched every CRD in full (17.6 MB of JSON on the dev cluster, a quorum read
from etcd) on every start, context switch and refresh, just to learn which
resources are custom. It now lists CRDs as metadata only from the API
server's watch cache (~20ms) and fetches a CRD only when its printer columns
are needed.

### Watch fan-out (ConfigMaps, 20 patches/s for 25s)

| UI watchers | upstream watches before | after | all SNAPSHOTs before | after | frames sent before | after (same events) |
|---|---|---|---|---|---|---|
| 1 | 1 | shared (0 new) | 300 ms | 11 ms | 533 | 253 |
| 10 | 10 | shared (0 new) | 425–621 ms | 66 ms | 5,190 | 2,419 |

"0 new": the stream was already open from earlier tests; a fresh set of N
watchers opens exactly one upstream watch (covered by
`TestSharedStreamRefCountAndIdleEviction`). Frames halve because deltas in a
75ms window are batched (`BATCH`), at 20 events/s.

### Memory and CPU (backend)

| | before | after |
|---|---|---|
| Idle RSS avg / max (after the latency runs) | 43 / 119 MiB | 32 / 135 MiB |
| Live heap after the latency runs | 12 MiB (rerun) | 78 MiB |
| Live heap 100s after the last request (streams evicted) | – | 9 MiB |
| Typical use 60s: RSS avg / max | 36 / 80 MiB | 43 / 80 MiB |
| Typical use 60s: CPU | 1.4% | 0.8% |
| Typical use: Overview poll p50 | 422 ms | 78 ms |
| 10 watchers under churn: RSS avg / max | 50 / 183 MiB | 38 / 77 MiB |
| Rendering a 1,500-pod SNAPSHOT (`BenchmarkTableSnapshot`) | 38 ms, 26 MB, 267k allocs | warm: 2.3 ms, 0.7 MB, 6k allocs |

Typical use = one pods table watch (all namespaces) + the inspector's
single-object watch + the Overview poll every 10s + the alerts badge every
30s. The cache trades memory for latency: every stream holds its objects
(unstructured) while it is warm, so after visiting Overview and Security for
all namespaces the live heap is ~60-80 MiB (mostly decoded objects; on the dev
cluster Security pulls in Trivy reports and RBAC). It drops back to ~9 MiB 90s
after the pages are left. Peak RSS is set by LIST decoding, as before.
The cold rendering path (memo miss) also deep-copies each object before jq
evaluation (see below), ~20% more allocations than a plain LIST render.

### Goroutine leak check

Open 100 single-object watches and 100 log streams, then close them all:

| | baseline | all open | after close |
|---|---|---|---|
| before | 7 | 907 | 7 |
| after | 61 (warm streams) | 761 | 61 |

No leaks either way. The after baseline includes the warm shared streams from
the earlier tests (two goroutines each, evicted after 90s); the 100 watches
share one stream instead of 100 upstream watches (≈150 fewer goroutines).

### Frontend

Widget-test benchmark (`frontend/test/perf/table_perf_test.dart`; debug-mode
test VM, so absolute times are pessimistic; ranges are min–max of 3 runs):

| 1,500-row table, 200 MODIFIED events | before | after |
|---|---|---|
| Frame per single event | 23.7–26.6 ms | 4.6–5.5 ms |
| Row widgets rebuilt per event | 42 | 0.3 (only the changed row) |
| Cell widgets / Tooltips built per event | 294 / 211 | 2.3 / 0.7 |
| All widget rebuilds per event | 1,734 | 86 |
| Burst of 20 single events: frame | 20–42 ms | 11–19 ms |
| BATCH of 20 events: frame / notifies / rows rebuilt | (not supported) | 9.8–14.6 ms / 1 / 6.7 |
| Select one row: frame / rows rebuilt | 17–22 ms / 42 | 2.6–3.6 ms / 0 |
| `rows` (filter + sort) | 0.4–1.5 ms, ≥2× per frame | ~0.002 ms cached, once per change |

| Log dock, 10k lines × 3 tabs | before | after |
|---|---|---|
| Lines kept per tab (cap) | 10,000 | 10,000 (ring buffer, same cap) |
| Estimated bytes | ~3.1 MB | ~3.1 MB |
| Append + frame, 3 × 200 lines | 33–36 ms | 33–54 ms (frame-dominated, noise) |
| Flush with search + only-matching | 14–33 ms | 14–17 ms |

| Polling while a page isn't visible | before | after |
|---|---|---|
| Port-forwards view, fetches/60s: visible / offstage / app hidden | 40 / 40 / 40 | 40 / 0 / 0 (+1 on resume) |
| Nodes view, fetches/60s: visible / offstage / app hidden | 6 / 6 / 6 | 6 / 0 / 0 (+1 on resume) |
| Poll timers alive when hidden or backgrounded | one per polling widget | 0 |

Pages are disposed when you navigate away, so the polls that kept running
were the collapsed inspector's tabs, the always-mounted alerts badge, and
everything while the app was hidden or minimised.

### Frontend changes

- **Table** (`lib/state/table_controller.dart`, `lib/ui/resource_table.dart`):
  `rows` (filter + sort) is memoised and recomputed once per change; row
  widgets are cached by UID and rebuild only when their row data or
  selection changes (the 30s age ticker clears the cache); the toolbar and
  header are reused; a cell only gets a `Tooltip` when its text is over 40
  characters.
- **Watches** (`lib/api/client.dart`, `lib/api/models.dart`): `watch()`
  sends `batch=true` and applies a `BATCH` frame with a single notify (table
  and inspector); single-row frames still work with older backends.
  Reconnects use jittered exponential backoff (500ms doubling to 16s,
  random in [d/2, d]) for tables and the inspector (was a flat 2s). The
  WebSocket wrapper closes cleanly however early the subscriber cancels, and a
  malformed frame becomes a stream error.
- **Polling** (`lib/state/poller.dart`): one scheduler with one lifecycle
  observer drives Overview, alerts (page and badge), nodes, Helm,
  port-forwards, metrics status and the usage views. A poll holds a one-shot
  timer only while the app isn't hidden/paused and its subtree's
  `TickerMode` is on, refreshes immediately when it can run again, backs off
  exponentially on errors (up to 8× its interval, max 2 min) and is disposed
  with its widget. Intervals are unchanged.
- **Log dock** (`lib/state/log_buffer.dart`): lines live in a ring buffer
  with the same 10k cap; search matches update incrementally.
- **Startup**: group icons and the alerts badge's first fetch wait until the
  first table has painted (3s cap); backend icons are decoded at display size.
- Every WebSocket user (inspector, log streams, terminals) closes its socket
  on dispose; terminal scrollback stays at 10k lines (user-selectable to 50k).

## Memory

Release builds of both processes, measured with `footprint` (phys_footprint,
which unlike RSS counts compressed pages; macOS compresses an idle Go heap
heavily, so the backend's RSS can read *below* its live heap) and the Go
heap from `--pprof`.

**Setup.** Kind v1.25, one node, `make cluster` plus `dev/bulk.sh`: 917
ConfigMaps (~2 KB each), 502 Secrets, 208 Deployments, 305 Services and 168
pods (147 running pause pods), all applied with client-side `kubectl apply`
(so they carry `last-applied-configuration` and `managedFields`). The
scenario (`tools/membench/bench_scenario.dart`, driven inside the app so
nothing takes focus) opens the Pod, ConfigMap, Secret, Deployment and
Service tables for all namespaces (~2,100 objects), inspects a Deployment, a
ConfigMap, a Service and the kube-apiserver pod, opens that pod's logs
(continuously logging), a local shell and the ⌘K palette, then idles 2
minutes. Window 1728×1025 pt on a Retina display (3456×2050 px).

| | before | after |
|---|---|---|
| App, after launch | 119 MB | 126 MB |
| App, after scenario | 202 MB | 186 MB |
| App, after 2 min idle | 187 MB | 174 MB |
| App, peak | 326 MB | 405 MB |
| Backend, after launch | 33 MB | 30 MB |
| Backend, after scenario | 95 MB | 58 MB |
| Backend, after 2 min idle | 82 MB | 53 MB |
| Backend, peak | 95 MB | 68 MB |
| Backend live heap after GC, after scenario | 37.7 MiB | 17–25 MiB |
| Backend CPU time, whole run | 2.0–2.2 s | 2.1–2.8 s |

Medians of 3 runs before and 2 after (the third pair was cut short). The
app's code didn't change: its differences are run-to-run noise. Its
footprint swings by 100–200 MB within a second while frames are produced
(see below), so each point is the median of five one-second samples, and
its peak (319 MB to 1 GB across runs) is a transient.

Backend alone, with a small WebSocket client holding the five table watches
open (no app; live heap after a forced GC, footprint just before it; 2–3
alternating runs each):

| | live heap | footprint |
|---|---|---|
| baseline | 36.6 MiB | 85–86 MB |
| strip `managedFields` in the cache | 23.3 MiB | 70–84 MB (median 73) |
| + `GOGC=50` | 23.2 MiB | 56–64 MB (median 58) |

**What holds the memory.**

- *Backend:* the shared watch cache's decoded objects. `managedFields` is
  20% of the five kinds' JSON but a third of the live heap, being many
  small maps. With Go's default GOGC=100 the heap also carries as much
  garbage (LIST decoding, table rendering) as live data before collecting.
- *App:* mostly the engine, not Dart. After the scenario the Dart heap is
  ~27 MiB (VM service, profile build), ~16 MiB of it code; table rows, palette lookups and log buffers
  are a few MiB. The image cache stayed empty (0 bytes). The rest is
  graphics and malloc: two full-window IOSurfaces (27 MB each at
  3456×2050), ~30 MB of large and ~25 MB of small malloc blocks in the
  engine, and "owned unmapped" memory that the surface pool gives back
  over the following minute. During bursts of frames the macOS embedder
  allocates a fresh full-window IOSurface while WindowServer still holds
  the previous ones: up to 16 at once (~480 MB) for under a second. That,
  not app data, sets the app's peak. On the test machine an accessibility
  client was active, so the semantics tree was built (~4 MB of Dart heap
  plus its native side); most users won't pay that.

**Changes.**

- `kcache` strips `metadata.managedFields` as objects enter the cache.
- `k8sman-server` sets `GOGC=50` unless `$GOGC` is set.

**Tried and dropped.**

- Shrinking `last-applied-configuration` in the cache (to just apiVersion
  and kind, which the Security check needs): another 2.9 MiB of live heap
  even with every object kubectl-applied, but the inspector's metadata
  section would show a doctored annotation.
- `GOMEMLIMIT=64MiB` instead of GOGC: 65–66 MB, and it thrashes when a
  large cluster's live cache exceeds the limit.
- Capping the image cache: it held nothing (kind icons are glyphs; group
  icons are already decoded at display size).
- Stopping idle watches sooner: streams already stop 90s after their last
  user, which is what keeps table switching instant.

**Re-running.**

```sh
make cluster                                      # dev kind cluster, .kubeconfig-dev
KUBECONFIG=$PWD/.kubeconfig-dev dev/bulk.sh       # the bulk objects
git checkout <base> && tools/membench/build.sh before
git checkout <change> && tools/membench/build.sh after
for i in 1 2 3; do tools/membench/run.sh before $i; tools/membench/run.sh after $i; done
cat /tmp/k8sman-membench/results/*.txt
```

`run.sh` starts its own backend (`--kubeconfig .kubeconfig-dev`, `--pprof`)
and launches the app in the background with `HOME` pointed at a scratch
directory, so your settings and chosen kubeconfig are neither used nor
changed. Each run takes about four minutes.

## Tried, or considered, and not done

- **Protobuf for the typed client.** The same clientset backs raw requests
  that expect JSON (`DoRaw` against metrics.k8s.io, which metrics-server can
  answer in protobuf, and the service proxy to Prometheus/Alertmanager/Argo
  CD). With Overview/Security served from the cache, typed LIST decoding is
  off the hot path anyway.
- **Disk discovery cache alone** barely moved cold start: discovery was
  ~20ms of a ~400ms `/api/resources`; the rest was the full CRD list (now
  metadata-only, from the watch cache).
- **Raising QPS/Burst.** The baseline's slow `security?namespace=` (~310ms
  at p50, but 21-50ms at min) was client-side rate-limiter wait after
  Overview's ~15 parallel lists drained the burst. Removing the lists (cache)
  fixed it; 50/100 is kept.
- **`GOMEMLIMIT`.** Peaks come from decoding large LISTs, which a soft limit
  would only make slower (more GC during the decode), and a limit below a
  big cluster's live cache makes the GC thrash. `GOGC=50` was adopted later
  instead (see [Memory](#memory)).
- **Stripping `managedFields` from cached objects** was left out of this
  behaviour-preserving pass; the memory pass did it (see [Memory](#memory)).
- **Batching log lines** (one frame per line today) would need a protocol
  change on `/api/logs`; the log stream already applies backpressure (a slow
  client blocks the reader, nothing is buffered), so it was left alone.
- **Known difference:** analyses that keep list order (e.g. the "HTTPRoutes
  … send traffic to" finding in Security) now see items in namespace/name
  order. Before, they saw the order of an RV=0 LIST from the API server's
  watch cache, which on v1.25 is unspecified (hash order).

## How it works now

### Shared watch cache (`backend/internal/kcache`)

One upstream LIST+WATCH ("stream") per kube context, resource, namespace
and selector set, shared by every user:

- **`/api/watch`** subscribes. Ten table watchers of the same resource cost
  one upstream watch, not ten. The inspector's single-object watch
  (`fieldSelector=metadata.name=X`) and label-selector watches ride on an
  already-warm stream of the same type (same namespace or all namespaces)
  and are filtered locally; an object that stops matching a selector is
  reported as `DELETED`, like the API server does. Selectors the cache
  can't evaluate (e.g. `status.phase`, `spec.nodeName`) get their own
  upstream stream.
- **`/api/table` and `/api/items`** answer from a warm stream, else LIST
  directly (a one-off read does not start a watch).
- **`/api/overview` and `/api/security`** list through the cache: the first
  poll costs one LIST per type and starts the streams, later polls cost no
  API requests. Typed conversions (`corev1.Pod` etc.) are memoised per
  object version.
- **Lifecycle.** Streams are ref-counted; with no subscribers a stream stays
  warm for 90s (a page switch or a 10s poll keeps it), then it is stopped.
  A watch that ends normally resumes from the last resourceVersion (no
  re-list, no new SNAPSHOT; previously every ~5-10 minute watch timeout
  caused a full re-list and SNAPSHOT); 410 Gone re-lists and sends a fresh
  SNAPSHOT. Bookmarks keep the resume point current.
- **Errors keep their old semantics.** A failed LIST is sent to every
  subscriber as the same ERROR frame. `Forbidden`/`NotFound` end the stream
  (and the socket) and the stream is forgotten, so the next attempt LISTs
  again (e.g. after an RBAC fix); other errors retry with 1s..30s backoff.
- **Metadata first for heavy kinds.** Tables of the kinds in
  `kapi.MetadataFirst` (Secrets, ConfigMaps, CRDs) use a lean stream: a
  metadata-only LIST (`PartialObjectMetadataList`) is the first SNAPSHOT,
  rows marked `pending` for the cells that read more than plain metadata
  paths. A fill then pages through the full objects (50 per request, at
  most 4 fills at once, cancelled when the last watcher leaves), keeps a
  summary of each (Secrets: type, keys and value sizes; ConfigMaps: keys
  and sizes; CRDs: everything but the schemas) and sends the rows as
  MODIFIED, one batch per page. The watch starts from the fill's
  resourceVersion with full objects, summarised per event; a 410 re-list
  takes the same path. A table uses it only when its columns are
  metadata paths or the kind's built-in ones (plus plugin columns on
  Secrets, which see key names only); otherwise it watches full objects.
  Snapshot readers wait for the fill; plugin lookups of ConfigMaps and
  CRDs, the inspector and `/api/items` read full objects.
- **Trimmed objects.** `metadata.managedFields` is dropped as objects enter
  the cache (nothing reads it there; the YAML tab GETs the live object), so
  `includeObject` rows and `/api/items` answered from the cache don't
  carry it.
- **Bounded memory per client.** Each subscriber has a queue of at most
  4,096 events; a client that falls further behind gets a fresh SNAPSHOT
  instead, so a stalled UI can't grow backend memory without bound.
- **Row memo.** Rendered rows are cached per (object UID, resourceVersion,
  column set, usage values), and the row JSON is encoded once and shared
  by all watchers. Re-snapshots, extra watchers and the 15s pod/node usage
  tick re-evaluate jq only for objects that changed. gojq programs were
  already compiled once per query (global cache in `internal/columns`).
  gojq normalises numbers by writing into every map of its input, so a
  memo miss evaluates a private deep copy of the (shared) cached object;
  without it, concurrent watchers crashed the backend with "concurrent map
  read and map write" (regression test:
  `TestSharedObjectsAreNotWrittenByColumnEvaluation`).

### Watch frames

`/api/watch?batch=true` (the app always sends it) coalesces deltas from a
75ms window into one `BATCH` frame; repeated updates of one object within
the window collapse to its latest row. A lone event is still a plain
`ADDED`/`MODIFIED`/`DELETED` frame, and clients that don't pass
`batch=true` get exactly the old protocol.

### Discovery and client config

- `--cache-dir` (default `~/.cache/k8sman`, `""` = memory only): discovery is
  cached on disk per API server (like kubectl's `~/.kube/cache`), with an
  ETag HTTP cache. After a start served from disk, discovery is refreshed in
  the background; a resource not found in stale data triggers one
  synchronous re-discovery (kubectl behaviour), so a newly installed CRD
  still opens.
- The CRD set (for the `custom` flag) comes from a **metadata-only** list.
  The full CRD list was 17.6 MB of JSON on the dev cluster and was fetched
  and decoded on every start, context switch and refresh. Printer columns
  are now fetched per CRD on first use.
- Discovery and the CRD list run in parallel; the resource-type list is
  cached until `refresh=true` (it was rebuilt and re-sorted on every request
  that resolved a resource).
- Dynamic, typed and metadata clients share one HTTP client (one HTTP/2
  connection). QPS/Burst stay 50/100: with the cache, Overview/Security
  polls no longer fan out ~20 LISTs, which is what hit the client-side rate
  limiter before (security p50 ~310ms in the baseline was mostly limiter
  wait). Protobuf was not enabled for the typed client: it also backs raw
  requests (metrics.k8s.io via `DoRaw`, service proxy) that expect JSON, and
  with the cache the typed LIST decode is no longer on the hot path.

### pprof

`k8sman-server --pprof 127.0.0.1:6060` serves `net/http/pprof` on a separate
loopback-only listener (refused for non-loopback addresses). Off by default.
It is guarded like the API (loopback `Host`, bearer token; see API.md), so
fetch profiles with the token, e.g.
`curl -H "Authorization: Bearer $K8SMAN_AUTH_TOKEN" -o heap.pb.gz http://127.0.0.1:6060/debug/pprof/heap`
and then `go tool pprof heap.pb.gz`. `tools/perf/run.sh` sets the token for
the server and the harness.

## Re-running the benchmarks

```sh
# 1. load (dev kind cluster only): 1,500 ConfigMaps, 300 pause pods
#    (kind runs ~45 of them, the rest stay Pending), 200 Widget CRs, a logger pod
tools/perf/load.sh up

# 2. backend suite (builds tools/perf, starts its own server on :7574 with
#    scratch settings/columns files and a scratch kubeconfig)
(cd backend && go build -o /tmp/k8sman-server ./cmd/k8sman-server)
tools/perf/run.sh /tmp/k8sman-server after
RTT=150ms tools/perf/run.sh /tmp/k8sman-server after   # via the latency proxy
QUICK=1 N=3 tools/perf/run.sh /tmp/k8sman-server smoke # fast subset

# 3. micro-benchmark: rendering a 1,500-pod SNAPSHOT
(cd backend && go test ./internal/server -run '^$' -bench TableSnapshot -benchmem)

# 4. frontend benchmarks
(cd frontend && K8SMAN_PERF=1 flutter test test/perf/table_perf_test.dart)

# 5. clean up
tools/perf/load.sh down
```

`tools/perf` subcommands can be run on their own against any backend:
`perf latency|typical|idle|fanout|leak|coldstart|ctxswitch|churn|proxy|heap`
(see the header of `tools/perf/main.go`). `perf proxy -upstream host:port
-rtt 150ms` is a TCP proxy that delays each direction by RTT/2 without
throttling throughput; `run.sh` points a scratch kubeconfig at it when `RTT`
is set. Numbers vary ±20% between runs on a laptop (kind, the UI and other
processes share the CPU); compare runs made back to back.
