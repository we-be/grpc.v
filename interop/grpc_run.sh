#!/usr/bin/env bash
# Live interop, the reverse of run.sh: a real grpc-go client vs the V native
# GrpcServer over cleartext h2c. Requires a V toolchain with server-side HTTP/2
# response-trailer support (vlang/v#28066) — set V=/path/to/v to point at it.
set -euo pipefail
cd "$(dirname "$0")"

V="${V:-v}"
ADDR="${ADDR:-127.0.0.1:50052}"
command -v go >/dev/null || { echo "go toolchain required"; exit 1; }

# V server in native gRPC mode + the grpc-go client
"$V" -o /tmp/vgrpcserver-interop ./vserver
(cd goserver && go build -o /tmp/grpcclient-interop ./grpcclient)

/tmp/vgrpcserver-interop "$ADDR" grpc &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/${ADDR%:*}/${ADDR##*:}") 2>/dev/null; then exec 3>&-; break; fi
  sleep 0.1
done

/tmp/grpcclient-interop "$ADDR"
