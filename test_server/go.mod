module connectnativehttp/testserver

go 1.26.2

require (
	connectrpc.com/connect/v2 v2.0.1
	connectrpc.com/grpchealth/v2 v2.0.0
	github.com/quic-go/quic-go v0.65.0
	google.golang.org/protobuf v1.36.12
)

require (
	github.com/quic-go/qpack v0.6.0 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/net v0.56.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
)

tool connectrpc.com/connect/v2/cmd/protoc-gen-connect-go
