package main

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync"
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

// freezableListener hands out TCP connections that Freeze can black-hole, so a test can kill the HTTP/2 path of the
// connections a client already has, as a network change that leaves both ends up would. Neither URLSession nor
// Cronet notices such a connection on its own: nothing fails, and nothing arrives.
type freezableListener struct {
	net.Listener

	mu    sync.Mutex
	conns map[*freezableConn]struct{}
}

func newFreezableListener(l net.Listener) *freezableListener {
	return &freezableListener{Listener: l, conns: map[*freezableConn]struct{}{}}
}

func (l *freezableListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	c := &freezableConn{Conn: conn, listener: l}
	l.mu.Lock()
	l.conns[c] = struct{}{}
	l.mu.Unlock()
	return c, nil
}

// Freeze black-holes every connection open now for d, then closes it: the bytes it dropped leave the connection
// unusable. Connections accepted later are unaffected, so a client that dials again gets through. A zero d closes
// the frozen connections now. It returns how many connections it froze.
func (l *freezableListener) Freeze(d time.Duration) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for c := range l.conns {
		if d <= 0 {
			if c.frozen.Load() {
				_ = c.Conn.Close()
			}
			continue
		}
		if c.frozen.CompareAndSwap(false, true) {
			n++
			time.AfterFunc(d, func() { _ = c.Conn.Close() })
		}
	}
	return n
}

type freezableConn struct {
	net.Conn
	listener *freezableListener
	frozen   atomic.Bool
}

// Read drops everything that arrives while the connection is frozen.
func (c *freezableConn) Read(p []byte) (int, error) {
	for {
		n, err := c.Conn.Read(p)
		if err != nil || !c.frozen.Load() {
			return n, err
		}
	}
}

// Write drops everything while the connection is frozen, as a dead path would.
func (c *freezableConn) Write(p []byte) (int, error) {
	if c.frozen.Load() {
		return len(p), nil
	}
	return c.Conn.Write(p)
}

func (c *freezableConn) Close() error {
	c.listener.mu.Lock()
	delete(c.listener.conns, c)
	c.listener.mu.Unlock()
	return c.Conn.Close()
}

// adminHandler lets tests on a device kill the server's network paths over plain HTTP:
//
//	POST /freeze?for=10s           drop all UDP traffic, so every HTTP/3 connection, for 10 s
//	POST /freeze?for=10s&path=tcp  black-hole the TCP connections open now (HTTP/2) for 10 s, then close them
//	POST /unfreeze                 stop dropping UDP now, and close the frozen TCP connections
//
// udp is nil when the server has no HTTP/3.
func adminHandler(udp *freezablePacketConn, tcp *freezableListener) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /freeze", func(w http.ResponseWriter, r *http.Request) {
		d, err := time.ParseDuration(r.URL.Query().Get("for"))
		if err != nil || d <= 0 {
			http.Error(w, fmt.Sprintf("for=%q: want a positive duration such as 10s", r.URL.Query().Get("for")),
				http.StatusBadRequest)
			return
		}
		switch path := r.URL.Query().Get("path"); path {
		case "", "udp":
			if udp == nil {
				http.Error(w, "no HTTP/3 path to freeze", http.StatusConflict)
				return
			}
			udp.Freeze(d)
			fmt.Fprintf(w, "udp frozen for %s\n", d)
		case "tcp":
			fmt.Fprintf(w, "%d tcp connections frozen for %s\n", tcp.Freeze(d), d)
		default:
			http.Error(w, fmt.Sprintf("path=%q: want udp or tcp", path), http.StatusBadRequest)
		}
	})
	mux.HandleFunc("POST /unfreeze", func(w http.ResponseWriter, r *http.Request) {
		if udp != nil {
			udp.Freeze(0)
		}
		tcp.Freeze(0)
		fmt.Fprintln(w, "unfrozen")
	})
	return mux
}
