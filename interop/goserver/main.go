// Reference gRPC server for the live interop test: grpc-go over TLS,
// serving the examples/kv schema. The V client must roundtrip against
// this to prove the wire story (ALPN h2, framing, trailers).
package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	pb "example.com/kvserver/kv"
)

type server struct {
	pb.UnimplementedKVServer
	mu    sync.Mutex
	store map[string][]byte
}

func (s *server) Get(ctx context.Context, req *pb.GetRequest) (*pb.GetResponse, error) {
	// echo a request-metadata value back as response metadata, so the V
	// client can prove metadata flows both directions
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		if vals := md.Get("x-echo"); len(vals) > 0 {
			grpc.SetHeader(ctx, metadata.Pairs("x-echoed", vals[0]))
		}
	}
	if req.Key == "boom" {
		// unicode message exercises percent-encoding on the wire
		return nil, status.Error(codes.InvalidArgument, "bad key: 🚀 boom")
	}
	if req.Key == "slow" {
		// sleep past any sane client deadline so the client's timeout fires
		time.Sleep(2 * time.Second)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.store[req.Key]
	return &pb.GetResponse{Value: v, Found: ok}, nil
}

func (s *server) Put(_ context.Context, req *pb.PutRequest) (*pb.PutResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, existed := s.store[req.Key]
	s.store[req.Key] = req.Value
	return &pb.PutResponse{Replaced: existed}, nil
}

func main() {
	addr := flag.String("addr", ":50051", "listen address")
	cert := flag.String("cert", "certs/server.crt", "TLS certificate")
	key := flag.String("key", "certs/server.key", "TLS key")
	flag.Parse()

	creds, err := credentials.NewServerTLSFromFile(*cert, *key)
	if err != nil {
		panic(err)
	}
	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		panic(err)
	}
	s := grpc.NewServer(grpc.Creds(creds))
	pb.RegisterKVServer(s, &server{store: map[string][]byte{}})
	fmt.Println("READY")
	if err := s.Serve(lis); err != nil {
		panic(err)
	}
}
