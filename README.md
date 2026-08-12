# grpc.v

[![CI](https://github.com/we-be/grpc.v/actions/workflows/ci.yml/badge.svg)](https://github.com/we-be/grpc.v/actions/workflows/ci.yml)

Native gRPC — and [Connect](https://connectrpc.com) for reach — for V, built on
[protobuf.v](https://github.com/we-be/protobuf.v). Write a `.proto`, and
`vpbgen` generates a typed client and a server you plug a handler into; the wire
format, framing, status codes, trailers, and JSON are all handled.

- **Native gRPC server** — real gRPC over HTTP/2 (TLS via ALPN, or cleartext
  h2c), the terminal status in HTTP/2 trailers, unary + buffered streaming.
  Proven against a live [grpc-go](https://github.com/grpc/grpc-go) client.
- **gRPC client** — real gRPC over HTTP/2, proven against a live grpc-go server.
- **Connect server** — the *same* service over HTTP/1.1 in the proto *and* JSON
  codecs, for browsers, connect clients, and curl that can't speak raw gRPC.
  Proven against connect-go and the official Connect conformance suite.
- **Generated glue** — `<Service>Client`, a `<Service>Handler` interface, and
  dispatch, from `vpbgen -grpc`.
- **Typed errors** — `StatusError` carrying a gRPC/Connect code and a
  percent-decoded message.

grpc.v is **native-HTTP/2-gRPC-first**: real gRPC is the design center, and the
library doubles as a proving ground for what a V *stdlib* gRPC could look like.
Connect is kept as a compatibility transport — a browser `fetch` can't read h2
trailers, so it can't speak raw gRPC — not as the focus.

## Requirements

grpc.v tracks **V master**. The native gRPC server uses server-side HTTP/2
response trailers and cleartext h2c
([vlang/v#28066](https://github.com/vlang/v/pull/28066)), which aren't in the
0.5.2 release yet — CI builds against master, and so should you until a V
release carries it. (The Connect server alone also builds on stable V.)

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
struct. Implement the interface once, mount it on the native gRPC server:

```v
struct Handlers {}

fn (mut h Handlers) say(mut ctx grpc.ServerContext, req Msg) !Msg {
	return Msg{ text: 'you said: ${req.text}' }
}

fn main() {
	// h2c on a plain listener; set cert/cert_key to serve gRPC over TLS (ALPN h2)
	mut srv := grpc.GrpcServer{ addr: ':50051' }
	srv.mount(EchoService{ h: Handlers{} })
	srv.listen_and_serve()!
}
```

grpc-go, grpcurl, and connect clients all reach it directly. `ctx` reads request
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

Every call returns `grpc.Reply[T]{ msg, metadata }`; per-call options layer on
(`client.say(req, grpc.timeout(d), grpc.header(k, v))`). A non-OK RPC returns a
`grpc.StatusError` — `match err { grpc.StatusError { err.status.code } … }`. The
client speaks h2 over TLS (ALPN), so point it at an `https://` endpoint.

## Streaming

Buffered server- and client-streaming: a server-streaming rpc's handler returns
`![]Resp` and the client method returns `Reply[[]Resp]`; a client-streaming
handler takes `[]Req` and the client method takes `[]Req`. Each rides one HTTP
request, carrying multiple gRPC frames in the body — so it fits finite streams
and inherits the server's request-body cap. True incremental delivery and
**bidirectional** streaming wait on an upstream `net.http` streaming-handler API.

## Connect — the compatibility transport

The same `EchoService` mounts on `grpc.ConnectServer` to serve the
[Connect protocol](https://connectrpc.com) over HTTP/1.1 in proto *and* JSON —
what browsers (connect-es), connect-go, and plain curl use:

```v
mut srv := grpc.ConnectServer{ addr: ':8080' }
srv.mount(EchoService{ h: Handlers{} })
srv.listen_and_serve()!
```

Add `-json` to the `vpbgen` call and the server handles the JSON codec too:

```sh
curl -X POST localhost:8080/echo.Echo/Say \
  -H 'content-type: application/json' -d '{"text":"hi"}'
```

## Stability

Pre-1.0 (**0.x**). The **wire behavior** — gRPC framing, HTTP/2 trailers, the
Connect protocol, status codes, and error details — is proven against grpc-go,
connect-go, and the official [Connect conformance suite](interop/conformance),
and is not expected to change. The **V API** is still converging and may break
in any 0.x release; 1.0 waits for the native gRPC server API to settle against
real-world use now that it exists. See [CHANGELOG.md](CHANGELOG.md).

## kvd — the dogfood

[examples/kvd](examples/kvd) is an etcd-lite:
[vlang/leveldb](https://github.com/vlang/leveldb) storage behind a generated
API (Get/Put/Delete/Range). `smoke.sh` drives it with curl over the JSON codec
and restarts mid-run to prove the data survives on disk — the first networked KV
service in the V ecosystem.

```sh
git clone https://github.com/vlang/leveldb ~/.vmodules/leveldb
v run examples/kvd    # then POST to localhost:8181/kvd.KVD/Put …
```

## registry — a feature tour

[examples/registry](examples/registry) leans on protobuf.v's richer schema
features in one place: a consul/etcd-flavored tree of nodes carrying labels
(`map<string,string>`), a `google.protobuf.Timestamp` and
`google.protobuf.Duration`, an opaque `google.protobuf.Any`, a health status (an
`allow_alias` enum), `children` (recursion) and the `leader` among them
(singular recursion, generated as `?&Node`). Handler, client, and both codecs
are all generated; `registry_test.v` roundtrips it on the wire and in protojson.

## What's proven, and how

CI runs four live interop suites against reference implementations on every push
— the credibility argument for a from-scratch gRPC stack:

| suite | what it proves |
|---|---|
| [`interop/run.sh`](interop) | the V client vs a real grpc-go server over TLS/HTTP-2 — roundtrips, byte payloads, error statuses with percent-encoded unicode messages |
| [`interop/grpc_run.sh`](interop) | a real grpc-go client vs the V `GrpcServer` over h2c — unary + server-streaming, Trailers-Only errors, leading/trailing metadata |
| [`interop/connect_run.sh`](interop) | connect-go clients vs the V `ConnectServer`, both proto and JSON codecs |
| [`interop/conformance`](interop/conformance) | the official Connect conformance suite against `ConnectServer` (85/88, gaps enumerated) |

`examples/kvd/smoke.sh` adds a full-stack check (curl → Connect → leveldb →
disk, across a restart). Generated `*_pb.v`/`*_grpc.v` are checked in, and
[`interop/check_generated.sh`](interop) fails CI if they drift from `vpbgen`.

## Development

```sh
v test .            # unit tests
interop/grpc_run.sh # needs a go toolchain for the reference peers
```

## License

MIT
