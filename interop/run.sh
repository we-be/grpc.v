#!/usr/bin/env bash
# Live interop: V unary client vs a real grpc-go server over TLS/h2.
#   1. self-signed localhost cert (generated once, gitignored)
#   2. build + start the Go server
#   3. run the V client's assertions against it
set -euo pipefail
cd "$(dirname "$0")"

command -v go >/dev/null || { echo "go toolchain required"; exit 1; }

if [ ! -f certs/server.crt ]; then
  mkdir -p certs
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout certs/server.key -out certs/server.crt \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
  echo "generated certs/server.{crt,key}"
fi

(cd goserver && go build -o kvserver .)

./goserver/kvserver -addr 127.0.0.1:50051 -cert certs/server.crt -key certs/server.key &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  if (exec 3<>/dev/tcp/127.0.0.1/50051) 2>/dev/null; then exec 3>&-; break; fi
  sleep 0.1
done

v run vclient https://localhost:50051
