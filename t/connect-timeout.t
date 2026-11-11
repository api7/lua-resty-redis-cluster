use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(1);
no_long_string();
plan tests => repeat_each() * (2 * blocks() + 1);

my $pwd = cwd();
my $extra_lua_path = $ENV{TEST_REDIS_LUA_PATH} || "";
my $fixtures = $ENV{TEST_REDIS_FIXTURE_DIR} or die "Set TEST_REDIS_FIXTURE_DIR; see t/README.md\n";

# Two fake single-node clusters speaking RESP over TLS. Both report
# 127.0.0.1:17621 as the owner of every slot; only 17621 delays its TLS
# handshake by 300 ms, so whether a connect to it succeeds depends on the
# connect timeout that bounds the handshake.
my $fake_redis = q{
    content_by_lua_block {
        local sock, err = ngx.req.socket(true)
        if not sock then
            ngx.log(ngx.ERR, "fake redis: failed to get the client socket: ", err)
            return
        end
        local function check(ok, err, op)
            -- The client closing its connection is how every session ends.
            if not ok and err ~= "closed" then
                ngx.log(ngx.ERR, "fake redis: failed to ", op, ": ", err)
            end
            return ok
        end
        local function read(size)
            local data, err = sock:receive(size or "*l")
            return check(data, err, "read")
        end
        local function read_command()
            local line = read()
            if not line then return end
            local args = {}
            for i = 1, tonumber(line:sub(2)) do
                local len = read()
                local arg = len and read(tonumber(len:sub(2)) + 2)
                if not arg then return end
                args[i] = arg:sub(1, -3):lower()
            end
            return args
        end
        while true do
            local args = read_command()
            if not args then return end
            local reply
            if args[1] == "cluster" and args[2] == "slots" then
                reply = "*1\r\n*3\r\n:0\r\n:16383\r\n*2\r\n$9\r\n127.0.0.1\r\n:17621\r\n"
            elseif args[1] == "cluster" and args[2] == "nodes" then
                local nodes = "n1 127.0.0.1:17621@27621 myself,master - 0 0 1 connected 0-16383\n"
                reply = "$" .. #nodes .. "\r\n" .. nodes .. "\r\n"
            elseif args[1] == "get" then
                reply = "$2\r\nok\r\n"
            else
                reply = "-ERR unknown command\r\n"
            end
            local ok, err = sock:send(reply)
            if not check(ok, err, "send") then return end
        end
    }
};

my $main_config = qq{
    stream {
        lua_package_path "$pwd/lib/?.lua;;";
        ssl_certificate $fixtures/server.crt;
        ssl_certificate_key $fixtures/server.key;
        server {
            listen 127.0.0.1:17620 ssl;
            $fake_redis
        }
        server {
            listen 127.0.0.1:17621 ssl;
            ssl_certificate_by_lua_block {
                ngx.log(ngx.NOTICE, "slow TLS handshake started")
                ngx.sleep(0.3)
            }
            $fake_redis
        }
    }
};

my $http_config = qq{
    lua_package_path "$pwd/lib/?.lua;$extra_lua_path;;";
    lua_shared_dict redis_cluster_slot_locks 64k;
};

add_block_preprocessor(sub {
    my ($block) = @_;
    $block->set_value("main_config", $main_config);
    $block->set_value("http_config", $http_config);
    $block->set_value("request", "GET /t");
    $block->set_value("timeout", 10);
});

run_tests();
__DATA__

=== TEST 1: slot fetch connects within the configured connect_timeout
--- config
    location /t {
        content_by_lua_block {
            local red, err = require("resty.rediscluster"):new({
                name = "slow-seed-1000",
                serv_list = { { ip = "127.0.0.1", port = 17621 } },
                connect_opts = { ssl = true },
                connect_timeout = 1000,
                max_connection_attempts = 1,
            })
            ngx.say(red and "connected" or err)
        }
    }
--- response_body
connected



=== TEST 2: slot fetch retries are bounded by the configured connect_timeout
--- config
    location /t {
        content_by_lua_block {
            local red, err = require("resty.rediscluster"):new({
                name = "slow-seed-200",
                serv_list = { { ip = "127.0.0.1", port = 17621 } },
                connect_opts = { ssl = true },
                connect_timeout = 200,
                max_connection_attempts = 2,
            })
            ngx.say(red and "connected" or err)
        }
    }
--- response_body_like chomp
^failed to fetch slots: failed to do ssl handshake: timeout(;failed to do ssl handshake: timeout)+$
--- grep_error_log eval
qr/slow TLS handshake started/
--- grep_error_log_out
slow TLS handshake started
slow TLS handshake started



=== TEST 3: slot fetch without connect_timeout uses the 1000 ms default
--- config
    location /t {
        content_by_lua_block {
            local red, err = require("resty.rediscluster"):new({
                name = "slow-seed-default",
                serv_list = { { ip = "127.0.0.1", port = 17621 } },
                connect_opts = { ssl = true },
                max_connection_attempts = 1,
            })
            ngx.say(red and "connected" or err)
        }
    }
--- response_body
connected



=== TEST 4: command connects within the configured connect_timeout
--- config
    location /t {
        content_by_lua_block {
            local red = assert(require("resty.rediscluster"):new({
                name = "slow-node-1000",
                serv_list = { { ip = "127.0.0.1", port = 17620 } },
                connect_opts = { ssl = true },
                connect_timeout = 1000,
                max_redirection = 1,
            }))
            local res, err = red:get("k")
            ngx.say(res or err)
        }
    }
--- response_body
ok



=== TEST 5: command without connect_timeout uses the 1000 ms default
--- config
    location /t {
        content_by_lua_block {
            local red = assert(require("resty.rediscluster"):new({
                name = "slow-node-default",
                serv_list = { { ip = "127.0.0.1", port = 17620 } },
                connect_opts = { ssl = true },
                max_redirection = 1,
            }))
            local res, err = red:get("k")
            ngx.say(res or err)
        }
    }
--- response_body
ok



=== TEST 6: command retries are bounded by the configured connect_timeout
--- config
    location /t {
        content_by_lua_block {
            local red = assert(require("resty.rediscluster"):new({
                name = "slow-node-200",
                serv_list = { { ip = "127.0.0.1", port = 17620 } },
                connect_opts = { ssl = true },
                connect_timeout = 200,
                max_redirection = 2,
            }))
            local res, err = red:get("k")
            ngx.say(res or err)
        }
    }
--- response_body
failed to do ssl handshake: timeout
