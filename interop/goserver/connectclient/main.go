// connect-go client asserting against the V Connect server, once per
// codec. Distinct key prefixes keep the two runs independent.
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"

	"connectrpc.com/connect"

	pb "example.com/kvserver/kv"
	"example.com/kvserver/kv/kvconnect"
)

func die(cond bool, msg string, args ...any) {
	if cond {
		fmt.Fprintf(os.Stderr, "FAIL: "+msg+"\n", args...)
		os.Exit(1)
	}
}

func run(client kvconnect.KVClient, label string) {
	ctx := context.Background()
	key := label + "-k1"
	p1, err := client.Put(ctx, connect.NewRequest(&pb.PutRequest{Key: key, Value: []byte("hello connect")}))
	die(err != nil, "%s put1: %v", label, err)
	die(p1.Msg.Replaced, "%s put1 claimed replaced", label)
	p2, err := client.Put(ctx, connect.NewRequest(&pb.PutRequest{Key: key, Value: []byte("v2")}))
	die(err != nil, "%s put2: %v", label, err)
	die(!p2.Msg.Replaced, "%s put2 not replaced", label)
	g, err := client.Get(ctx, connect.NewRequest(&pb.GetRequest{Key: key}))
	die(err != nil, "%s get: %v", label, err)
	die(!g.Msg.Found || string(g.Msg.Value) != "v2", "%s get roundtrip: %v %q", label, g.Msg.Found, g.Msg.Value)
	miss, err := client.Get(ctx, connect.NewRequest(&pb.GetRequest{Key: "nope-" + label}))
	die(err != nil, "%s miss: %v", label, err)
	die(miss.Msg.Found, "%s missing key reported found", label)
	_, err = client.Get(ctx, connect.NewRequest(&pb.GetRequest{Key: "boom"}))
	die(err == nil, "%s boom should error", label)
	die(connect.CodeOf(err) != connect.CodeInvalidArgument, "%s boom code: %v", label, connect.CodeOf(err))
	die(!strings.Contains(err.Error(), "bad key: 🚀 boom"), "%s boom message: %v", label, err)
	fmt.Printf("connect %s codec OK\n", label)
}

func main() {
	base := os.Args[1]
	run(kvconnect.NewKVClient(http.DefaultClient, base), "proto")
	run(kvconnect.NewKVClient(http.DefaultClient, base, connect.WithProtoJSON()), "json")
}
