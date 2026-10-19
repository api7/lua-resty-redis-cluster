-- Real Redis sockets and shared memory; only the fixture's listener is stopped.
local redis = require "resty.redis"
local cluster = require "resty.rediscluster"
local _M = {}

function _M.run(mode)
    local tls = mode ~= "plain" and mode ~= "auth" and mode ~= "wrong-auth-plain"
    local password = mode == "auth" or mode == "tls-auth"
        or mode == "wrong-auth" or mode == "wrong-auth-plain" or mode == "rotate"
    local plain_port = password and 17602 or 17600
    local tls_port = plain_port + 1
    local port = tls and tls_port or plain_port
    local control = assert(redis:new())
    control:set_timeout(2000)
    -- Keep the other listener open to restore the failed endpoint.
    assert(control:connect("127.0.0.1", tls and plain_port or tls_port,
        { ssl = not tls, ssl_verify = true, server_name = "localhost" }))
    if password then assert(control:auth("health-test-password")) end
    assert(control:ping() == "PONG", "fixture is not ready")

    local config = {
        name = "health-test",
        serv_list = {{ip = "127.0.0.1", port = port}},
        max_connection_attempts = 4,
        dict_name = "redis_cluster_slot_locks",
        auth = password and "health-test-password" or nil,
        connect_opts = {
            ssl = tls, ssl_verify = true, server_name = "localhost",
            pool = "health-test-" .. mode,
        },
    }
    if mode == "wrong-auth" or mode == "wrong-auth-plain" or mode == "rotate" then
        config.auth = "old-or-wrong-password"
    elseif mode == "wrong-name" then
        config.connect_opts.server_name = "wrong.invalid"
    end

    local listener = tls and "tls-port" or "port"
    assert(control:config("SET", listener, 0))
    local ok, failure = pcall(function()
        local instance = cluster:new(config)
        assert(not instance, "connection unexpectedly succeeded with port closed")
        local key = "health-test:127.0.0.1:" .. port
        assert((ngx.shared.redis_cluster_health:get(key) or 0) > 3,
            "business connection failure was not recorded")
        if mode == "rotate" then
            config.auth = "health-test-password"
            cluster:new(config)
        end
    end)
    -- Restore the listener even when an assertion fails.
    assert(control:config("SET", listener, port))
    control:close()
    assert(ok, failure)

    local key = "health-test:127.0.0.1:" .. port
    if mode == "wrong-auth" or mode == "wrong-auth-plain" or mode == "wrong-name" then
        local before = ngx.shared.redis_cluster_health:get(key)
        local deadline = ngx.now() + 4
        repeat
            ngx.sleep(0.05)
        until (ngx.shared.redis_cluster_health:get(key) or 0) > before
            or ngx.now() >= deadline
        assert((ngx.shared.redis_cluster_health:get(key) or 0) > before,
            "invalid credentials or certificate name incorrectly recovered")
        ngx.say("rejected")
        return
    end

    local deadline = ngx.now() + 4
    repeat
        ngx.sleep(0.05)
    until not ngx.shared.redis_cluster_health:get(key) or ngx.now() >= deadline
    assert(not ngx.shared.redis_cluster_health:get(key), "node did not recover")
    ngx.say("recovered")
end

return _M
