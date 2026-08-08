# grpc

gRPC for V, built on [protobuf.v](https://github.com/we-be/protobuf.v).

Working unary client. Wire framing, status codes (with `StatusError` and
percent-encoded `grpc-message` handling), `Client.unary` over stdlib
HTTP/2, and generated client stubs via protobuf.v's `vpbgen -grpc`
(see [examples/kv](examples/kv)).

## Transport reality (V master, 2026-08)

V's stdlib gained HTTP/2 (client + server) in June 2026. What that means here:

- **Client**: real gRPC is feasible today. The h2 client negotiates via ALPN
  over TLS and surfaces response trailers (where `grpc-status` lives) into
  `resp.header` when the stream ends.
- **Server**: blocked upstream. `http.Response` has no way to send trailers,
  and the h2 listener is TLS/ALPN-only (no h2c) — so a native gRPC server
  needs stdlib work first. Until then the server side speaks the
  [Connect protocol](https://connectrpc.com) (unary RPC over plain HTTP POST),
  which interops with the gRPC ecosystem via connect-go/Envoy.

## Roadmap

1. ~~Message framing + status codes~~
2. ~~`service`/`rpc` parsing and stub codegen (`vpbgen -grpc`)~~
3. ~~Unary gRPC client over stdlib HTTP/2 (TLS)~~
4. ~~Integration test against a real gRPC server (Go)~~ — `interop/run.sh` runs the V client's assertions against grpc-go over TLS/h2: unary roundtrips, byte payloads, and error statuses with percent-encoded unicode messages all pass
5. Connect-protocol unary server on the stdlib HTTP/1.1 server
6. Upstream V: response trailers + h2c, then a native gRPC server + streaming

## Development

```sh
ln -s "$PWD" ~/.vmodules/grpc
v test .
```
