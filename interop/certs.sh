# Shared by the TLS interop suites: a self-signed localhost cert, generated
# once and gitignored. Sourced, not executed.
ensure_certs() {
  [ -f certs/server.crt ] && return
  mkdir -p certs
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout certs/server.key -out certs/server.crt \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
  echo "generated certs/server.{crt,key}"
}
