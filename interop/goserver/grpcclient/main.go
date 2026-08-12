// A real grpc-go client that drives the V native GrpcServer over cleartext
// h2c, asserting the full unary surface: success with a body, Trailers-Only
// errors, a unicode (percent-encoded) grpc-message, the status-code table, and
// leading vs trailing response metadata. Mirror of what vclient asserts against
// grpc-go, run the other direction.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	kv "example.com/kvserver/kv"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func fail(what string, err error) {
	fmt.Fprintf(os.Stderr, "FAIL %s: %v\n", what, err)
	os.Exit(1)
}

func first(md metadata.MD, key string) string {
	v := md.Get(key)
	if len(v) == 0 {
		return ""
	}
	return v[0]
}

func main() {
	addr := "127.0.0.1:50052"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fail("dial", err)
	}
	defer conn.Close()
	c := kv.NewKVClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// put a new key -> replaced=false
	pr, err := c.Put(ctx, &kv.PutRequest{Key: "hello", Value: []byte("world")})
	if err != nil {
		fail("put", err)
	}
	if pr.Replaced {
		fail("put", fmt.Errorf("expected replaced=false on first put"))
	}

	// get it back -> found, value round-trips (success with a body frame)
	gr, err := c.Get(ctx, &kv.GetRequest{Key: "hello"})
	if err != nil {
		fail("get", err)
	}
	if !gr.Found || string(gr.Value) != "world" {
		fail("get", fmt.Errorf("got found=%v value=%q", gr.Found, gr.Value))
	}

	// missing key -> found=false, still OK status
	gm, err := c.Get(ctx, &kv.GetRequest{Key: "nope"})
	if err != nil {
		fail("get-missing", err)
	}
	if gm.Found {
		fail("get-missing", fmt.Errorf("expected found=false"))
	}

	// error path -> Trailers-Only InvalidArgument, unicode grpc-message
	_, err = c.Get(ctx, &kv.GetRequest{Key: "boom"})
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.InvalidArgument {
		fail("boom-code", fmt.Errorf("want InvalidArgument, got %v", err))
	}
	if st.Message() != "bad key: 🚀 boom" {
		fail("boom-msg", fmt.Errorf("grpc-message did not round-trip: %q", st.Message()))
	}

	// status-code table -> code:5 maps to NotFound
	_, err = c.Get(ctx, &kv.GetRequest{Key: "code:5"})
	st2, _ := status.FromError(err)
	if st2.Code() != codes.NotFound {
		fail("code:5", fmt.Errorf("want NotFound, got %v", st2.Code()))
	}

	// metadata echo -> leading header AND trailer both survive
	ctxm := metadata.AppendToOutgoingContext(ctx, "x-echo", "ping")
	var hdr, trl metadata.MD
	_, err = c.Get(ctxm, &kv.GetRequest{Key: "hello"}, grpc.Header(&hdr), grpc.Trailer(&trl))
	if err != nil {
		fail("echo-get", err)
	}
	if first(hdr, "x-echo-response") != "ping" {
		fail("echo-header", fmt.Errorf("leading metadata lost: %v", hdr))
	}
	if first(trl, "x-echo-trailer") != "ping" {
		fail("echo-trailer", fmt.Errorf("trailing metadata lost: %v", trl))
	}

	// server-streaming: put a few prefixed keys, then Scan reads them back as
	// a real gRPC stream (N framed messages + trailers)
	for _, k := range []string{"k1", "k2", "k3"} {
		if _, err := c.Put(ctx, &kv.PutRequest{Key: k, Value: []byte("v-" + k)}); err != nil {
			fail("scan-setup", err)
		}
	}
	sc, err := c.Scan(ctx, &kv.GetRequest{Key: "k"})
	if err != nil {
		fail("scan", err)
	}
	var vals []string
	for {
		resp, err := sc.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			fail("scan-recv", err)
		}
		vals = append(vals, string(resp.Value))
	}
	if len(vals) != 3 || vals[0] != "v-k1" || vals[2] != "v-k3" {
		fail("scan-stream", fmt.Errorf("expected [v-k1 v-k2 v-k3], got %v", vals))
	}

	// client-streaming: Send several PutRequests, then CloseAndRecv the count
	ps, err := c.PutMany(ctx)
	if err != nil {
		fail("putmany", err)
	}
	for _, k := range []string{"c1", "c2", "c3", "c4"} {
		if err := ps.Send(&kv.PutRequest{Key: k, Value: []byte("s-" + k)}); err != nil {
			fail("putmany-send", err)
		}
	}
	pmr, err := ps.CloseAndRecv()
	if err != nil {
		fail("putmany-recv", err)
	}
	if pmr.Written != 4 {
		fail("putmany-count", fmt.Errorf("expected written=4, got %d", pmr.Written))
	}

	fmt.Println("GRPC-GO -> V GrpcServer INTEROP OK (unary + server-streaming + client-streaming)")
}
