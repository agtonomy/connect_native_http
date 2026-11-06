package main

import (
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"time"
)

// freezablePacketConn drops every datagram in both directions while frozen, which looks to both QUIC endpoints like
// a network path that went dead without either side closing anything.
type freezablePacketConn struct {
	net.PacketConn
	frozenUntil atomic.Int64 // Unix nanoseconds; zero when not frozen.
}

func (c *freezablePacketConn) frozen() bool {
	return time.Now().UnixNano() < c.frozenUntil.Load()
}

// Freeze drops all traffic for d. A zero d unfreezes.
func (c *freezablePacketConn) Freeze(d time.Duration) {
	if d <= 0 {
		c.frozenUntil.Store(0)
		return
	}
	c.frozenUntil.Store(time.Now().Add(d).UnixNano())
}

func (c *freezablePacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		n, addr, err := c.PacketConn.ReadFrom(p)
		if err != nil || !c.frozen() {
			return n, addr, err
		}
	}
}

func (c *freezablePacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	if c.frozen() {
		return len(p), nil
	}
	return c.PacketConn.WriteTo(p, addr)
}

// adminHandler lets tests on a device freeze the HTTP/3 path over plain HTTP:
//
//	POST /freeze?for=10s   drop all UDP traffic for 10 s
//	POST /unfreeze         stop dropping now
//
// TCP is never frozen, so HTTP/2 calls are unaffected.
func adminHandler(conn *freezablePacketConn) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /freeze", func(w http.ResponseWriter, r *http.Request) {
		d, err := time.ParseDuration(r.URL.Query().Get("for"))
		if err != nil || d <= 0 {
			http.Error(w, fmt.Sprintf("for=%q: want a positive duration such as 10s", r.URL.Query().Get("for")),
				http.StatusBadRequest)
			return
		}
		conn.Freeze(d)
		fmt.Fprintf(w, "frozen for %s\n", d)
	})
	mux.HandleFunc("POST /unfreeze", func(w http.ResponseWriter, r *http.Request) {
		conn.Freeze(0)
		fmt.Fprintln(w, "unfrozen")
	})
	return mux
}
