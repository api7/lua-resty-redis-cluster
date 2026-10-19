-- Run with: luajit t/health_check.lua
package.path = "lib/?.lua;" .. package.path
local real_cjson = os.getenv("HEALTH_CHECK_REAL_CJSON") and require "cjson.safe"

local values = {}
local deadlines = {}
local now = 0
local reject_config_write = false
local reject_counter_write = false
local dict = {}
function dict:get(key)
    if deadlines[key] and deadlines[key] <= now then self:delete(key) end
    return values[key]
end
function dict:set(key, value, ttl)
    if type(value) == "string" and reject_config_write
        or type(value) == "number" and reject_counter_write then
        return nil, "no memory"
    end
    values[key] = value
    deadlines[key] = ttl and ttl > 0 and now + ttl or nil
    return true
end
function dict:safe_set(...) return self:set(...) end
function dict:safe_add(key, value, ttl)
    if self:get(key) ~= nil then return nil, "exists" end
    return self:set(key, value, ttl)
end
function dict:expire(key, ttl)
    if self:get(key) == nil then return nil, "not found" end
    deadlines[key] = now + ttl
    return true
end
function dict:delete(key) values[key] = nil; deadlines[key] = nil end
function dict:incr(key, by, initial)
    local current = self:get(key) or initial
    if current == nil then return nil, "not found" end
    values[key] = current + by
    return values[key]
end
function dict:get_keys()
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    return keys
end

local attempts = {}
local expected = {
    ["7000"] = { ssl = true, auth = "secret", down = true },
    ["7001"] = { ssl = false, down = true },
    ["7002"] = { ssl = true, down = true },
}
package.preload["resty.redis"] = function()
    return {
        new = function()
            local client = {}
            function client:set_timeouts() end
            function client:connect(_, port, opts)
                local target = expected[tostring(port)]
                attempts[#attempts + 1] = { port = port, opts = opts }
                if target.down then return nil, "connection refused" end
                if (opts and opts.ssl or false) ~= target.ssl then
                    return nil, "wrong transport"
                end
                self.port = port
                return true
            end
            function client:auth(password)
                self.authed = password == expected[tostring(self.port)].auth
                if self.authed then return true end
                return nil, "wrong password"
            end
            function client:get_reused_times() return 0 end
            function client:ping()
                local target = expected[tostring(self.port)]
                if target.auth and not self.authed then
                    return nil, "NOAUTH Authentication required"
                end
                return "PONG"
            end
            function client:close() return true end
            return client
        end,
    }
end
package.preload["resty.lock"] = function() return {} end
package.preload["resty.xmodem"] = function()
    return { redis_crc = function() return 0 end }
end
local encoded = {}
package.preload["cjson.safe"] = function()
    if real_cjson then return real_cjson end
    return {
        encode = function(value)
            local id = tostring(#encoded + 1)
            encoded[#encoded + 1] = value
            return id
        end,
        decode = function(id) return encoded[tonumber(id)] end,
    }
end

local timer
ngx = {
    WARN = 4, ERR = 3,
    now = function() return now end,
    shared = { redis_cluster_health = dict },
    timer = { every = function(_, callback) timer = callback; return true end },
    log = function() end,
}

local cluster = require "resty.rediscluster"
cluster.init_slots = function() return true end
local function register(name, port, opts, auth)
    local instance, err = cluster:new({
        name = name,
        serv_list = {{ ip = "127.0.0.1", port = port }},
        connect_opts = opts,
        auth = auth,
    })
    assert(instance, err)
    local ok = instance:fetch_slots()
    assert(not ok, "initial node failure was not recorded")
end

register("tls", 7000, { ssl = true, ssl_verify = true }, "secret")
register("config", 7001, { ssl = false })
register("down", 7002, { ssl = true })
expected["7000"].down = false
expected["7001"].down = false
local down_failures = dict:get("down:127.0.0.1:7002")
package.loaded["resty.rediscluster"] = nil
local health_agent = require "resty.rediscluster"
health_agent.init()
assert(timer, "health timer was not registered")
timer(false)

assert(dict:get("tls:127.0.0.1:7000") == nil,
       "TLS node did not recover")
assert(dict:get("config:127.0.0.1:7001") == nil,
       "plaintext node did not recover")
assert(dict:get("down:127.0.0.1:7002") == down_failures + 1,
       "genuinely down node was not counted")
local tls_seen, plain_seen = false, false
for _, attempt in ipairs(attempts) do
    if attempt.port == 7000 then
        tls_seen = attempt.opts and attempt.opts.ssl == true
                          and attempt.opts.ssl_verify == true
    elseif attempt.port == 7001 then
        plain_seen = attempt.opts and attempt.opts.ssl == false
    end
end
assert(tls_seen and plain_seen, "cluster connection options leaked or vanished")
print("health check TLS, auth, plaintext, isolation, down-node: PASS")

local function reset()
    for key in pairs(values) do dict:delete(key) end
    attempts = {}
    now = 0
    reject_config_write = false
    reject_counter_write = false
    expected["7000"] = {ssl = true, auth = "old-test-password", down = true}
end

local function new_client(password)
    return assert(cluster:new({name = "review", auth = password,
        serv_list = {{ip = "127.0.0.1", port = 7000}}, connect_opts = {ssl = true}}))
end

local key = "review:127.0.0.1:7000"
local function mark_unhealthy()
    register("review", 7000, {ssl = true}, "old-test-password")
    register("review", 7000, {ssl = true}, "old-test-password")
    assert(dict:get(key) == 4)
end

local tests = {}
tests["password rotation while unhealthy"] = function()
    mark_unhealthy()
    expected["7000"].down = false
    expected["7000"].auth = "new-test-password"
    new_client("new-test-password")
    timer(false)
    assert(dict:get(key) == nil, "health checker still uses the old password")
end

tests["configuration update during a failed probe"] = function()
    mark_unhealthy()
    local original_new = package.loaded["resty.redis"].new
    package.loaded["resty.redis"].new = function(...)
        local red = original_new(...)
        function red:connect()
            new_client("new-test-password")
            return nil, "timeout"
        end
        return red
    end
    timer(false)
    package.loaded["resty.redis"].new = original_new
    expected["7000"].down = false
    expected["7000"].auth = "new-test-password"
    timer(false)
    assert(dict:get(key) == nil, "failed probe restored the old configuration")
end

tests["configuration allocation fails"] = function()
    reject_config_write = true
    register("review", 7000, {ssl = true}, "old-test-password")
    register("review", 7000, {ssl = true}, "old-test-password")
    assert(dict:get(key) == nil, "uncheckable failure marker was created")
end

tests["configuration update fails during rotation"] = function()
    mark_unhealthy()
    reject_config_write = true
    new_client("new-test-password")
    timer(false)
    assert(dict:get(key) == nil, "old credentials keep the node unhealthy")
end

tests["configuration is evicted independently"] = function()
    mark_unhealthy()
    for entry, value in pairs(values) do
        if type(value) == "string" then dict:delete(entry) end
    end
    timer(false)
    assert(dict:get(key) == nil, "missing configuration leaves a blocked node")
end

tests["counter allocation fails"] = function()
    reject_counter_write = true
    register("review", 7000, {ssl = true}, "old-test-password")
    assert(dict:get(key) == nil, "counter allocation error was ignored")
end

tests["counter deleted during network I/O"] = function()
    mark_unhealthy()
    local original_new = package.loaded["resty.redis"].new
    package.loaded["resty.redis"].new = function(...)
        local red = original_new(...)
        function red:connect()
            dict:delete(key)
            return nil, "timeout"
        end
        return red
    end
    timer(false)
    package.loaded["resty.redis"].new = original_new
    assert(dict:get(key) == nil, "probe resurrected a removed failure marker")
end

tests["unused credentials expire after recovery"] = function()
    mark_unhealthy()
    expected["7000"].down = false
    timer(false)
    now = 61
    for entry in pairs(values) do
        assert(dict:get(entry) == nil, "recovered cluster retains configuration beyond TTL")
    end
end

tests["one recovered node does not remove another node's configuration"] = function()
    expected["7002"] = {ssl = true, auth = "old-test-password", down = true}
    register("review", 7000, {ssl = true}, "old-test-password")
    register("review", 7002, {ssl = true}, "old-test-password")
    expected["7000"].down = false
    timer(false)
    assert(dict:get(key) == nil)
    local second_key = "review:127.0.0.1:7002"
    assert(dict:get(second_key) == 3, "remaining node lost its configuration")
    expected["7002"].down = false
    timer(false)
    assert(dict:get(second_key) == nil, "remaining node did not recover")
end

local failed = 0
for name, test in pairs(tests) do
    reset()
    local ok, err = pcall(test)
    print((ok and "PASS: " or "FAIL: ") .. name .. (ok and "" or ": " .. tostring(err)))
    if not ok then failed = failed + 1 end
end
assert(failed == 0, tostring(failed) .. " health-check regression(s)")
