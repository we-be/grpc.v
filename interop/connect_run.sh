#!/usr/bin/env bash
# Connect-protocol interop: connect-go clients (proto + JSON codecs) vs
# the V ConnectServer over plain HTTP/1.1.
set -euo pipefail
cd "$(dirname "$0")"

command -v go >/dev/null || { echo "go toolchain required"; exit 1; }

(cd goserver && go build -o connectclient-bin ./connectclient)
v -o vserver/vserver-bin vserver

./vserver/vserver-bin 127.0.0.1:8181 connect &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  if (exec 3<>/dev/tcp/127.0.0.1/8181) 2>/dev/null; then exec 3>&-; break; fi
  sleep 0.1
done

./goserver/connectclient-bin http://127.0.0.1:8181
echo "connect interop OK"
