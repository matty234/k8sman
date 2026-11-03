// Command perf is k8sman's backend benchmark harness. It drives a running
// k8sman-server over its HTTP/WebSocket API (like the UI does) and reports
// latencies, memory/CPU and goroutine counts. See docs/PERFORMANCE.md.
//
//	perf latency   -base URL [-n 10] [-ns perf-load] [-warm]
//	perf typical   -base URL -pid PID [-dur 60s]
//	perf idle      -pid PID [-dur 30s]
//	perf fanout    -base URL -pid PID -n 10 [-kubeconfig F -context C]
//	perf leak      -base URL -pprof ADDR [-n 100] -pod P
//	perf coldstart -bin PATH [-runs 3] -- <server args>
//	perf ctxswitch -base URL -contexts a,b [-n 6]
//	perf churn     -kubeconfig F -context C [-ns perf-load] [-rate 20] [-dur 60s]
//	perf proxy     -listen ADDR -upstream ADDR [-rtt 150ms]
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	var run func() error
	switch cmd {
	case "latency":
		run = latencyCmd(fs)
	case "typical":
		run = typicalCmd(fs)
	case "idle":
		run = idleCmd(fs)
	case "fanout":
		run = fanoutCmd(fs)
	case "leak":
		run = leakCmd(fs)
	case "coldstart":
		run = coldstartCmd(fs)
	case "ctxswitch":
		run = ctxswitchCmd(fs)
	case "churn":
		run = churnCmd(fs)
	case "proxy":
		run = proxyCmd(fs)
	case "heap":
		run = heapCmd(fs)
	default:
		usage()
	}
	_ = fs.Parse(args)
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "perf:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: perf latency|typical|idle|fanout|leak|coldstart|ctxswitch|churn|proxy|heap [flags]")
	os.Exit(2)
}
