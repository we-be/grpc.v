#!/usr/bin/env bash
# The official Connect conformance suite (connectrpc.com/conformance) run
# against the V ConnectServer. Regenerates the ConformanceService stubs from
# the vendored protos (so codegen is exercised too), builds the server-under-
# test, and drives the official runner constrained to Connect / unary / HTTP1
# / no-TLS (config.yaml). Documented gaps live in known_failing.txt — the
# runner REQUIRES those to fail, so a gap we quietly fix trips CI until we
# delete its line.
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
echo "conformance OK"
