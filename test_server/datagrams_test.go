package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

// dialHTTP3 starts the test server's HTTP/3 side and connects a quic-go client to it, which advertises QUIC and HTTP
// datagram support when datagrams is set.
func dialHTTP3(t *testing.T, ctx context.Context, datagrams bool) *http3.ClientConn {
	t.Helper()
	dir := t.TempDir()
	cert, err := writeCertificates(dir, []string{"localhost", "127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	caDER, err := os.ReadFile(filepath.Join(dir, "ca.der"))
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)

	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := newHTTP3Server(newElizaMux(), newTLSConfig(cert), quicConfig(30*time.Second, 5*time.Second))
	go func() { _ = server.Serve(udp) }()
	t.Cleanup(func() { _ = server.Close() })

	tlsConfig := &tls.Config{RootCAs: roots, ServerName: "localhost", NextProtos: []string{http3.NextProtoH3}}
	conn, err := quic.DialAddr(ctx, udp.LocalAddr().String(), tlsConfig, &quic.Config{EnableDatagrams: datagrams})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.CloseWithError(0, "") })
	transport := &http3.Transport{EnableDatagrams: datagrams}
	return transport.NewClientConn(conn)
}

// An Extended CONNECT with :protocol datagram-echo gets 200, and each HTTP datagram comes back unchanged.
func TestDatagramEcho(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := dialHTTP3(t, ctx, true)
	select {
	case <-client.ReceivedSettings():
	case <-ctx.Done():
		t.Fatal("no SETTINGS from the server")
	}
	if settings := client.Settings(); !settings.EnableDatagrams || !settings.EnableExtendedConnect {
		t.Fatalf("server SETTINGS %+v: want datagrams and Extended CONNECT", settings)
	}

	stream, err := client.OpenRequestStream(ctx)
	if err != nil {
		t.Fatal(err)
	}
	req := &http.Request{
		Method: http.MethodConnect,
		Proto:  datagramEchoProtocol,
		Host:   "localhost",
		URL:    &url.URL{Scheme: "https", Host: "localhost", Path: "/datagrams/echo"},
		Header: http.Header{},
	}
	if err := stream.SendRequestHeader(req); err != nil {
		t.Fatal(err)
	}
	res, err := stream.ReadResponse()
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want 200", res.StatusCode)
	}
	for _, payload := range []string{"one", "two"} {
		if err := stream.SendDatagram([]byte(payload)); err != nil {
			t.Fatal(err)
		}
		got, err := stream.ReceiveDatagram(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != payload {
			t.Fatalf("echo %q, want %q", got, payload)
		}
	}
	if err := stream.Close(); err != nil {
		t.Fatal(err)
	}
}

// /client-settings reports whether the client advertised QUIC and HTTP datagram support.
func TestClientSettings(t *testing.T) {
	for _, datagrams := range []bool{false, true} {
		t.Run(fmt.Sprintf("datagrams=%v", datagrams), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			client := dialHTTP3(t, ctx, datagrams)
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://localhost/client-settings", nil)
			if err != nil {
				t.Fatal(err)
			}
			res, err := client.RoundTrip(req)
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			if res.StatusCode != http.StatusOK {
				t.Fatalf("status %d, want 200", res.StatusCode)
			}
			var got clientSettings
			if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
				t.Fatal(err)
			}
			want := clientSettings{H3Datagram: datagrams, QUICDatagrams: datagrams}
			if got != want {
				t.Fatalf("got %+v, want %+v", got, want)
			}
		})
	}
}
