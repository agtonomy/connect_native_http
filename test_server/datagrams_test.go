package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
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

// An Extended CONNECT with :protocol datagram-echo gets 200, and each HTTP datagram comes back unchanged.
func TestDatagramEcho(t *testing.T) {
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

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tlsConfig := &tls.Config{RootCAs: roots, ServerName: "localhost", NextProtos: []string{http3.NextProtoH3}}
	conn, err := quic.DialAddr(ctx, udp.LocalAddr().String(), tlsConfig, &quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatal(err)
	}
	transport := &http3.Transport{EnableDatagrams: true}
	client := transport.NewClientConn(conn)
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
