package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

// warmUp sends one request to the server itself over each protocol it serves (HTTP/3 to udpAddr, unless it is
// empty, and HTTP/2 to tcpAddr), through loopback, and returns how long each took.
//
// It pays the first handshake's one-time costs before any test connects. On CI, the first QUIC handshakes of a
// freshly started server took 86-159 ms between the client's Initial arriving and the server's reply (2 ms once
// warm), and URLSession, which races QUIC against TCP, had already connected over TCP by then: the first calls of a
// suite went over HTTP/2.
func warmUp(cert tls.Certificate, serverName, tcpAddr, udpAddr string) (h3, h2 time.Duration, err error) {
	if len(cert.Certificate) < 2 {
		return 0, 0, errors.New("the certificate chain has no CA")
	}
	ca, err := x509.ParseCertificate(cert.Certificate[len(cert.Certificate)-1])
	if err != nil {
		return 0, 0, err
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	tlsConfig := &tls.Config{RootCAs: roots, ServerName: serverName}

	if udpAddr != "" {
		target, err := loopback(udpAddr)
		if err != nil {
			return 0, 0, err
		}
		transport := &http3.Transport{
			TLSClientConfig: tlsConfig,
			Dial: func(ctx context.Context, _ string, tlsCfg *tls.Config, cfg *quic.Config) (*quic.Conn, error) {
				return quic.DialAddrEarly(ctx, target, tlsCfg, cfg)
			},
		}
		defer transport.Close()
		if h3, err = warmUpRequest(transport, serverName, target, "HTTP/3.0"); err != nil {
			return 0, 0, err
		}
	}

	target, err := loopback(tcpAddr)
	if err != nil {
		return h3, 0, err
	}
	transport := &http.Transport{
		TLSClientConfig:   tlsConfig,
		ForceAttemptHTTP2: true,
		DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, target)
		},
	}
	defer transport.CloseIdleConnections()
	h2, err = warmUpRequest(transport, serverName, target, "HTTP/2.0")
	return h3, h2, err
}

// loopback returns addr's loopback equivalent when addr listens on all interfaces (":8443", "[::]:8443"), else addr.
func loopback(addr string) (string, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return "", err
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, port), nil
}

func warmUpRequest(transport http.RoundTripper, serverName, target, wantProto string) (time.Duration, error) {
	_, port, err := net.SplitHostPort(target)
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "https://" + net.JoinHostPort(serverName, port) + "/warm-up"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}
	start := time.Now()
	resp, err := (&http.Client{Transport: transport}).Do(req)
	if err != nil {
		return 0, fmt.Errorf("warm-up over %s: %w", wantProto, err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	elapsed := time.Since(start)
	if got := resp.Header.Get("X-Proto"); got != wantProto {
		return 0, fmt.Errorf("warm-up over %s arrived over %q", wantProto, got)
	}
	return elapsed, nil
}
