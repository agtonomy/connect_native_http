package main

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
)

// quicConnKey holds the request's QUIC connection in its context; newHTTP3Server sets it.
type quicConnKey struct{}

func withQUICConn(ctx context.Context, conn *quic.Conn) context.Context {
	return context.WithValue(ctx, quicConnKey{}, conn)
}

// clientSettings is what clientSettingsHandler reports about the client's side of the connection.
type clientSettings struct {
	// H3Datagram is the client's SETTINGS_H3_DATAGRAM (RFC 9297).
	H3Datagram bool `json:"h3Datagram"`
	// QUICDatagrams is whether the client's QUIC transport parameters included max_datagram_frame_size (RFC 9221).
	QUICDatagrams bool `json:"quicDatagrams"`
}

// clientSettingsHandler answers an HTTP/3 request with the datagram support the client advertised, as JSON (see
// clientSettings), so tests can check what the client sent. Other protocols get 505.
func clientSettingsHandler(w http.ResponseWriter, r *http.Request) {
	settingser, ok := w.(http3.Settingser)
	conn, connOK := r.Context().Value(quicConnKey{}).(*quic.Conn)
	if !ok || !connOK {
		http.Error(w, "HTTP/3 only", http.StatusHTTPVersionNotSupported)
		return
	}
	// The client's SETTINGS travel on its control stream, which may arrive after this request.
	select {
	case <-settingser.ReceivedSettings():
	case <-r.Context().Done():
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(clientSettings{
		H3Datagram:    settingser.Settings().EnableDatagrams,
		QUICDatagrams: conn.ConnectionState().SupportsDatagrams.Remote,
	})
}
