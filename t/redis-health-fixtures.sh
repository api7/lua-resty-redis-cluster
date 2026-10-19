#!/usr/bin/env bash
# Dedicated local fixtures; never point these tests at a shared Redis service.
set -euo pipefail
ROOT="${TEST_REDIS_FIXTURE_DIR:-$PWD/t/fixtures-run}"
REDIS_SERVER="${REDIS_SERVER:-redis-server}"
REDIS_CLI="${REDIS_CLI:-redis-cli}"
if [[ "${1:-}" == stop ]]; then
    for port in 17600 17602; do
        args=()
        if [[ $port == 17602 ]]; then args=(-a health-test-password --no-auth-warning); fi
        [[ -f "$ROOT/$port.run-id" ]] || continue
        current=$("$REDIS_CLI" -h 127.0.0.1 -p "$port" "${args[@]}" INFO server | tr -d '\r' | sed -n 's/^run_id://p')
        if [[ -n "$current" && "$current" == "$(cat "$ROOT/$port.run-id")" ]]; then
            "$REDIS_CLI" -h 127.0.0.1 -p "$port" "${args[@]}" SHUTDOWN NOSAVE
        else
            echo "Refusing to stop an unrecognized Redis process on $port" >&2
        fi
    done
    exit
fi
[[ "${1:-}" == start ]] || { echo "Usage: $0 start|stop" >&2; exit 2; }
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)
for port in 17600 17601 17602 17603; do
    if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
        echo "Fixture port $port is already occupied" >&2
        exit 1
    fi
done
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=redis-health-test-ca \
    -keyout "$ROOT/ca.key" -out "$ROOT/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
    -keyout "$ROOT/server.key" -out "$ROOT/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n' > "$ROOT/server.ext"
openssl x509 -req -days 2 -in "$ROOT/server.csr" -CA "$ROOT/ca.crt" \
    -CAkey "$ROOT/ca.key" -CAcreateserial -extfile "$ROOT/server.ext" \
    -out "$ROOT/server.crt" >/dev/null 2>&1
chmod 600 "$ROOT"/*.key
for port in 17600 17602; do
    cat > "$ROOT/$port.conf" <<EOF
bind 127.0.0.1
protected-mode yes
port $port
tls-port $((port + 1))
tls-cert-file $ROOT/server.crt
tls-key-file $ROOT/server.key
tls-ca-cert-file $ROOT/ca.crt
tls-auth-clients no
daemonize yes
pidfile $ROOT/$port.pid
logfile $ROOT/$port.log
save ""
appendonly no
EOF
    if [[ $port == 17602 ]]; then echo 'requirepass health-test-password' >> "$ROOT/$port.conf"; fi
    "$REDIS_SERVER" "$ROOT/$port.conf"
    args=()
    if [[ $port == 17602 ]]; then args=(-a health-test-password --no-auth-warning); fi
    run_id=""
    for attempt in $(seq 1 50); do
        if run_id=$("$REDIS_CLI" -h 127.0.0.1 -p "$port" "${args[@]}" INFO server 2>/dev/null | tr -d '\r' | sed -n 's/^run_id://p') && [[ -n "$run_id" ]]; then
            break
        fi
        sleep 0.1
    done
    [[ -n "$run_id" ]] || { echo "Fixture failed to start on $port" >&2; exit 1; }
    printf '%s\n' "$run_id" > "$ROOT/$port.run-id"
done
echo "Fixtures started. Set TEST_REDIS_TLS_CA=$ROOT/ca.crt"
