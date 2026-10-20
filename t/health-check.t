use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(1);
no_shuffle();
no_long_string();
master_on();
workers(1);
plan tests => repeat_each() * (2 * blocks());

my $pwd = cwd();
my $extra_lua_path = $ENV{TEST_REDIS_LUA_PATH} || "";
my $ca = $ENV{TEST_REDIS_TLS_CA} or die "Set TEST_REDIS_TLS_CA; see t/README.md\n";
our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;$pwd/t/lib/?.lua;$extra_lua_path;;";
    lua_shared_dict redis_cluster_slot_locks 64k;
    lua_shared_dict redis_cluster_health 1m;
    lua_ssl_trusted_certificate $ca;
    lua_ssl_verify_depth 3;
    init_by_lua_block {
        assert(require("ngx.process").enable_privileged_agent())
    }
    init_worker_by_lua_block {
        if require("ngx.process").type() == "privileged agent" then
            require("resty.rediscluster").init()
        end
    }
};

run_tests();
__DATA__

=== TEST 1: plain TCP node recovers
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("plain") } }
--- request
GET /t
--- response_body
recovered
--- timeout: 8

=== TEST 2: TLS-only node recovers with certificate verification
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("tls") } }
--- request
GET /t
--- response_body
recovered
--- timeout: 8

=== TEST 3: password-only node authenticates before PING
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("auth") } }
--- request
GET /t
--- response_body
recovered
--- timeout: 8

=== TEST 4: TLS and password node recovers
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("tls-auth") } }
--- request
GET /t
--- response_body
recovered
--- timeout: 8

=== TEST 5: wrong password must not recover
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("wrong-auth") } }
--- request
GET /t
--- response_body
rejected
--- timeout: 8

=== TEST 6: incorrect TLS server name must not recover
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("wrong-name") } }
--- request
GET /t
--- response_body
rejected
--- timeout: 8

=== TEST 7: rotated credentials recover independently of the old configuration
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("rotate") } }
--- request
GET /t
--- response_body
recovered
--- timeout: 8

=== TEST 8: NOAUTH error on plain TCP must not be treated as successful PING
--- http_config eval: $::HttpConfig
--- config
    location /t { content_by_lua_block { require("health_check_integration").run("wrong-auth-plain") } }
--- request
GET /t
--- response_body
rejected
--- timeout: 8
