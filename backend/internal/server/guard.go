package server

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/matty234/k8sman/backend/internal/httpx"
)

// AuthTokenEnv is the environment variable the desktop app uses to hand the
// backend its per-launch bearer token. The server clears it after reading so
// child processes (exec credential plugins, helm, trivy) don't inherit it.
const AuthTokenEnv = "K8SMAN_AUTH_TOKEN"

// MinTokenLength is the shortest token the server accepts.
const MinTokenLength = 32

// NewToken returns 32 random bytes, hex-encoded.
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Protect wraps h with the guards every request to a local k8sman listener
// must pass (see checkAccess). Used for the pprof listener; the API server
// applies the same checks in ServeHTTP.
func Protect(token string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if checkAccess(w, r, token) {
			h.ServeHTTP(w, r)
		}
	})
}

// checkAccess enforces, in order:
//
//  1. Host is 127.0.0.1, localhost or [::1] with the port the request
//     arrived on (DNS rebinding) → 403;
//  2. Origin, when present, is http(s)://localhost|127.0.0.1|[::1] (any
//     port) → 403 otherwise, rather than just not reflecting it;
//  3. Authorization: Bearer <token>, compared in constant time → 401.
//     CORS preflights (OPTIONS) from a local origin are answered without it.
//  4. POST/PUT/PATCH/DELETE carry Content-Type application/json (or YAML
//     where an endpoint takes YAML) → 415, so a cross-site "simple" request
//     (text/plain, form) never reaches a handler.
//
// It writes the error response and returns false when the request is refused.
func checkAccess(w http.ResponseWriter, r *http.Request, token string) bool {
	if !allowedHost(r) {
		guardErr(w, http.StatusForbidden, "Host not allowed", "ForbiddenHost")
		return false
	}
	origin := r.Header.Get("Origin")
	if origin != "" && !isLocalOrigin(origin) {
		guardErr(w, http.StatusForbidden, "Origin not allowed", "ForbiddenOrigin")
		return false
	}
	if origin != "" {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Add("Vary", "Origin")
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return false
	}
	if !validToken(r, token) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="k8sman"`)
		guardErr(w, http.StatusUnauthorized, "missing or invalid bearer token", "Unauthorized")
		return false
	}
	if mutating(r.Method) && !allowedContentType(r) {
		guardErr(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json", "UnsupportedMediaType")
		return false
	}
	return true
}

func guardErr(w http.ResponseWriter, code int, msg, reason string) {
	httpx.WriteJSON(w, code, apiError{Error: msg, Code: code, Reason: reason})
}

func validToken(r *http.Request, token string) bool {
	if len(token) < MinTokenLength {
		return false // no token configured: refuse everything
	}
	h := r.Header.Get("Authorization")
	const prefix = "bearer "
	if len(h) <= len(prefix) || !strings.EqualFold(h[:len(prefix)], prefix) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(strings.TrimSpace(h[len(prefix):])), []byte(token)) == 1
}

// allowedHost reports whether the Host header names a loopback address with
// the port of the listener the request came in on.
func allowedHost(r *http.Request) bool {
	la, ok := r.Context().Value(http.LocalAddrContextKey).(net.Addr)
	if !ok {
		return false
	}
	_, port, err := net.SplitHostPort(la.String())
	if err != nil || port == "" {
		return false
	}
	host, hport, err := net.SplitHostPort(r.Host)
	if err != nil || hport != port {
		return false
	}
	return isLoopbackName(host)
}

func isLoopbackName(host string) bool {
	switch strings.ToLower(host) {
	case "127.0.0.1", "localhost", "::1":
		return true
	}
	return false
}

// isLocalOrigin reports whether o is exactly http(s)://<loopback>[:port].
func isLocalOrigin(o string) bool {
	u, err := url.Parse(o)
	if err != nil || u.User != nil || u.Opaque != "" || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return false
	}
	if p := u.Port(); p != "" {
		if n, err := strconv.Atoi(p); err != nil || n < 1 || n > 65535 {
			return false
		}
	}
	return isLoopbackName(u.Hostname())
}

func mutating(method string) bool {
	switch method {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	}
	return false
}

// yamlBodies are the endpoints that also accept a YAML body.
var yamlBodies = map[string]bool{
	"PUT /api/object":      true,
	"POST /api/rbac/apply": true,
	"POST /api/apply":      true,
}

func allowedContentType(r *http.Request) bool {
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil {
		return false
	}
	switch mt {
	case "application/json":
		return true
	case "application/yaml", "application/x-yaml", "text/yaml":
		return yamlBodies[r.Method+" "+r.URL.Path]
	}
	return false
}
