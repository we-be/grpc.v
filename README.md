# grpc.v

[![CI](https://github.com/we-be/grpc.v/actions/workflows/ci.yml/badge.svg)](https://github.com/we-be/grpc.v/actions/workflows/ci.yml)

gRPC and [Connect](https://connectrpc.com) for V, built on
[protobuf.v](https://github.com/we-be/protobuf.v). Write a `.proto`, and
`vpbgen` generates a typed client and a server you plug a handler into  - 
the wire format, framing, status codes, and JSON are all handled.

- **gRPC client** - real gRPC over HTTP/2 (ALPN + TLS + trailers), proven
  against a live [grpc-go](https://github.com/grpc/grpc-go) server
- **Connect server** - unary RPC over HTTP/1.1 in the proto *and* JSON
  codecs, proven against live [connect-go](https://connectrpc.com) clients
- **Generated glue** - `<Service>Client`, a `<Service>Handler` interface,
  and dispatch, from `vpbgen -grpc`
- **Typed errors** - `StatusError` carrying a gRPC/Connect code and a
  percent-decoded message

The catch, stated up front: a *native gRPC server* isn't possible yet  - 
V's stdlib can't send HTTP/2 trailers or speak cleartext h2, both of which
gRPC servers need. Until that lands upstream, the server side speaks
Connect, which the gRPC ecosystem reaches via connect-go, connect-es,
browsers, or an Envoy bridge. The client speaks true gRPC today.

## Setup

```sh
git clone https://github.com/we-be/protobuf.v ~/.vmodules/protobuf
git clone https://github.com/we-be/grpc.v ~/.vmodules/grpc
```

## Client

```proto
// echo.proto
syntax = "proto3";
package echo;
message Msg { string text = 1; }
service Echo { rpc Say (Msg) returns (Msg); }
```

```sh
v run ~/.vmodules/protobuf/cmd/vpbgen -m main -o echo_pb.v -grpc echo_grpc.v echo.proto
```

```v
mut client := EchoClient{
	c: grpc.Client{
		base_url: 'https://localhost:50051'
	}
}
reply := client.say(Msg{ text: 'hello' })!
println(reply.text)
```

A non-OK RPC returns a `grpc.StatusError` - `match err { grpc.StatusError { err.status.code } … }`.

## Server

`vpbgen -grpc` also emits an `EchoHandler` interface and an `EchoService`
dispatch struct. Implement the interface, mount it, serve:

```v
struct Handlers {}

fn (mut h Handlers) say(req Msg) !Msg {
	return Msg{ text: 'you said: ${req.text}' }
}

fn main() {
	mut srv := grpc.ConnectServer{ addr: ':8080' }
	srv.mount(EchoService{ h: Handlers{} })
	srv.listen_and_serve()!
}
```

Add `-json` to the vpbgen call and the server handles both the proto and
JSON codecs; a connect-go/connect-es client or plain curl can call it:

```sh
curl -X POST localhost:8080/echo.Echo/Say \
  -H 'content-type: application/json' -d '{"text":"hi"}'
```

## kvd - the dogfood

[examples/kvd](examples/kvd) is an etcd-lite:
[vlang/leveldb](https://github.com/vlang/leveldb) storage behind a Connect
API (Get/Put/Delete/Range), everything between generated. `smoke.sh`
drives it with curl over the JSON codec and restarts mid-run to prove the
data survives on disk - the first networked KV service in the V ecosystem.

```sh
git clone https://github.com/vlang/leveldb ~/.vmodules/leveldb
v run examples/kvd    # then POST to localhost:8181/kvd.KVD/Put …
```

## registry - a feature tour

[examples/registry](examples/registry) is a smaller Connect service that
leans on protobuf.v's richer schema features in one place: a
consul/etcd-flavored tree of nodes where each node carries labels
(`map<string,string>`), a `google.protobuf.Timestamp` and
`google.protobuf.Duration`, an opaque `google.protobuf.Any` payload, a
health status (an `allow_alias` enum), its `children` (recursion) and the
`leader` among them (singular recursion, generated as `?&Node`). The
handler, client, and both codecs are all generated; `registry_test.v`
roundtrips it on the wire and in protojson and drives it through the
generated dispatch.

## What's proven, and how

CI runs three live interop suites against reference implementations on
every push - this is the credibility argument for a from-scratch gRPC
stack:

| suite | what it proves |
|---|---|
| [`interop/run.sh`](interop) | the V client vs a real grpc-go server over TLS/HTTP-2 - roundtrips, byte payloads, and error statuses with percent-encoded unicode messages |
| [`interop/connect_run.sh`](interop) | connect-go clients vs the V `ConnectServer`, both proto and JSON codecs |
| [`examples/kvd/smoke.sh`](examples/kvd) | the full stack - curl → Connect → leveldb → disk, across a restart |

Generated `*_pb.v`/`*_grpc.v` are checked into the repo and
[`interop/check_generated.sh`](interop) fails CI if they drift from what
`vpbgen` currently emits.

## Transport detail

V's stdlib gained HTTP/2 (client and server) in June 2026. The client side
negotiates h2 via ALPN over TLS and surfaces response trailers - where
`grpc-status` lives - into `resp.header` when the stream ends, which is
what makes real gRPC reachable. The server side is Connect-only because
`http.Response` cannot emit trailers and there's no h2c listener; both are
tracked upstream and are the gate to a native gRPC server with streaming.

## Development

```sh
v test .            # unit tests
interop/run.sh      # needs a go toolchain for the reference peers
```

## License

MIT
