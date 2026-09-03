// Reference Connect server for the live interop test: connect-go over TLS,
// serving the examples/kv schema. connect-go answers the gRPC protocol on the
// same handler, so the V client must roundtrip against this exactly as it does
// against grpc-go — a second, independent implementation of the wire story.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"connectrpc.com/connect"

	pb "example.com/kvserver/kv"
	"example.com/kvserver/kv/kvconnect"
)

type server struct {
	kvconnect.UnimplementedKVHandler
	mu    sync.Mutex
	store map[string][]byte
}

func (s *server) Get(ctx context.Context, req *connect.Request[pb.GetRequest]) (*connect.Response[pb.GetResponse], error) {
	key := req.Msg.Key
	if key == "boom" {
		// unicode message exercises percent-encoding on the wire
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("bad key: 🚀 boom"))
	}
	// `code:<n>` drives the full error-code table: return code n with a
	// unicode message, matching the convention the V server uses for the
	// connect-go client's sweep in the other direction.
	if n, ok := strings.CutPrefix(key, "code:"); ok {
		v, err := strconv.Atoi(n)
		if err != nil || v < 1 || v > 16 {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("bad code %s", n))
		}
		return nil, connect.NewError(connect.Code(v), fmt.Errorf("status 🚀 %d", v))
	}
	if key == "slow" {
		// sleep past any sane client deadline so the client's timeout fires
		time.Sleep(2 * time.Second)
	}
	resp := connect.NewResponse(&pb.GetResponse{})
	// echo a request-metadata value back as response metadata, so the V
	// client can prove metadata flows both directions
	if v := req.Header().Get("x-echo"); v != "" {
		resp.Header().Set("x-echoed", v)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	val, ok := s.store[key]
	resp.Msg.Value, resp.Msg.Found = val, ok
	return resp, nil
}

func (s *server) Put(_ context.Context, req *connect.Request[pb.PutRequest]) (*connect.Response[pb.PutResponse], error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, existed := s.store[req.Msg.Key]
	s.store[req.Msg.Key] = req.Msg.Value
	return connect.NewResponse(&pb.PutResponse{Replaced: existed}), nil
}

func main() {
	addr := flag.String("addr", ":50053", "listen address")
	cert := flag.String("cert", "certs/server.crt", "TLS certificate")
	key := flag.String("key", "certs/server.key", "TLS key")
	flag.Parse()

	mux := http.NewServeMux()
	mux.Handle(kvconnect.NewKVHandler(&server{store: map[string][]byte{}}))
	// TLS with Go's default TLSNextProto negotiates h2 over ALPN, which is
	// what the V client requires to speak real gRPC
	srv := &http.Server{Addr: *addr, Handler: mux}
	fmt.Println("READY")
	if err := srv.ListenAndServeTLS(*cert, *key); err != nil {
		panic(err)
	}
}
