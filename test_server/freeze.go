package main

import (
	"errors"
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

// SetReadBuffer and SetWriteBuffer let quic-go size the socket's buffers, which it does through these methods when
// the conn is not a *net.UDPConn. It would otherwise keep the OS defaults, and drop datagrams that arrive in a burst.
// The conn deliberately doesn't expose SyscallConn or ReadMsgUDP: with them, quic-go reads batches straight from the
// socket, around ReadFrom and so around Freeze.
func (c *freezablePacketConn) SetReadBuffer(bytes int) error {
	if b, ok := c.PacketConn.(interface{ SetReadBuffer(int) error }); ok {
		return b.SetReadBuffer(bytes)
	}
	return errors.New("the underlying conn can't set its receive buffer")
}

func (c *freezablePacketConn) SetWriteBuffer(bytes int) error {
	if b, ok := c.PacketConn.(interface{ SetWriteBuffer(int) error }); ok {
		return b.SetWriteBuffer(bytes)
	}
	return errors.New("the underlying conn can't set its send buffer")
}

// adminHandler lets tests on a device freeze the HTTP/3 path, and see the health checks the server received, over
// plain HTTP:
//
//	POST /freeze?for=10s   drop all UDP traffic for 10 s
//	POST /unfreeze         stop dropping now
//	GET /health-checks     every health check so far, as JSON (see healthLog)
//
// TCP is never frozen, so HTTP/2 calls are unaffected.
func adminHandler(conn *freezablePacketConn, health *healthLog) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health-checks", health.serveJSON)
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
