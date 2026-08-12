# grpc.v

[![CI](https://github.com/we-be/grpc.v/actions/workflows/ci.yml/badge.svg)](https://github.com/we-be/grpc.v/actions/workflows/ci.yml)

Native gRPC for V, with [Connect](https://connectrpc.com) for reach. Built on
[protobuf.v](https://github.com/we-be/protobuf.v). Write a `.proto`; `vpbgen`
generates a typed client and a server you plug a handler into. Framing, status
codes, trailers, and JSON are handled.

- **Native gRPC server**: real gRPC over HTTP/2 (TLS via ALPN, or cleartext
  h2c), status in trailers, unary + buffered streaming. Proven against live
  grpc-go.
- **gRPC client**: real gRPC over HTTP/2, proven against a live grpc-go server.
- **Connect server**: the same service over HTTP/1.1 in proto and JSON, for
  browsers, connect clients, and curl. Proven against connect-go and the
  official Connect conformance suite.
- **Generated glue**: `<Service>Client`, a `<Service>Handler`, and dispatch,
  from `vpbgen -grpc`.
- **Typed errors**: `StatusError` with a gRPC/Connect code and a decoded message.

Native HTTP/2 gRPC is the design center. Connect is a compatibility transport
(a browser `fetch` can't read h2 trailers, so it can't speak raw gRPC), not the
focus.

## Requirements

grpc.v tracks **V master**. The native server needs HTTP/2 response trailers and
h2c ([vlang/v#28066](https://github.com/vlang/v/pull/28066)), not yet in a V
release. CI builds against master. The Connect server alone builds on stable V.

## Setup

```sh
git clone https://github.com/we-be/protobuf.v ~/.vmodules/protobuf
git clone https://github.com/we-be/grpc.v ~/.vmodules/grpc
```

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

## Server

`vpbgen -grpc` emits an `EchoHandler` interface and an `EchoService` dispatch
struct. Implement it, mount it, serve:

```v
struct Handlers {}

fn (mut h Handlers) say(mut ctx grpc.ServerContext, req Msg) !Msg {
	return Msg{ text: 'you said: ${req.text}' }
}

fn main() {
	// h2c on a plain listener; set cert/cert_key for gRPC over TLS
	mut srv := grpc.GrpcServer{ addr: ':50051' }
	srv.mount(EchoService{ h: Handlers{} })
	srv.listen_and_serve()!
}
```

grpc-go, grpcurl, and connect clients reach it directly. `ctx` reads request
metadata and sets response headers, trailers, and typed error details.

## Client

```v
mut client := EchoClient{
	c: grpc.Client{
		base_url: 'https://localhost:50051'
	}
}
reply := client.say(Msg{ text: 'hello' })!
println(reply.msg.text)
```

Every call returns `grpc.Reply[T]{ msg, metadata }`. Per-call options compose:
`client.say(req, grpc.timeout(d), grpc.header(k, v))`. A non-OK RPC returns a
`grpc.StatusError`. The client speaks h2 over TLS, so use an `https://` endpoint.

## Streaming

Buffered. A server-streaming handler returns `![]Resp` (the client gets
`Reply[[]Resp]`); a client-streaming handler takes `[]Req`. Each rides one HTTP
request carrying multiple gRPC frames, so it fits finite streams and inherits
the request-body cap. Bidirectional and true incremental streaming wait on an
upstream `net.http` streaming-handler API.

## Connect (compatibility)

The same `EchoService` mounts on `grpc.ConnectServer` for HTTP/1.1 in proto and
JSON, what browsers (connect-es), connect-go, and curl use:

```v
mut srv := grpc.ConnectServer{ addr: ':8080' }
srv.mount(EchoService{ h: Handlers{} })
srv.listen_and_serve()!
```

Add `-json` to `vpbgen` for the JSON codec:

```sh
curl -X POST localhost:8080/echo.Echo/Say \
  -H 'content-type: application/json' -d '{"text":"hi"}'
```

## Stability

Pre-1.0 (**0.x**). Wire behavior (framing, trailers, Connect, status codes,
error details) is proven against grpc-go, connect-go, and the official
[Connect conformance suite](interop/conformance), and is stable. The V API is
still converging and may break in any 0.x release. See
[CHANGELOG.md](CHANGELOG.md).

## Examples

- [examples/registry](examples/registry): a native gRPC feature tour leaning on
  protobuf.v's richer schema (maps, `Timestamp`/`Duration`, `Any`, an
  `allow_alias` enum, recursion). Handler, client, and codecs all generated.
- [examples/kvd](examples/kvd): etcd-lite over
  [vlang/leveldb](https://github.com/vlang/leveldb), served via Connect for the
  curl/JSON demo. `smoke.sh` drives it with curl and restarts mid-run to prove
  on-disk persistence.

## What's proven

CI runs four live interop suites against reference implementations on every push:

| suite | what it proves |
|---|---|
| [`interop/grpc_run.sh`](interop) | a real grpc-go client vs the V `GrpcServer` over h2c (unary + server-streaming) |
| [`interop/run.sh`](interop) | the V client vs a real grpc-go server over TLS/h2 |
| [`interop/connect_run.sh`](interop) | connect-go clients vs the V `ConnectServer`, both codecs |
| [`interop/conformance`](interop/conformance) | the official Connect conformance suite (85/88) |

Generated `*_pb.v`/`*_grpc.v` are checked in;
[`interop/check_generated.sh`](interop) fails CI on drift.

## Development

```sh
v test .
interop/grpc_run.sh   # needs a go toolchain for the reference peers
```

## License

MIT
