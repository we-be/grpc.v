#!/usr/bin/env bash
# End-to-end smoke over the JSON codec with plain curl, including a
# restart to prove leveldb persistence. Keys/values are base64 (bytes
# fields): aGk~"hi", d29ybGQ~"world", eA~"x".
set -euo pipefail
cd "$(dirname "$0")"

data="$(mktemp -d)/db"
bin="$(mktemp -d)/kvd"
v -o "$bin" . >/dev/null

start() {
  "$bin" "$data" 127.0.0.1:8391 &
  SRV=$!
  for _ in $(seq 1 50); do
    if (exec 3<>/dev/tcp/127.0.0.1/8391) 2>/dev/null; then exec 3>&-; break; fi
    sleep 0.1
  done
}
call() { # call <Method> <json>
  curl -sS -X POST "http://127.0.0.1:8391/kvd.KVD/$1" \
    -H 'content-type: application/json' -d "$2"
}
expect() { # expect <got> <substring> <label>
  case "$1" in
    *"$2"*) ;;
    *) echo "FAIL $3: got $1, want $2"; kill $SRV; exit 1;;
  esac
}

start
trap 'kill $SRV 2>/dev/null || true' EXIT

expect "$(call Put '{"key":"aGk=","value":"d29ybGQ="}')" '{}' "first put"
expect "$(call Put '{"key":"aGk=","value":"eA=="}')" '"replaced":true' "second put"
expect "$(call Get '{"key":"aGk="}')" '"value":"eA==","found":true' "get"
expect "$(call Get '{"key":"bm8="}')" '{}' "miss"
expect "$(call Put '{"key":"YQ==","value":"MQ=="}')" '{}' "put a"
expect "$(call Put '{"key":"Yg==","value":"Mg=="}')" '{}' "put b"
expect "$(call Range '{"limit":2}')" '"more":true' "range limit"
expect "$(call Range '{"start":"YQ==","end":"Yg=="}')" '"key":"YQ=="' "range window"
expect "$(call Delete '{"key":"YQ=="}')" '"existed":true' "delete"
expect "$(call Get '{"key":"YQ=="}')" '{}' "deleted gone"
expect "$(call Put '{"key":""}')" '"code":"invalid_argument"' "empty key refused"

# restart: values must come back off disk
kill $SRV
wait $SRV 2>/dev/null || true
start
expect "$(call Get '{"key":"aGk="}')" '"value":"eA==","found":true' "get after restart"

echo "kvd smoke OK (incl. persistence across restart)"
