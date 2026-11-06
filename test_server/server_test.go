package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect/v2"
	"connectrpc.com/connect/v2/connecthttp"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"

	elizav1 "connectnativehttp/testserver/gen/connectrpc/eliza/v1"
	"connectnativehttp/testserver/gen/connectrpc/eliza/v1/elizav1connect"
)

// protocolRecorder keeps the protocol and X-Proto of the last response it carried.
type protocolRecorder struct {
	next http.RoundTripper

	mu     sync.Mutex
	proto  string
	xProto string
}

func (p *protocolRecorder) RoundTrip(req *http.Request) (*http.Response, error) {
	res, err := p.next.RoundTrip(req)
	if err == nil {
		p.mu.Lock()
		p.proto, p.xProto = res.Proto, res.Header.Get("X-Proto")
		p.mu.Unlock()
	}
	return res, err
}

func (p *protocolRecorder) last() (string, string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.proto, p.xProto
}

// startHTTP3 serves the eliza handler over HTTP/3 only, on a free loopback UDP port, with the server's default QUIC
// settings, and returns a client for it.
func startHTTP3(t *testing.T) (elizav1connect.ElizaServiceClient, *protocolRecorder) {
	t.Helper()
	client, recorder, _ := startHTTP3With(t, quicConfig(30*time.Second, 5*time.Second), nil)
	return client, recorder
}

// startHTTP3With is startHTTP3 with the server's and the client's QUIC settings (nil for quic-go's defaults), also
// returning the server's socket so a test can freeze the path.
func startHTTP3With(
	t *testing.T,
	serverQUIC, clientQUIC *quic.Config,
) (elizav1connect.ElizaServiceClient, *protocolRecorder, *freezablePacketConn) {
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
	conn := &freezablePacketConn{PacketConn: udp}
	server := newHTTP3Server(protocolHeaders(newElizaMux(), `h3=":1"`), newTLSConfig(cert), serverQUIC)
	go func() { _ = server.Serve(conn) }()
	t.Cleanup(func() { _ = server.Close() })

	transport := &http3.Transport{TLSClientConfig: &tls.Config{RootCAs: roots}, QUICConfig: clientQUIC}
	t.Cleanup(func() { _ = transport.Close() })
	recorder := &protocolRecorder{next: transport}
	baseURL := "https://" + udp.LocalAddr().String()
	client := connect.NewClient(connecthttp.NewTransport(&http.Client{Transport: recorder}, baseURL))
	return elizav1connect.NewElizaServiceClient(client), recorder, conn
}

// openQuietConverse opens a Converse stream and reads the server's greeting, after which nothing flows on it until
// the test sends.
func openQuietConverse(t *testing.T, client elizav1connect.ElizaServiceClient) elizav1connect.ElizaServiceConverseClientStream {
	t.Helper()
	stream, err := client.Converse(timeoutContext(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stream.Close() })
	if err := stream.SendHeaders(); err != nil {
		t.Fatal(err)
	}
	if res, err := stream.Receive(); err != nil || res.GetSentence() != "hello" {
		t.Fatalf("greeting = %v, %v", res, err)
	}
	return stream
}

// The idle tests use a 1 s idle timeout. QUIC applies the smaller of the two endpoints' values, but a client may
// raise the peer's: quic-go's client treats anything under 5 s as 5 s (protocol.MinRemoteIdleTimeout). The server
// enforces its own value regardless, which is what the first two tests rely on.
const testMaxIdle = time.Second

func TestServerPingsKeepQuietStreamAlive(t *testing.T) {
	client, _, _ := startHTTP3With(t, quicConfig(testMaxIdle, 300*time.Millisecond), nil)
	stream := openQuietConverse(t, client)
	time.Sleep(3 * testMaxIdle)
	if err := stream.Send(&elizav1.ConverseRequest{Sentence: "still there"}); err != nil {
		t.Fatal(err)
	}
	if res, err := stream.Receive(); err != nil || res.GetSentence() != "echo: still there" {
		t.Fatalf("after %v of quiet: %v, %v", 3*testMaxIdle, res, err)
	}
}

func TestQuietStreamWithoutPingsHitsServerIdleTimeout(t *testing.T) {
	// Without pings, the idle timeout ends a quiet connection. This is what makes the previous test meaningful.
	client, _, _ := startHTTP3With(t, quicConfig(testMaxIdle, 0), nil)
	stream := openQuietConverse(t, client)
	time.Sleep(3 * testMaxIdle)
	_ = stream.Send(&elizav1.ConverseRequest{Sentence: "still there"})
	if res, err := stream.Receive(); err == nil {
		t.Fatalf("stream survived %v of quiet with a %v idle timeout and no pings: %v", 3*testMaxIdle, testMaxIdle, res)
	}
}

func TestFrozenPathFailsOpenStreamWithinIdleTimeout(t *testing.T) {
	// The client's own idle timeout is what notices a dead path, so it gets the short value too.
	client, _, conn := startHTTP3With(
		t,
		quicConfig(testMaxIdle, 300*time.Millisecond),
		&quic.Config{MaxIdleTimeout: testMaxIdle},
	)
	stream := openQuietConverse(t, client)
	conn.Freeze(time.Minute)
	t.Cleanup(func() { conn.Freeze(0) })

	start := time.Now()
	_, err := stream.Receive()
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("Receive succeeded on a frozen path")
	}
	// The client's idle timer runs out about testMaxIdle after the last packet it received; allow scheduling slack.
	if elapsed > 3*testMaxIdle {
		t.Errorf("stream failed after %v, want within about %v: %v", elapsed, testMaxIdle, err)
	}
}

func TestAdminFreezeAndUnfreeze(t *testing.T) {
	conn := &freezablePacketConn{}
	handler := adminHandler(conn)
	post := func(target string) int {
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(http.MethodPost, target, nil))
		return w.Code
	}
	if code := post("/freeze?for=1h"); code != http.StatusOK || !conn.frozen() {
		t.Fatalf("freeze: status %d, frozen %t", code, conn.frozen())
	}
	if code := post("/unfreeze"); code != http.StatusOK || conn.frozen() {
		t.Fatalf("unfreeze: status %d, frozen %t", code, conn.frozen())
	}
	if code := post("/freeze?for=nonsense"); code != http.StatusBadRequest || conn.frozen() {
		t.Fatalf("bad duration: status %d, frozen %t", code, conn.frozen())
	}
}

func timeoutContext(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestSayOverHTTP3(t *testing.T) {
	client, recorder := startHTTP3(t)
	res, err := client.Say(timeoutContext(t), &elizav1.SayRequest{Sentence: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if got := res.GetSentence(); got != "say: hi" {
		t.Errorf("sentence = %q, want %q", got, "say: hi")
	}
	proto, xProto := recorder.last()
	if proto != "HTTP/3.0" || xProto != "HTTP/3.0" {
		t.Errorf("response proto %q, X-Proto %q; want HTTP/3.0 for both", proto, xProto)
	}
}

func TestSayErrorCode(t *testing.T) {
	client, _ := startHTTP3(t)
	_, err := client.Say(timeoutContext(t), &elizav1.SayRequest{Sentence: "error:failed_precondition"})
	if got := connect.CodeOf(err); got != connect.CodeFailedPrecondition {
		t.Errorf("code = %v (%v), want failed_precondition", got, err)
	}
}

func TestSaySleepHonorsDeadline(t *testing.T) {
	client, _ := startHTTP3(t)
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := client.Say(ctx, &elizav1.SayRequest{Sentence: "sleep:5000"})
	if got := connect.CodeOf(err); got != connect.CodeDeadlineExceeded {
		t.Errorf("code = %v (%v), want deadline_exceeded", got, err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("call took %v, want it to end near the 200ms deadline", elapsed)
	}
}

func TestIntroduceStreamsIncrementally(t *testing.T) {
	client, _ := startHTTP3(t)
	stream, err := client.Introduce(timeoutContext(t), &elizav1.IntroduceRequest{Name: "ann"})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	var arrivals []time.Time
	for {
		res, err := stream.Receive()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if want := "ann " + string(rune('0'+len(arrivals))); res.GetSentence() != want {
			t.Errorf("sentence %d = %q, want %q", len(arrivals), res.GetSentence(), want)
		}
		arrivals = append(arrivals, time.Now())
	}
	if len(arrivals) != introduceSentences {
		t.Fatalf("got %d sentences, want %d", len(arrivals), introduceSentences)
	}
	// Buffered delivery would put every sentence within a few ms of the first.
	if spread := arrivals[len(arrivals)-1].Sub(arrivals[0]); spread < introduceInterval*(introduceSentences-2) {
		t.Errorf("sentences arrived within %v, want them spread over about %v", spread, introduceInterval*4)
	}
}

func TestIntroduceErrorEndsStream(t *testing.T) {
	client, _ := startHTTP3(t)
	stream, err := client.Introduce(timeoutContext(t), &elizav1.IntroduceRequest{Name: "error"})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	received := 0
	for {
		_, err := stream.Receive()
		if err != nil {
			if got := connect.CodeOf(err); got != connect.CodeFailedPrecondition {
				t.Errorf("code = %v (%v), want failed_precondition", got, err)
			}
			break
		}
		received++
	}
	if received != 2 {
		t.Errorf("received %d sentences before the error, want 2", received)
	}
}

func TestConverseIsFullDuplex(t *testing.T) {
	client, _ := startHTTP3(t)
	stream, err := client.Converse(timeoutContext(t))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err := stream.SendHeaders(); err != nil {
		t.Fatal(err)
	}
	// The server speaks first, before the client has sent a message.
	res, err := stream.Receive()
	if err != nil {
		t.Fatal(err)
	}
	if res.GetSentence() != "hello" {
		t.Errorf("first sentence = %q, want hello", res.GetSentence())
	}
	for _, sentence := range []string{"one", "two"} {
		if err := stream.Send(&elizav1.ConverseRequest{Sentence: sentence}); err != nil {
			t.Fatal(err)
		}
		res, err := stream.Receive()
		if err != nil {
			t.Fatal(err)
		}
		if want := "echo: " + sentence; res.GetSentence() != want {
			t.Errorf("reply = %q, want %q", res.GetSentence(), want)
		}
	}
	// "bye" makes the server end the stream while the client's side is still open.
	if err := stream.Send(&elizav1.ConverseRequest{Sentence: "bye"}); err != nil {
		t.Fatal(err)
	}
	if res, err := stream.Receive(); err != nil || res.GetSentence() != "echo: bye" {
		t.Fatalf("reply to bye = %v, %v", res, err)
	}
	if _, err := stream.Receive(); !errors.Is(err, io.EOF) {
		t.Errorf("after bye, Receive = %v, want io.EOF", err)
	}
}

func TestConverseStallStopsAnswering(t *testing.T) {
	client, _ := startHTTP3(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	stream, err := client.Converse(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err := stream.SendHeaders(); err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Receive(); err != nil {
		t.Fatal(err)
	}
	if err := stream.Send(&elizav1.ConverseRequest{Sentence: "stall"}); err != nil {
		t.Fatal(err)
	}
	if res, err := stream.Receive(); err != nil || res.GetSentence() != "echo: stall" {
		t.Fatalf("reply to stall = %v, %v", res, err)
	}
	if err := stream.Send(&elizav1.ConverseRequest{Sentence: "one"}); err != nil {
		t.Fatal(err)
	}
	if res, err := stream.Receive(); err == nil {
		t.Errorf("after stall, received %q", res.GetSentence())
	}
}

func TestRedirectKeepsThePathAfterIt(t *testing.T) {
	w := httptest.NewRecorder()
	newElizaMux().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/redirect/connectrpc.eliza.v1.ElizaService/Say", nil))
	if w.Code != http.StatusTemporaryRedirect {
		t.Errorf("status = %d, want 307", w.Code)
	}
	if got, want := w.Header().Get("Location"), "/connectrpc.eliza.v1.ElizaService/Say"; got != want {
		t.Errorf("Location = %q, want %q", got, want)
	}
}

func TestAltSvcOnlyOnTCPResponses(t *testing.T) {
	handler := protocolHeaders(http.NotFoundHandler(), `h3=":8443"`)
	for _, tc := range []struct {
		major      int
		wantAltSvc string
	}{
		{2, `h3=":8443"`},
		{3, ""},
	} {
		req := httptest.NewRequest(http.MethodPost, "/", nil)
		req.ProtoMajor = tc.major
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if got := w.Header().Get("Alt-Svc"); got != tc.wantAltSvc {
			t.Errorf("HTTP/%d: Alt-Svc = %q, want %q", tc.major, got, tc.wantAltSvc)
		}
	}
}
