#!/usr/bin/env bash
# Live interop: the V gRPC client vs a connect-go server over TLS/h2.
# connect-go answers the gRPC protocol on the same handler, so this runs the
# identical vclient assertions as run.sh against a second, independent
# implementation of the wire story.
set -euo pipefail
cd "$(dirname "$0")"

ADDR="${ADDR:-127.0.0.1:50053}"
command -v go >/dev/null || { echo "go toolchain required"; exit 1; }

# shellcheck source=certs.sh
. ./certs.sh
ensure_certs

(cd goserver && go build -o connectserver-bin ./connectserver)

./goserver/connectserver-bin -addr "$ADDR" -cert certs/server.crt -key certs/server.key &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT

# a bare TCP probe against a TLS port makes the Go server log one benign
# "TLS handshake error ... EOF" — that line is the readiness check, not a failure
for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/${ADDR%:*}/${ADDR##*:}") 2>/dev/null; then exec 3>&-; break; fi
  sleep 0.1
done

v run vclient "https://localhost:${ADDR##*:}"
