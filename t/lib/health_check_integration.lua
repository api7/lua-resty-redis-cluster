-- Real Redis sockets and shared memory; only the fixture's listener is stopped.
local redis = require "resty.redis"
local cluster = require "resty.rediscluster"
local _M = {}

function _M.run(mode)
    local tls = mode ~= "plain" and mode ~= "auth" and mode ~= "wrong-auth-plain"
    local password = mode == "auth" or mode == "tls-auth"
        or mode == "wrong-auth" or mode == "wrong-auth-plain" or mode == "rotate"
        or mode == "takeover"
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
    local function failure_key()
        local opts = config.connect_opts
        local settings = string.format("%q:%q:%q:%q:%q",
            type(config.auth) .. ":" .. tostring(config.auth),
            tostring(not not opts.ssl), tostring(not not opts.ssl_verify),
            type(opts.server_name) .. ":" .. tostring(opts.server_name),
            type(opts.pool) .. ":" .. tostring(opts.pool))
        return config.name .. ":127.0.0.1:" .. port .. ":config:"
               .. ngx.encode_base64(ngx.sha1_bin(settings))
    end
    local key = failure_key()
    assert(control:config("SET", listener, 0))
    local ok, failure = pcall(function()
        -- A previous worker can leave a failure counter after its local state is gone.
        if mode == "takeover" then assert(dict:set(key, 4, 60)) end
        local instance, err = cluster:new(config)
        assert(not instance and err, "connection unexpectedly succeeded with port closed")
        assert((dict:get(key) or 0) > 3,
            "business connection failure was not recorded")
        if mode == "takeover" then
            assert(dict:get(key) == 4, "unhealthy node was retried by the business connection")
        end
        if mode == "rotate" then
            config.auth = "health-test-password"
            key = failure_key()
            instance, err = cluster:new(config)
            assert(not instance and err, "rotated client unexpectedly connected to closed port")
            assert((dict:get(key) or 0) > 3, "rotated connection failure was not recorded")
        end
        for _, candidate in ipairs(dict:get_keys(0)) do
            assert(type(dict:get(candidate)) == "number",
                "health shared memory contains configuration instead of a failure counter")
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
