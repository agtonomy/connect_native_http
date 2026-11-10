// Command connect-native-http-test-server serves connectrpc.eliza.v1.ElizaService over HTTP/2 (TLS on TCP) and
// HTTP/3 (QUIC on UDP) for connect_native_http's integration tests. Its behavior is scripted by the request, not
// ELIZA's: see elizaServer.
//
// It creates a CA in -certdir on first start (ca.pem, ca.der, ca-key.pem), reuses it afterwards, and serves a
// fresh leaf for -hosts signed by it. Clients must trust that CA. Cronet only negotiates QUIC with certificates that
// chain to a public root, so Android reaches this server over HTTP/2 only.
//
// -max-idle and -keepalive set the server's QUIC idle timeout and ping interval. QUIC uses the smaller of the two
// endpoints' idle timeouts, so -max-idle also bounds how long a client takes to notice a dead path. -admin-addr
// serves a plain-HTTP endpoint that freezes the HTTP/3 path, or the open HTTP/2 connections (see adminHandler).
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"connectrpc.com/connect/v2"
	"connectrpc.com/connect/v2/connecthttp"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/quic-go/qlog"

	"connectnativehttp/testserver/gen/connectrpc/eliza/v1/elizav1connect"
)

func main() {
	addr := flag.String("addr", ":8443", "TCP listen address for HTTP/1.1 and HTTP/2")
	h3Addr := flag.String("h3addr", "", "UDP listen address for HTTP/3; defaults to -addr")
	noH3 := flag.Bool("no-h3", false, "serve no HTTP/3 and send no Alt-Svc, as if UDP were blocked")
	altSvc := flag.String("alt-svc", "", `Alt-Svc header on HTTP/2 responses; defaults to h3=":<h3 port>"`)
	hosts := flag.String("hosts", "localhost,127.0.0.1", "comma-separated DNS names and IPs for the leaf certificate")
	certDir := flag.String("certdir", "certs", "directory to keep the CA in")
	maxIdle := flag.Duration("max-idle", 30*time.Second, "QUIC idle timeout the server advertises")
	keepAlive := flag.Duration("keepalive", 5*time.Second, "interval between the server's QUIC pings; 0 sends none")
	adminAddr := flag.String("admin-addr", ":8081", "plain-HTTP address of the freeze endpoint; empty disables it")
	flag.Parse()
	if *h3Addr == "" {
		*h3Addr = *addr
	}
	if *altSvc == "" && !*noH3 {
		_, port, err := net.SplitHostPort(*h3Addr)
		if err != nil {
			log.Fatalf("-h3addr: %v", err)
		}
		*altSvc = fmt.Sprintf(`h3=":%s"; ma=86400`, port)
	}

	if err := os.MkdirAll(*certDir, 0o755); err != nil {
		log.Fatal(err)
	}
	cert, err := writeCertificates(*certDir, strings.Split(*hosts, ","))
	if err != nil {
		log.Fatal(err)
	}

	handler := protocolHeaders(newElizaMux(), *altSvc)
	tlsConfig := newTLSConfig(cert)
	h2 := &http.Server{Addr: *addr, Handler: handler, TLSConfig: tlsConfig, ReadHeaderTimeout: 10 * time.Second}
	tcp, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("http2: %v", err)
	}
	tcpConns := newFreezableListener(tcp)
	go func() {
		if err := h2.ServeTLS(tcpConns, "", ""); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("http2: %v", err)
		}
	}()

	var h3 *http3.Server
	var udpConn *freezablePacketConn
	if !*noH3 {
		udp, err := net.ListenPacket("udp", *h3Addr)
		if err != nil {
			log.Fatalf("http3: %v", err)
		}
		udpConn = &freezablePacketConn{PacketConn: udp}
		h3 = newHTTP3Server(handler, tlsConfig, quicConfig(*maxIdle, *keepAlive))
		go func() {
			if err := h3.Serve(udpConn); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Fatalf("http3: %v", err)
			}
		}()
	}
	if *adminAddr != "" {
		admin := &http.Server{Addr: *adminAddr, Handler: adminHandler(udpConn, tcpConns), ReadHeaderTimeout: 10 * time.Second}
		go func() {
			if err := admin.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Fatalf("admin: %v", err)
			}
		}()
	}
	log.Printf("listening: tcp %s, udp %s (h3 %t, max idle %s, keepalive %s), admin %q, Alt-Svc %q, CA in %s",
		*addr, *h3Addr, !*noH3, *maxIdle, *keepAlive, *adminAddr, *altSvc, *certDir)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = h2.Shutdown(shutdownCtx)
	if h3 != nil {
		_ = h3.Shutdown(shutdownCtx)
	}
}

// quicConfig writes a qlog trace of every connection to $QLOGDIR when it is set, which shows the server's side of a
// handshake: when each packet arrived and when it answered.
func quicConfig(maxIdle, keepAlive time.Duration) *quic.Config {
	return &quic.Config{MaxIdleTimeout: maxIdle, KeepAlivePeriod: keepAlive, Tracer: qlog.DefaultConnectionTracer}
}

func newHTTP3Server(handler http.Handler, tlsConfig *tls.Config, quicConfig *quic.Config) *http3.Server {
	return &http3.Server{
		Handler:    handler,
		TLSConfig:  http3.ConfigureTLSConfig(tlsConfig.Clone()),
		QUICConfig: quicConfig,
	}
}

func newElizaMux() *http.ServeMux {
	server := connect.NewServer()
	elizav1connect.RegisterElizaServiceHandler(server, elizaServer{})
	mux := http.NewServeMux()
	connecthttp.Mount(mux, server)
	// A 307 makes a client send the same request body again, to the path after /redirect. The body is read first:
	// answering without it resets the request stream, and the client fails on that instead of the redirect.
	mux.HandleFunc("/redirect/", func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.Copy(io.Discard, r.Body); err != nil {
			return
		}
		http.Redirect(w, r, strings.TrimPrefix(r.URL.Path, "/redirect"), http.StatusTemporaryRedirect)
	})
	return mux
}

// protocolHeaders logs each request and reports the protocol it arrived on in X-Proto, which is how tests check
// for HTTP/3 on clients that don't expose the negotiated protocol. HTTP/2 responses also advertise HTTP/3.
func protocolHeaders(next http.Handler, altSvc string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s %s from %s", r.Proto, r.Method, r.URL.Path, r.RemoteAddr)
		w.Header().Set("X-Proto", r.Proto)
		if r.ProtoMajor < 3 && altSvc != "" {
			w.Header().Set("Alt-Svc", altSvc)
		}
		next.ServeHTTP(w, r)
	})
}
