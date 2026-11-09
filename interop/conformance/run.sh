#!/usr/bin/env bash
# The official Connect conformance suite (connectrpc.com/conformance), run
# twice: against the V ConnectServer as Connect / unary / HTTP1 / no-TLS
# (config.yaml), and against the native GrpcServer as gRPC / unary / h2c
# (config_grpc.yaml). Regenerates the ConformanceService stubs from the
# vendored protos (so codegen is exercised too), builds the one server-under-
# test that serves whichever protocol the runner asks for, and drives the
# runner. Documented gaps live in known_failing.txt and known_failing_grpc.txt
# — the runner REQUIRES those to fail, so a gap we quietly fix trips CI until
# we delete its line.
set -euo pipefail
cd "$(dirname "$0")"

command -v go >/dev/null || { echo "go toolchain required"; exit 1; }

# vpbgen from ~/.vmodules/protobuf (CI layout) or a sibling checkout
if [ -d "$HOME/.vmodules/protobuf/cmd/vpbgen" ]; then
  pbgen="$HOME/.vmodules/protobuf/cmd/vpbgen"
elif [ -d "../../../protobuf/cmd/vpbgen" ]; then
  pbgen="../../../protobuf/cmd/vpbgen"
else
  echo "cannot find protobuf.v's vpbgen (checked ~/.vmodules/protobuf and ../../../protobuf)"
  exit 1
fi

# messages from the package-scoped entry (short, dedup'd names); service glue
# from service.proto (the ConformanceService lives there, streaming skipped)
v run "$pbgen" -m main -json -I proto -o conformance_pb.v proto/harness_entry.proto >/dev/null
v run "$pbgen" -m main -json -I proto -grpc conformance_grpc.v \
  proto/connectrpc/conformance/v1/service.proto >/dev/null

v -o /tmp/conf-harness .

GOBIN="$PWD/.bin" go install connectrpc.com/conformance/cmd/connectconformance@v1.0.5
./.bin/connectconformance --mode server --conf config.yaml \
  --known-failing @known_failing.txt -- /tmp/conf-harness
echo "Connect conformance OK"

# -p 1: V's HTTP/2 server advertises SETTINGS_MAX_CONCURRENT_STREAMS = 1 and
# refuses every stream past it, and at the runner's default parallelism Go's
# HTTP/2 transport still lands a few concurrent POSTs on one connection. A
# refused POST whose body is already written cannot be retried, so those RPCs
# come back unavailable on the client side (4 of 64, measured) with nothing
# wrong in the gRPC exchange. One RPC at a time keeps the gate about gRPC.
./.bin/connectconformance --mode server --conf config_grpc.yaml -p 1 \
  --known-failing @known_failing_grpc.txt -- /tmp/conf-harness
echo "gRPC conformance OK"
