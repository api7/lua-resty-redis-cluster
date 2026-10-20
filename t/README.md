# Tests

Run from the repository root. Requirements: OpenResty with privileged-agent
support, this library's Lua dependencies, Test::Nginx, Redis 6+ built with TLS,
Bash, and the OpenSSL command-line tools.
The tests use disposable local fixtures, never a production Redis service.
Run Nginx with permission to start a privileged agent. In Docker, use `--init`
or a subreaper such as `tini -s` so exited daemon processes are reaped.

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
The privileged agent uses real Redis sockets and `ngx.shared` to check recovery.
The cases cover plain TCP, TLS with server verification, password authentication,
TLS plus authentication, rejected passwords/server names, and updated credentials
while a node is unhealthy. The plain NOAUTH case reaches PING without sending
AUTH, so it checks Redis's `false, error` response. These fixtures test health
probes, not slot routing.
Expected connection errors are part of fault injection.

## Allocation and interleaving tests

```sh
make test-unit
```

This uses real `cjson.safe`, with Redis, shared memory, and the digest simulated
to inject allocation failures and changes during network I/O. It covers late
failures from older clients, endpoint/credential isolation, caller mutations,
and expiry of unused configuration. Real digest generation is exercised by the
OpenResty tests. It complements the real
connection tests and does not claim to exercise OS-process concurrency.
Set `LUA_PATH`/`LUA_CPATH` if your LuaJIT does not find OpenResty's modules.

## Full Test::Nginx suite

`make test` runs the allocation/interleaving tests and both `t/sanity.t` and
`t/health-check.t`. In addition to the health
fixtures above, the existing sanity suite requires a disposable Redis Cluster
reachable through localhost ports 7000 onward. It performs destructive commands
such as FLUSHALL. Follow the existing suite's cluster setup before running it.
Health fixtures are serial and must not be shared between parallel test jobs.

No trial license, deployment token, private environment configuration, or captured
cloud-host log is needed for these library regression tests.
