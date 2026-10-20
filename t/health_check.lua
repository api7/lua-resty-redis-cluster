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
local authentications = {}
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
                authentications[#authentications + 1] = {port = self.port, password = password}
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
            function client:set_keepalive() return true end
            function client:cluster(command)
                if command == "nodes" then return "" end
                return {{0, 0, {"127.0.0.1", self.port}}}
            end
            return client
        end,
    }
end
package.preload["resty.lock"] = function() return {} end
package.preload["resty.xmodem"] = function()
    return { redis_crc = function() return 0 end }
end
local encoded = {}
local function stable(value)
    if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
    local entries = {}
    for key, item in pairs(value) do
        entries[#entries + 1] = stable(key) .. "=" .. stable(item)
    end
    table.sort(entries)
    return "{" .. table.concat(entries, ";") .. "}"
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
package.preload["cjson.safe"] = function()
    if real_cjson then return real_cjson end
    return {
        encode = function(value)
            local id = stable(value)
            encoded[id] = copy(value)
            return id
        end,
        decode = function(id) return copy(encoded[id]) end,
    }
end
-- Hash implementation is exercised by the OpenResty integration tests.
package.preload["resty.sha256"] = function()
    return { new = function()
        return {
            update = function(self, value) self.value = value end,
            final = function(self) return self.value end,
        }
    end }
end
package.preload["resty.string"] = function()
    return {to_hex = function(value)
        return (value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
    end}
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
    return instance.cache_key .. ":127.0.0.1:" .. port
end

local tls_key = register("tls", 7000, { ssl = true, ssl_verify = true }, "secret")
local plain_key = register("config", 7001, { ssl = false })
local down_key = register("down", 7002, { ssl = true })
expected["7000"].down = false
expected["7001"].down = false
local down_failures = dict:get(down_key)
package.loaded["resty.rediscluster"] = nil
local health_agent = require "resty.rediscluster"
health_agent.init()
assert(timer, "health timer was not registered")
timer(false)

assert(dict:get(tls_key) == nil,
       "TLS node did not recover")
assert(dict:get(plain_key) == nil,
       "plaintext node did not recover")
assert(dict:get(down_key) == down_failures + 1,
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
    package.loaded["resty.rediscluster"] = nil
    cluster = require "resty.rediscluster"
    cluster.init_slots = function() return true end
    for key in pairs(values) do dict:delete(key) end
    attempts = {}
    authentications = {}
    now = 0
    reject_config_write = false
    reject_counter_write = false
    expected["7000"] = {ssl = true, auth = "old-test-password", down = true}
end

local function new_client(password, port)
    return assert(cluster:new({name = "review", auth = password,
        serv_list = {{ip = "127.0.0.1", port = port or 7000}}, connect_opts = {ssl = true}}))
end

local key
local function mark_unhealthy()
    key = register("review", 7000, {ssl = true}, "old-test-password")
    key = register("review", 7000, {ssl = true}, "old-test-password")
    assert(dict:get(key) == 4)
end

local function probe_during(action)
    local redis = package.loaded["resty.redis"]
    local original_new = redis.new
    redis.new = function(...)
        local red = original_new(...)
        function red:connect()
            action()
            return nil, "timeout"
        end
        return red
    end
    local ok, err = pcall(timer, false)
    redis.new = original_new
    assert(ok, err)
end

local tests = {}
tests["first old failure after a new client does not block the new configuration"] = function()
    local old = new_client("old-test-password")
    local current = new_client("new-test-password")
    assert(not old:fetch_slots())
    assert(not old:fetch_slots())
    expected["7000"].down = false
    expected["7000"].auth = "new-test-password"
    local _, err = current:fetch_slots()
    assert(not err, "new configuration was blocked by a late old failure: " .. tostring(err))
end

tests["replacement credentials are never sent to a former endpoint"] = function()
    mark_unhealthy()
    expected["7000"].down = false
    expected["7002"] = {ssl = true, auth = "replacement-password", down = true}
    new_client("replacement-password", 7002)
    timer(false)
    for _, call in ipairs(authentications) do
        assert(not (call.port == 7000 and call.password == "replacement-password"),
            "replacement credentials were sent to the former endpoint")
    end
end

tests["password rotation while unhealthy"] = function()
    mark_unhealthy()
    expected["7000"].down = false
    expected["7000"].auth = "new-test-password"
    local current = new_client("new-test-password")
    local _, err = current:fetch_slots()
    assert(not err, "new credentials inherit the old failure")
    assert(dict:get(key), "old configuration unexpectedly reused the new credentials")
end

tests["configuration update during a failed probe"] = function()
    mark_unhealthy()
    probe_during(function() new_client("new-test-password") end)
    expected["7000"].down = false
    expected["7000"].auth = "new-test-password"
    local _, err = new_client("new-test-password"):fetch_slots()
    assert(not err, "failed probe blocked the new configuration")
end

tests["configuration allocation fails"] = function()
    reject_config_write = true
    key = register("review", 7000, {ssl = true}, "old-test-password")
    key = register("review", 7000, {ssl = true}, "old-test-password")
    assert(dict:get(key) == nil, "uncheckable failure marker was created")
end

tests["configuration update fails during rotation"] = function()
    mark_unhealthy()
    reject_config_write = true
    local current = new_client("new-test-password")
    local _, err = current:fetch_slots()
    assert(err, "down endpoint unexpectedly connected")
    assert(not dict:get(current.cache_key .. ":127.0.0.1:7000"),
        "allocation failure published an uncheckable new record")
    assert(dict:get(key) == 4, "new allocation failure altered the old record")
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
    key = register("review", 7000, {ssl = true}, "old-test-password")
    assert(dict:get(key) == nil, "counter allocation error was ignored")
end

tests["counter deleted during network I/O"] = function()
    mark_unhealthy()
    probe_during(function() dict:delete(key) end)
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
    local instance = assert(cluster:new({name = "review", auth = "old-test-password",
        serv_list = {{ip = "127.0.0.1", port = 7000}, {ip = "127.0.0.1", port = 7002}},
        connect_opts = {ssl = true}}))
    instance:fetch_slots()
    key = instance.cache_key .. ":127.0.0.1:7000"
    local second_key = instance.cache_key .. ":127.0.0.1:7002"
    expected["7000"].down = false
    timer(false)
    assert(dict:get(key) == nil)
    assert(dict:get(second_key) == 3, "remaining node lost its configuration")
    expected["7002"].down = false
    timer(false)
    assert(dict:get(second_key) == nil, "remaining node did not recover")
end

tests["abandoned credentials expire even while probes fail"] = function()
    mark_unhealthy()
    now = 30
    timer(false)
    now = 61
    timer(false)
    for entry in pairs(values) do
        assert(dict:get(entry) == nil, "probe retained an abandoned configuration")
    end
end

tests["active clients renew only their own configuration"] = function()
    mark_unhealthy()
    now = 30
    timer(false)
    now = 50
    new_client("old-test-password")
    now = 61
    timer(false)
    assert(dict:get(new_client("old-test-password").cache_key),
        "active client lost its configuration")
    assert(dict:get(key) > 4, "active configuration lost its failure counter")
end

tests["caller mutations cannot change an existing client's credentials"] = function()
    local config = {name = "mutation", auth = "old-test-password",
        serv_list = {{ip = "127.0.0.1", port = 7000}}, connect_opts = {ssl = true}}
    local old = assert(cluster:new(config))
    config.auth = "new-test-password"
    config.connect_opts.ssl = false
    config.serv_list[1].port = 7002
    old:fetch_slots()
    expected["7000"].down = false
    timer(false)
    assert(authentications[1] and authentications[1].password == "old-test-password")
    assert(authentications[1].port == 7000)
end

tests["equivalent configurations share an identity across module reloads"] = function()
    local first = new_client("old-test-password")
    local second = assert(cluster:new({connect_opts = {ssl = true}, name = "review",
        serv_list = {{port = 7000, ip = "127.0.0.1"}}, auth = "old-test-password"}))
    assert(first.cache_key == second.cache_key, "table insertion order changed identity")
    package.loaded["resty.rediscluster"] = nil
    local reloaded = require "resty.rediscluster"
    reloaded.init_slots = function() return true end
    assert(first.cache_key == assert(reloaded:new(first.config)).cache_key)
end

tests["new endpoints do not inherit a previous configuration's slot cache"] = function()
    local old = new_client("old-test-password")
    expected["7000"].down = false
    local _, err = old:fetch_slots()
    assert(not err)
    expected["7002"] = {ssl = true, auth = "new-test-password", down = false}
    local current = new_client("new-test-password", 7002)
    _, err = current:fetch_slots()
    assert(not err, "new endpoint reused the former topology")
    for _, call in ipairs(authentications) do
        assert(not (call.port == 7000 and call.password == "new-test-password"))
    end
end

tests["unused topology is released after a configuration change"] = function()
    local old = new_client("old-test-password")
    expected["7000"].down = false
    local original_new = package.loaded["resty.redis"].new
    local weak = setmetatable({}, {__mode = "v"})
    package.loaded["resty.redis"].new = function(...)
        local red = original_new(...)
        local command = red.cluster
        function red:cluster(cmd)
            local result = command(self, cmd)
            if cmd == "slots" then
                -- A collectable sentinel stands in for an endpoint value so
                -- the test observes retained topology without inspecting caches.
                weak[1] = {}
                result[1][3][1] = weak[1]
            end
            return result
        end
        return red
    end
    local _, err = old:fetch_slots()
    package.loaded["resty.redis"].new = original_new
    assert(not err)
    new_client("new-test-password")
    old = nil
    collectgarbage("collect")
    assert(weak[1] == nil, "unused configuration retains its topology indefinitely")
end

tests["constructor renews but does not create a shared snapshot"] = function()
    local current = new_client("old-test-password")
    assert(dict:get(current.cache_key) == nil,
        "constructor published an unnecessary credential snapshot")
end

tests["another worker publishes the identical snapshot after expire misses"] = function()
    local current = new_client("old-test-password")
    local config_key = current.cache_key
    local expire = dict.expire
    local raced = false
    dict.expire = function(self, entry, ttl)
        if entry == config_key and not raced then
            raced = true
            assert(self:safe_add(entry, current.health_config, ttl))
            return nil, "not found"
        end
        return expire(self, entry, ttl)
    end
    local ok, err = pcall(current.fetch_slots, current)
    dict.expire = expire
    assert(ok, err)
    assert(raced, "concurrent publication was not simulated")
    assert(dict:get(current.cache_key .. ":127.0.0.1:7000") == 2,
        "an existing identical snapshot prevented failure recording")
end


tests["health scan preserves configuration but removes malformed numeric counters"] = function()
    mark_unhealthy()
    dict:set("malformed-counter", 4, 60)
    timer(false)
    assert(dict:get(new_client("old-test-password").cache_key), "scan deleted configuration")
    assert(not dict:get("malformed-counter"), "invalid counter was not removed")
end

tests["slot refresh preserves its own snapshot and other configuration records"] = function()
    mark_unhealthy()
    local current = new_client("old-test-password")
    local other = new_client("new-test-password", 7002)
    expected["7002"] = {ssl = true, auth = "new-test-password", down = true}
    other:fetch_slots()
    dict:delete(key)
    expected["7000"].down = false
    local ok, err = current:fetch_slots()
    assert(not err, err)
    local obsolete = current.cache_key .. ":127.0.0.1:7999"
    dict:set(obsolete, 4, 60)
    ngx.worker = {id = function() return 0 end}
    package.loaded["resty.lock"].new = function()
        return {lock = function() return 0 end, unlock = function() return true end}
    end
    local _, refresh_err = current:refresh_slots()
    assert(not refresh_err, refresh_err)
    assert(not dict:get(obsolete), "removed node retained a failure marker")
    assert(dict:get(current.cache_key), "refresh deleted its own snapshot")
    assert(dict:get(other.cache_key), "refresh deleted another snapshot")
    assert(dict:get(other.cache_key .. ":127.0.0.1:7002"), "refresh deleted another counter")
end

tests["alternating live configurations reuse their topology"] = function()
    package.loaded["resty.rediscluster"] = nil
    cluster = require "resty.rediscluster"
    package.loaded["resty.lock"].new = function()
        return {lock = function() return 0 end, unlock = function() return true end}
    end
    for entry in pairs(values) do dict:delete(entry) end
    expected["7000"] = {ssl = true, auth = "old-test-password", down = false}
    expected["7002"] = {ssl = true, auth = "new-test-password", down = false}
    local retained = {new_client("old-test-password"), new_client("new-test-password", 7002)}
    local before = #attempts
    for _ = 1, 10 do
        new_client("old-test-password")
        new_client("new-test-password", 7002)
    end
    assert(#attempts == before, "alternating live configurations refetched their topology")
    assert(retained[1] and retained[2])
end

local failed = 0
for name, test in pairs(tests) do
    reset()
    local ok, err = pcall(test)
    print((ok and "PASS: " or "FAIL: ") .. name .. (ok and "" or ": " .. tostring(err)))
    if not ok then failed = failed + 1 end
end
assert(failed == 0, tostring(failed) .. " health-check regression(s)")
