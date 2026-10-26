-- Deterministic scheduler tests; real sockets are covered by health-check.t.
package.path = "lib/?.lua;" .. package.path
local now, down, password, hook, auths, connects, closes
local health, locks, worker_count
local function dictionary()
    local data, expires = {}, {}
    local dict = {}
    function dict:get(key)
        if expires[key] and now >= expires[key] then self:delete(key) end
        return data[key]
    end
    function dict:set(key, value, ttl)
        if self.full then return nil, "no memory" end
        data[key], expires[key] = value, ttl and now + ttl
        return true
    end
    function dict:safe_add(key, value, ttl)
        if self:get(key) ~= nil then return nil, "exists" end
        return self:set(key, value, ttl)
    end
    function dict:incr(key, amount, initial, ttl)
        local value = self:get(key)
        if value == nil then
            if initial == nil then return nil, "not found" end
            if not self:set(key, initial, ttl) then return nil, "no memory" end
            value = initial
        end
        data[key] = value + amount
        return data[key]
    end
    function dict:delete(key) data[key], expires[key] = nil, nil end
    function dict:expire(key, ttl)
        if self:get(key) == nil then return nil, "not found" end
        expires[key] = now + ttl
        return true
    end
    function dict:get_keys()
        local keys = {}
        for key in pairs(data) do keys[#keys + 1] = key end
        return keys
    end
    return dict
end

package.preload["resty.redis"] = function()
    return {new = function()
        return {
            set_timeouts = function() end,
            connect = function(self, ip, port, opts)
                connects[#connects + 1] = opts or {}
                if hook then local f = hook; hook = nil; f() end
                if down then return nil, "connection refused" end
                return true
            end,
            get_reused_times = function() return 0 end,
            auth = function(self, value)
                auths[#auths + 1] = value
                self.authed = value == password
                if self.authed then return true end
                return false, "WRONGPASS"
            end,
            ping = function(self)
                if password and not self.authed then return false, "NOAUTH" end
                return "PONG"
            end,
            close = function() closes = closes + 1; return true end,
            set_keepalive = function() return true end,
            cluster = function(_, cmd)
                if cmd == "nodes" then return "" end
                return {{0, 0, {"127.0.0.1", 7000}}}
            end,
        }
    end}
end
package.preload["resty.lock"] = function()
    return {new = function()
        return {lock = function() return 0 end, unlock = function() return true end}
    end}
end
package.preload["resty.xmodem"] = function()
    return {redis_crc = function() return 0 end}
end

local key = "test:127.0.0.1:7000"
local function worker(real_slots)
    local w = {starts = 0, id = worker_count}
    worker_count = worker_count + 1
    ngx = {
        WARN = 4, ERR = 3, now = function() return now end, log = function() end,
        shared = {redis_cluster_health = health, redis_cluster_slot_locks = locks},
        worker = {
            id = function() return w.id end,
            count = function() return worker_count end,
        },
        timer = {every = function(_, callback)
            w.starts = w.starts + 1
            if w.reject_timer then return nil, "too many pending timers" end
            w.tick = callback
            return true
        end},
    }
    w.shared = ngx.shared
    package.loaded["resty.rediscluster"] = nil
    w.module = require "resty.rediscluster"
    if not real_slots then w.module.init_slots = function() return true end end
    function w:client(auth, opts, dict_name)
        return assert(self.module:new({
            name = "test", serv_list = {{ip = "127.0.0.1", port = 7000}},
            auth = auth, connect_opts = opts, max_connection_attempts = 4,
            dict_name = dict_name,
        }))
    end
    return w
end
local function fail(w, auth, opts)
    local client = w:client(auth, opts)
    client:fetch_slots()
    assert(health:get(key) == 4, "business failure not recorded")
    return client
end
local function reset()
    now, down, password, hook, closes = 10, true, nil, nil, 0
    worker_count = 0
    auths, connects = {}, {}
    health, locks = dictionary(), dictionary()
end
local failed, passed = 0, 0
local function test(name, body)
    reset()
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("PASS: " .. name)
    else failed = failed + 1; print("FAIL: " .. name .. ": " .. tostring(err)) end
end

test("init stays compatible and timers start only after a failure", function()
    local w = worker()
    w.module.init()
    assert(w.starts == 0, "init unexpectedly started a timer")
    local client = fail(w)
    client:fetch_slots()
    assert(w.starts == 1, "worker must have exactly one timer")
end)

test("TLS options and AUTH remain local, including non-JSON options", function()
    local w = worker()
    local cert = require("ffi").new("int[1]")
    local opts = {ssl = true, ssl_verify = true, client_cert = cert}
    fail(w, "secret", opts)
    for _, k in ipairs(health:get_keys()) do
        assert(type(health:get(k)) == "number", "configuration leaked to shm")
    end
    down, password = false, "secret"
    opts.server_name = "updated.example"
    assert(w.tick, "worker timer was not started")
    w.tick(false)
    assert(not health:get(key), "healthy authenticated node was not recovered")
    local actual = connects[#connects]
    assert(actual.ssl and actual.ssl_verify and actual.client_cert == cert)
    assert(actual.server_name == "updated.example", "probe used outdated connection options")
    assert(auths[1] == password and closes == 1)
    local before = #connects
    now = now + 6
    w.tick(false)
    assert(#connects == before, "recovered node was probed again")
end)

test("latest registration wins over a late failure from an older client", function()
    local w = worker()
    local old = w:client("old")
    w:client("new")
    old:fetch_slots()
    down, password = false, "new"
    assert(w.tick, "worker timer was not started")
    w.tick(false)
    assert(auths[1] == "new" and not health:get(key))
end)

test("a failed in-flight probe retries with the latest credentials", function()
    local w = worker()
    fail(w, "old")
    down, password = false, "new"
    hook = function() w:client("new") end
    w.tick(false)
    assert(auths[1] == "old" and health:get(key) == 5, "failed probe was not counted")
    now = now + 6
    w.tick(false)
    assert(auths[2] == "new" and not health:get(key), "new credentials did not recover")
end)

test("equivalent connection settings survive a lock dictionary change", function()
    local w = worker()
    w.shared.other_locks = dictionary()
    fail(w, "secret", {ssl = true, ssl_verify = true})
    down, password = false, "secret"
    hook = function()
        w:client("secret", {ssl = true, ssl_verify = true}, "other_locks")
    end
    w.tick(false)
    assert(not health:get(key), "lock dictionary change discarded a valid probe")
end)

test("a new worker adopts failures and shares the probe lock", function()
    local a = worker()
    fail(a)
    local b = worker()
    local before = #connects
    b:client():fetch_slots()
    assert(#connects == before, "unhealthy node was unexpectedly connected")
    assert(b.tick, "replacement worker did not start a timer")
    a.tick(false); b.tick(false)
    assert(#connects == before + 1, "duplicate cross-worker probe")
    now, down = now + 6, false
    b.tick(false)
    assert(not health:get(key))
end)

test("stale workers cannot starve a worker with rotated credentials", function()
    local a, b, c = worker(), worker(), worker()
    fail(a, "old")
    b:client("old"):fetch_slots()
    c:client("new"):fetch_slots()
    down, password = false, "new"
    for second = 10, 13 do
        now = second; a.tick(false)
        now = second + 0.2; b.tick(false)
        now = second + 0.4; c.tick(false)
    end
    assert(not health:get(key), "earlier stale workers starved the valid credentials")
end)

test("an abandoned older waiter eventually allows another worker to recover", function()
    local a, b, c = worker(), worker(), worker()
    fail(a)
    b:client():fetch_slots()
    c:client():fetch_slots()
    a.tick(false)
    now = 10.1; b.tick(false)
    down = false
    now = 11.2; c.tick(false)
    now = 16.3; c.tick(false)
    assert(not health:get(key), "abandoned waiter prevented recovery")
end)

test("a busy worker keeps its place while probing another node", function()
    local a, b = worker(), worker()
    fail(a, "old")
    b:client("new"):fetch_slots()
    a.tick(false)
    now = 10.1; b.tick(false)
    local other = assert(b.module:new({
        name = "other", serv_list = {{ip = "127.0.0.1", port = 7001}},
        auth = "new", max_connection_attempts = 4,
    }))
    other:fetch_slots()
    assert(health:get("other:127.0.0.1:7001") == 4)
    down, password = false, "new"
    hook = function()
        for second = 11, 16 do
            now = second
            b.tick(false)
        end
        a.tick(false)
    end
    now = 10.2; b.tick(false)
    now = 16.2; b.tick(false)
    assert(not health:get(key), "busy worker lost its turn to stale credentials")
end)

test("a slow probe excludes another worker after the first second", function()
    local a, b = worker(), worker()
    fail(a); b:client():fetch_slots()
    local before = #connects
    hook = function() now = now + 1.1; b.tick(false) end
    a.tick(false)
    assert(#connects == before + 1, "one-second lease allowed overlapping probes")
end)

test("a short probe does not delay the next one-second tick", function()
    local a, b = worker(), worker()
    fail(a); b:client():fetch_slots()
    hook = function() now = now + 0.1 end
    a.tick(false)
    local before = #connects
    now = 11
    b.tick(false)
    assert(#connects == before + 1, "finished probe delayed the next timer tick")
end)

test("an expired probe cannot change its successor's lock or failure", function()
    local w = worker()
    fail(w)
    local lock_key = "redis_cluster_probe_" .. key
    hook = function()
        now = now + 6
        assert(locks:safe_add(lock_key, now, 5))
    end
    w.tick(false)
    assert(health:get(key) == 4, "expired probe changed the counter")
    now = now + 2
    assert(locks:get(lock_key), "expired probe shortened its successor's lease")
end)

test("a successful probe clears failures recorded during the probe", function()
    local w = worker()
    fail(w)
    down = false
    hook = function() health:incr(key, 1) end
    w.tick(false)
    assert(not health:get(key), "successful probe did not clear the failure record")
end)

test("a deleted counter is not resurrected by a failing probe", function()
    local w = worker()
    fail(w)
    hook = function() health:delete(key) end
    w.tick(false)
    assert(not health:get(key))
end)

test("NOAUTH is not a successful PING", function()
    local w = worker()
    fail(w)
    down, password = false, "required"
    w.tick(false)
    assert(health:get(key) == 5 and closes == 1)
end)

test("failed timer allocation can be retried by a later request", function()
    local w = worker()
    w.reject_timer = true
    local client = fail(w)
    assert(not w.tick)
    w.reject_timer = false
    client:fetch_slots()
    assert(w.tick, "timer allocation was never retried")
end)

test("a full lock dictionary skips the probe without clearing the failure", function()
    local w = worker()
    fail(w)
    locks.full = true
    local before = #connects
    w.tick(false)
    assert(#connects == before and health:get(key) == 4)
end)

test("probe exceptions are logged without blocking later checks", function()
    local w, message = worker()
    fail(w)
    ngx.log = function(level, ...)
        if level == ngx.ERR then message = table.concat({...}) end
    end
    hook = function() error("injected probe failure", 0) end
    w.tick(false)
    assert(message and message:find("injected probe failure", 1, true), "probe error was not logged")
    assert(health:get(key) == 4, "exception changed the failure record")
    message = nil
    now, down = now + 6, false
    w.tick(false)
    assert(not health:get(key), "exception blocked a later health check")
    assert(not message, "successful probe logged an exception")
end)

test("same-name clients retain the original topology cache", function()
    local w = worker(true)
    down, password = false, "old"
    w:client("old")
    local before = #connects
    w:client("new")
    assert(#connects == before, "credentials changed business slot cache behavior")
end)

print(passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
