# Road to grpc.v 1.0

The plan of record is [issue #1](https://github.com/we-be/grpc.v/issues/1):
four gates, in order. This file tracks where they stand against what has
shipped ([CHANGELOG.md](CHANGELOG.md)); the issue lags it.

## Scope of 1.0

Issue #1 scoped 1.0 to the unary gRPC client and the Connect unary server, with
the native server and streaming as upstream-gated follow-ups. Both landed
before 1.0 (0.3.0), so **1.0 freezes what has shipped**:

- `Client` — unary, plus buffered server- and client-streaming
- `ConnectServer` and `GrpcServer`, with `ServerContext`
- `StatusError`, the status table, `frame`
- the generated-stub shape from protobuf.v's `vpbgen -grpc` (`<Svc>Client`,
  `<Svc>Handler`, `<Svc>Service` with `call` and `grpc_call`, `Reply[T]`)

**Post-1.0, upstream-gated:** bidirectional and true incremental streaming. Both
need a `net.http` streaming-handler API V does not have. They arrive as new,
additive stub shapes; the buffered `![]Resp` / `[]Req` shapes stay as frozen.

**Non-goal for 1.0:** compression. The client sends uncompressed and rejects a
compressed response cleanly; `GrpcServer` answers an unsupported
`grpc-encoding` with `unimplemented` and `grpc-accept-encoding: identity`.
Both are spec-valid.

grpc.v stays **0.x** until Gate 4; until then the V API may break in a minor.

## Gate 1 — unary call semantics ✅

- [x] `grpc-timeout` + client-side deadlines → `deadline_exceeded` (0.2.0)
- [x] metadata both ways: `Reply.metadata` on the client, `ServerContext` on
  the server, multi-valued (0.2.0)
- [x] call options in the generated stubs, additive (protobuf.v 1.1.0)
- [x] gzip decided: a post-1.0 non-goal (above)

## Gate 2 — robustness & hardening ✅

- [x] frame-decoder fuzzing, adversarial server tests, fuzzed bodies through a
  real generated dispatch — in CI (0.2.0)
- [x] the protobuf.v bugs it found, patched upstream: the json2 bare-scalar DoS
  (protobuf.v 1.1.1), unchecked base64 in JSON bytes (protobuf.v 1.3.0)
- [x] request size limits: `max_receive_bytes` → `resource_exhausted`

## Gate 3 — conformance & interop breadth (open)

- [x] official conformance suite, Connect vs `ConnectServer`: 88/88
- [x] official conformance suite, gRPC over h2c vs `GrpcServer`: 64/64
- [x] the V client vs grpc-go and vs connect-go, the full status-code table,
  deadlines end to end, large and binary payloads
- [x] a real grpc-go client vs `GrpcServer` (unary + buffered streaming)
- [ ] the conformance and native-server interop legs on macOS. They run on
  Linux only: on macos/arm64, V's `http.Server` corrupted request bytes under
  its request loop. Re-check at each V re-pin; turn them on when it passes.

## Gate 4 — API freeze (open)

- [ ] review the 1.0 surface above for anything to rename or drop while 0.x
  still allows it; freeze it together with the stub shape in protobuf.v
  `gen/grpc.v` (a protobuf.v minor)
- [x] a scope-and-limitations section in the README (buffered streaming,
  compression, the 8 MiB request-body cap, V master requirement)
- [ ] cut **v1.0.0**, paired with that protobuf.v minor
