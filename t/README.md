# Tests

Run from the repository root. Requirements: OpenResty,
this library's Lua dependencies, Test::Nginx, Redis 6+ built with TLS,
Bash, and the OpenSSL command-line tools.
The tests use disposable local fixtures, never a production Redis service.
In Docker, use `--init` or a subreaper such as `tini -s`
so exited daemon processes are reaped.

## Health-check regression tests

```sh
bash t/redis-health-fixtures.sh start
export TEST_REDIS_TLS_CA="$PWD/t/fixtures-run/ca.crt"
make test-health TEST_NGINX_LIB=/path/to/test-nginx/lib
bash t/redis-health-fixtures.sh stop
```

Ports 17600 through 17603 must be free. Override `REDIS_SERVER`, `REDIS_CLI`,
`TEST_REDIS_FIXTURE_DIR`, or `OPENRESTY_PREFIX` for nonstandard installations.
`TEST_REDIS_LUA_PATH` can add a Lua dependency search path.

Each case closes a dedicated Redis listener through its other listener,
causes the real cluster client's connection to fail, then reopens it.
Worker timers use real Redis sockets and `ngx.shared` to check recovery;
no privileged agent is started. The existing `init()` call is kept to check
compatibility with callers that still invoke it.
The cases cover plain TCP, TLS with server verification, password authentication,
TLS plus authentication, rejected passwords/server names, and updated credentials
while a node is unhealthy. The plain NOAUTH case reaches PING without sending
AUTH, so it checks Redis's `false, error` response. Another case starts with an
existing unhealthy counter to check that a worker can take over probing without
another business connection failure. Each case also checks that the health
shared dictionary stores numeric counters, not serialized connection settings.
These fixtures test health probes, not slot routing.
Expected connection errors are part of fault injection.

## Worker-state and interleaving tests

```sh
make test-unit
```

Redis, shared memory, and timers are simulated to exercise configuration changes
and failure-record changes during network I/O. These tests complement the real
connections above; simulated workers do not prove OS-process behavior.
They also check that workers with stale credentials give waiting workers a turn,
slow probes preserve queued turns, exited workers' wait records expire, and a
different plugin lock dictionary does not invalidate a successful probe.
Changing endpoints under the same cluster name is outside this fix.

## Full Test::Nginx suite

`make test` runs the worker-state/interleaving tests and both `t/sanity.t` and
`t/health-check.t`. In addition to the health
fixtures above, the existing sanity suite requires a disposable Redis Cluster
reachable through localhost ports 7000 onward. It performs destructive commands
such as FLUSHALL. Follow the existing suite's cluster setup before running it.
Health fixtures are serial and must not be shared between parallel test jobs.

## Continuous integration

The Test workflow runs `bash t/run-ci.sh` on pull requests to `devel` and pushes
to `devel`. It installs OpenResty, Test::Nginx, LuaCov, and TLS-capable Redis,
then runs the existing `make test` target. The runner script creates a disposable
six-node cluster on ports 7000 through 7005 and reuses the health fixtures above.
It stops its Redis processes on exit and refuses occupied cluster ports.
Run the same script locally once the dependencies are installed. Failed workflow
runs retain the test output and available Redis/nginx logs as the `test-logs` artifact.
