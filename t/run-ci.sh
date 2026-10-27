#!/usr/bin/env bash
# Run the existing suites against disposable localhost Redis instances.
set -euo pipefail
export TEST_REDIS_FIXTURE_DIR="${TEST_REDIS_FIXTURE_DIR:-$PWD/t/fixtures-run}"
export TEST_REDIS_TLS_CA="$TEST_REDIS_FIXTURE_DIR/ca.crt"
REDIS_SERVER="${REDIS_SERVER:-redis-server}"
REDIS_CLI="${REDIS_CLI:-redis-cli}"
fixtures_started=false

cleanup() {
    local status=$?
    trap - EXIT
    if $fixtures_started; then bash t/redis-health-fixtures.sh stop || true; fi
    # Only terminate live background children started by this script.
    for pid in $(jobs -pr); do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for port in {7000..7005}; do
    if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
        echo "Redis Cluster port $port is already occupied" >&2
        exit 1
    fi
done
mkdir -p "$TEST_REDIS_FIXTURE_DIR"
cluster_dir=$(mktemp -d "$TEST_REDIS_FIXTURE_DIR/cluster.XXXXXX")
nodes=()
for port in {7000..7005}; do
    dir="$cluster_dir/$port"
    mkdir "$dir"
    "$REDIS_SERVER" --bind 127.0.0.1 --port "$port" \
        --cluster-enabled yes --cluster-config-file "$dir/nodes.conf" \
        --cluster-node-timeout 5000 --cluster-announce-ip 127.0.0.1 \
        --dir "$dir" --logfile "$dir/redis.log" --save "" --appendonly no &
    nodes+=("127.0.0.1:$port")
done
for port in {7000..7005}; do
    for _ in {1..100}; do
        if "$REDIS_CLI" -h 127.0.0.1 -p "$port" PING 2>/dev/null | grep -qx PONG; then break; fi
        sleep 0.1
    done
    "$REDIS_CLI" -h 127.0.0.1 -p "$port" PING | grep -qx PONG
done
timeout 60 "$REDIS_CLI" --cluster create "${nodes[@]}" --cluster-replicas 1 --cluster-yes
for port in {7000..7005}; do
    for _ in {1..100}; do
        info=$("$REDIS_CLI" -h 127.0.0.1 -p "$port" CLUSTER INFO | tr -d '\r')
        if grep -qx cluster_state:ok <<<"$info" \
            && grep -qx cluster_slots_ok:16384 <<<"$info" \
            && grep -qx cluster_known_nodes:6 <<<"$info"; then break; fi
        sleep 0.1
    done
    grep -qx cluster_state:ok <<<"$info"
    grep -qx cluster_slots_ok:16384 <<<"$info"
    grep -qx cluster_known_nodes:6 <<<"$info"
done
bash t/redis-health-fixtures.sh start
fixtures_started=true
make test "$@"
