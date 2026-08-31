#!/usr/bin/env bash
# Refuse to run interop against stale generated code: regenerate every
# example's *_pb.v / *_grpc.v from its .proto with the current vpbgen and
# diff against what is committed. The comparison is on token streams, not
# bytes: vpbgen vfmt's its output, so a byte-exact gate holds every committed
# stub hostage to upstream formatter changes — V's v3 formatter backend
# (vlang/v#28176) re-flowed match arms and struct-field alignment and
# dropped the space in `== (b`, without changing a single token. Stripping
# whitespace keeps the gate blocking and on what it is for: the generated
# code's shape — a renamed field, changed type or new method still trips it. The interop copies under
# vclient/vserver are symlinks to examples/kv, so they cannot drift and are
# not checked here. Finds vpbgen in ~/.vmodules/protobuf (CI layout) or a
# sibling checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -d "$HOME/.vmodules/protobuf/cmd/vpbgen" ]; then
  pbgen="$HOME/.vmodules/protobuf/cmd/vpbgen"
elif [ -d "../protobuf/cmd/vpbgen" ]; then
  pbgen="../protobuf/cmd/vpbgen"
else
  echo "cannot find protobuf.v's vpbgen (checked ~/.vmodules/protobuf and ../protobuf)"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stale=0

norm() { tr -d '[:space:]' < "$1"; }

check() { # check <proto> <dir> <basename>
  v run "$pbgen" -m main -json \
    -o "$tmp/$3_pb.v" -grpc "$tmp/$3_grpc.v" "$1" >/dev/null
  for suf in pb grpc; do
    if ! diff -q <(norm "$tmp/$3_${suf}.v") <(norm "$2/$3_${suf}.v") >/dev/null; then
      echo "STALE: $2/$3_${suf}.v differs from vpbgen output"
      stale=1
    fi
  done
}

check examples/kv/kv.proto examples/kv kv
check examples/kvd/kvd.proto examples/kvd kvd
check examples/registry/registry.proto examples/registry registry

if [ "$stale" -ne 0 ]; then
  echo
  echo "regenerate with:"
  echo "  v run \$VPBGEN -m main -json -o examples/kv/kv_pb.v -grpc examples/kv/kv_grpc.v examples/kv/kv.proto"
  echo "  v run \$VPBGEN -m main -json -o examples/kvd/kvd_pb.v -grpc examples/kvd/kvd_grpc.v examples/kvd/kvd.proto"
  echo "  v run \$VPBGEN -m main -json -o examples/registry/registry_pb.v -grpc examples/registry/registry_grpc.v examples/registry/registry.proto"
  exit 1
fi
echo "generated code up to date"
