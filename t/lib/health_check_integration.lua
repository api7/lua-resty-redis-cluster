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
    if mode == "wrong-auth" or mode == "rotate" then
        config.auth = "old-or-wrong-password"
    elseif mode == "wrong-auth-plain" then
        -- Reach PING and get Redis's false, NOAUTH response; do not fail AUTH first.
        config.auth = nil
    elseif mode == "wrong-name" then
        config.connect_opts.server_name = "wrong.invalid"
    end

    local listener = tls and "tls-port" or "port"
    local dict = ngx.shared.redis_cluster_health
    local key
    local function failure_key(excluded)
        for _, candidate in ipairs(dict:get_keys(0)) do
            if candidate ~= excluded and type(dict:get(candidate)) == "number"
                and candidate:sub(-#(":127.0.0.1:" .. port)) == ":127.0.0.1:" .. port then
                return candidate
            end
        end
        error("failure counter not found")
    end
    assert(control:config("SET", listener, 0))
    local ok, failure = pcall(function()
        local instance, err = cluster:new(config)
        assert(not instance and err, "connection unexpectedly succeeded with port closed")
        key = failure_key()
        assert((ngx.shared.redis_cluster_health:get(key) or 0) > 3,
            "business connection failure was not recorded")
        if mode == "rotate" then
            config.auth = "health-test-password"
            instance, err = cluster:new(config)
            assert(not instance and err, "rotated client unexpectedly connected to closed port")
            key = failure_key(key)
            assert((dict:get(key) or 0) > 3, "new configuration did not record its own failure")
        end
    end)
    -- Restore the listener even when an assertion fails.
    assert(control:config("SET", listener, port))
    control:close()
    assert(ok, failure)

    local rejected = mode == "wrong-auth" or mode == "wrong-auth-plain" or mode == "wrong-name"
    local before = dict:get(key)
    local deadline = ngx.now() + 4
    local complete
    repeat
        ngx.sleep(0.05)
        local failures = dict:get(key)
        complete = rejected and (failures or 0) > before or not rejected and not failures
    until complete or ngx.now() >= deadline
    assert(complete, rejected and "invalid credentials or certificate name incorrectly recovered"
        or "node did not recover")
    ngx.say(rejected and "rejected" or "recovered")
end

return _M
