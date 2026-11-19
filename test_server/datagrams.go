package main

import (
	"context"
	"errors"
	"io"
	"log"
	"net/http"

	"github.com/quic-go/quic-go/http3"
)

// datagramEchoProtocol is the `:protocol` of the Extended CONNECT (RFC 9220) request that opens a datagram echo
// session.
const datagramEchoProtocol = "datagram-echo"

// datagramEcho serves Extended CONNECT requests with `:protocol` datagram-echo over HTTP/3: it accepts the request
// with 200 and sends back every HTTP datagram (RFC 9297) the client sends on the request stream, unchanged. The
// session ends when the client finishes or resets the request stream.
//
// A datagram whose payload is "close" ends the session from the server's side instead, by closing the stream.
func datagramEcho(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect || r.Proto != datagramEchoProtocol {
		http.Error(w, "want Extended CONNECT with :protocol "+datagramEchoProtocol, http.StatusBadRequest)
		return
	}
	streamer, ok := w.(http3.HTTPStreamer)
	if !ok {
		http.Error(w, "HTTP/3 only", http.StatusHTTPVersionNotSupported)
		return
	}
	w.WriteHeader(http.StatusOK)
	stream, err := streamer.HTTPStream()
	if err != nil {
		log.Printf("datagram echo: take over stream: %v", err)
		return
	}
	defer stream.Close()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	// The client ends the session by finishing or resetting its side of the stream.
	go func() {
		defer cancel()
		_, _ = io.Copy(io.Discard, stream)
	}()
	for {
		payload, err := stream.ReceiveDatagram(ctx)
		if err != nil {
			if !errors.Is(err, context.Canceled) {
				log.Printf("datagram echo: receive: %v", err)
			}
			return
		}
		if string(payload) == "close" {
			return
		}
		if err := stream.SendDatagram(payload); err != nil {
			log.Printf("datagram echo: send: %v", err)
			return
		}
	}
}
