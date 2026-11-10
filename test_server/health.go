package main

import (
	"encoding/json"
	"net/http"
	"sync"

	"connectrpc.com/grpchealth/v2"
)

// healthCheckPath is the procedure connect_native_http's keepalive calls.
const healthCheckPath = "/" + grpchealth.HealthV1ServiceName + "/Check"

// healthLog records each health check the server receives: its protocol, and the client's address, which identifies
// the connection it came on. The integration tests read it through the admin endpoint to see that a client's
// keepalives arrived on the same connection as the call they keep busy.
type healthLog struct {
	mu      sync.Mutex
	entries []healthLogEntry
}

type healthLogEntry struct {
	Proto      string `json:"proto"`
	RemoteAddr string `json:"remoteAddr"`
}

// record wraps next, logging each request for healthCheckPath before passing it on.
func (l *healthLog) record(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == healthCheckPath {
			l.mu.Lock()
			l.entries = append(l.entries, healthLogEntry{Proto: r.Proto, RemoteAddr: r.RemoteAddr})
			l.mu.Unlock()
		}
		next.ServeHTTP(w, r)
	})
}

// serveJSON answers with every check logged so far, oldest first.
func (l *healthLog) serveJSON(w http.ResponseWriter, _ *http.Request) {
	l.mu.Lock()
	entries := append([]healthLogEntry{}, l.entries...)
	l.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(entries)
}
