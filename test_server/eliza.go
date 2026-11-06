package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect/v2"

	elizav1 "connectnativehttp/testserver/gen/connectrpc/eliza/v1"
	"connectnativehttp/testserver/gen/connectrpc/eliza/v1/elizav1connect"
)

// introduceSentences is how many responses Introduce streams, introduceInterval the gap between them: long enough
// that a client which buffers the response instead of streaming it gets them all at once.
const (
	introduceSentences = 5
	introduceInterval  = 100 * time.Millisecond
)

// elizaServer answers by script, so tests can drive each behavior:
//   - Say echoes its sentence as "say: <sentence>". "error:<code>" fails with that Connect code name (for example
//     "error:failed_precondition"), and "sleep:<ms>" waits that long first, so deadlines can expire.
//   - Introduce streams introduceSentences sentences introduceInterval apart. A name of "error" fails the stream
//     with FailedPrecondition after the second one.
//   - Converse sends "hello" before reading anything, so a client that cannot receive before it finishes sending
//     never sees it in time. It then answers each sentence with "echo: <sentence>" as it arrives, and ends the
//     stream itself after "bye", while the client may still have its side open. After echoing "stall" it stops
//     reading until the call ends, so the client's request body backs up.
type elizaServer struct {
	elizav1connect.UnimplementedElizaServiceHandler
}

func (elizaServer) Say(ctx context.Context, req *elizav1.SayRequest) (*elizav1.SayResponse, error) {
	sentence := req.GetSentence()
	if name, ok := strings.CutPrefix(sentence, "error:"); ok {
		code, err := codeOf(name)
		if err != nil {
			return nil, connect.Errorf(connect.CodeInvalidArgument, "%v", err)
		}
		return nil, connect.Errorf(code, "asked to fail with %s", name)
	}
	if ms, ok := strings.CutPrefix(sentence, "sleep:"); ok {
		n, err := strconv.Atoi(ms)
		if err != nil {
			return nil, connect.Errorf(connect.CodeInvalidArgument, "%v", err)
		}
		select {
		case <-time.After(time.Duration(n) * time.Millisecond):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return &elizav1.SayResponse{Sentence: "say: " + sentence}, nil
}

func (elizaServer) Introduce(
	ctx context.Context,
	req *elizav1.IntroduceRequest,
	stream elizav1connect.ElizaServiceIntroduceServerStream,
) error {
	for i := range introduceSentences {
		if i == 2 && req.GetName() == "error" {
			return connect.NewError(connect.CodeFailedPrecondition, "asked to fail")
		}
		if i > 0 {
			select {
			case <-time.After(introduceInterval):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		if err := stream.Send(&elizav1.IntroduceResponse{Sentence: fmt.Sprintf("%s %d", req.GetName(), i)}); err != nil {
			return err
		}
	}
	return nil
}

func (elizaServer) Converse(ctx context.Context, stream elizav1connect.ElizaServiceConverseServerStream) error {
	if err := stream.Send(&elizav1.ConverseResponse{Sentence: "hello"}); err != nil {
		return err
	}
	for {
		req, err := stream.Receive()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(&elizav1.ConverseResponse{Sentence: "echo: " + req.GetSentence()}); err != nil {
			return err
		}
		switch req.GetSentence() {
		case "bye":
			return nil
		case "stall":
			<-ctx.Done()
			return ctx.Err()
		}
	}
}

func codeOf(name string) (connect.Code, error) {
	for c := connect.Code(1); c <= connect.CodeUnauthenticated; c++ {
		if c.String() == name {
			return c, nil
		}
	}
	return 0, fmt.Errorf("unknown code %q", name)
}
