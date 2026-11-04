package main

import (
	"log"
	"net"
	"net/http"
	"net/http/pprof"

	"github.com/matty234/k8sman/backend/internal/server"
)

// startPprof serves the runtime profiler on its own loopback-only listener,
// so it is never reachable through the API port. It is guarded like the API
// (loopback Host, local Origin, bearer token), e.g.
// `curl -H "Authorization: Bearer $TOKEN" -o heap.pb.gz http://127.0.0.1:6060/debug/pprof/heap`
// then `go tool pprof heap.pb.gz`.
func startPprof(addr, token string) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		log.Fatalf("pprof: %v", err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		log.Fatalf("pprof: %q is not a loopback address", addr)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("pprof: %v", err)
	}
	log.Printf("pprof on http://%s/debug/pprof/", ln.Addr())
	go func() { _ = http.Serve(ln, server.Protect(token, mux)) }()
}
