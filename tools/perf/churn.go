package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// kindClient builds an HTTP client from a kind-style kubeconfig (inline
// certificate data, one cluster/user). Good enough for the dev cluster; it
// avoids pulling client-go into the harness.
func kindClient(path string) (*http.Client, string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	field := func(name string) string {
		for _, l := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(strings.TrimSpace(l), name+":"); ok {
				return strings.TrimSpace(v)
			}
		}
		return ""
	}
	dec := func(name string) []byte {
		v, _ := base64.StdEncoding.DecodeString(field(name))
		return v
	}
	cert, err := tls.X509KeyPair(dec("client-certificate-data"), dec("client-key-data"))
	if err != nil {
		return nil, "", fmt.Errorf("client cert: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(dec("certificate-authority-data"))
	tr := &http.Transport{TLSClientConfig: &tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: pool}, ForceAttemptHTTP2: true}
	return &http.Client{Transport: tr, Timeout: 30 * time.Second}, field("server"), nil
}

// churnCmd patches ConfigMaps (and so emits MODIFIED events) at a fixed rate.
func churnCmd(fs *flag.FlagSet) func() error {
	kc := fs.String("kubeconfig", "", "kind kubeconfig")
	ns := fs.String("ns", "perf-load", "namespace")
	rate := fs.Int("rate", 20, "patches per second")
	dur := fs.Duration("dur", 60*time.Second, "duration")
	count := fs.Int("count", 1500, "ConfigMaps perf-cm-0..count-1")
	return func() error {
		c, server, err := kindClient(*kc)
		if err != nil {
			return err
		}
		nonce := time.Now().UnixNano() // every run changes data, so every patch is an event
		t := time.NewTicker(time.Second / time.Duration(*rate))
		defer t.Stop()
		end := time.Now().Add(*dur)
		var wg sync.WaitGroup
		sent, failed := 0, 0
		var mu sync.Mutex
		for i := 0; time.Now().Before(end); i++ {
			<-t.C
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				name := fmt.Sprintf("perf-cm-%d", i%*count)
				body := fmt.Sprintf(`{"data":{"tick":"%d-%d"}}`, nonce, i)
				req, _ := http.NewRequest(http.MethodPatch, server+"/api/v1/namespaces/"+*ns+"/configmaps/"+name, bytes.NewBufferString(body))
				req.Header.Set("Content-Type", "application/merge-patch+json")
				resp, err := c.Do(req)
				mu.Lock()
				defer mu.Unlock()
				if err != nil || resp.StatusCode >= 300 {
					failed++
				} else {
					sent++
				}
				if resp != nil {
					_, _ = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}
			}(i)
		}
		wg.Wait()
		fmt.Printf("churn: %d patches (%d failed) over %s\n", sent, failed, *dur)
		return nil
	}
}

// proxyCmd is a TCP proxy adding a fixed one-way delay of rtt/2 in each
// direction, without throttling throughput (each chunk is delivered at
// arrival+delay).
func proxyCmd(fs *flag.FlagSet) func() error {
	listen := fs.String("listen", "127.0.0.1:7590", "listen address")
	upstream := fs.String("upstream", "", "upstream host:port (the kind API server)")
	rtt := fs.Duration("rtt", 150*time.Millisecond, "added round-trip time")
	return func() error {
		ln, err := net.Listen("tcp", *listen)
		if err != nil {
			return err
		}
		fmt.Printf("latency proxy %s -> %s (+%s RTT)\n", ln.Addr(), *upstream, *rtt)
		for {
			c, err := ln.Accept()
			if err != nil {
				return err
			}
			go func() {
				u, err := net.Dial("tcp", *upstream)
				if err != nil {
					c.Close()
					return
				}
				go delayed(c, u, *rtt/2)
				delayed(u, c, *rtt/2)
			}()
		}
	}
}

type chunk struct {
	at time.Time
	b  []byte
}

func delayed(dst, src net.Conn, d time.Duration) {
	ch := make(chan chunk, 4096)
	go func() {
		defer close(ch)
		for {
			buf := make([]byte, 32*1024)
			n, err := src.Read(buf)
			if n > 0 {
				ch <- chunk{time.Now().Add(d), buf[:n]}
			}
			if err != nil {
				return
			}
		}
	}()
	for c := range ch {
		time.Sleep(time.Until(c.at))
		if _, err := dst.Write(c.b); err != nil {
			break
		}
	}
	dst.Close()
	src.Close()
}
