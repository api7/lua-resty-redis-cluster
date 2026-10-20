use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(1);
no_shuffle();
no_long_string();
plan tests => repeat_each() * (2 * blocks());

my $pwd = cwd();
my $extra_lua_path = $ENV{TEST_REDIS_LUA_PATH} || "";
my $ca = $ENV{TEST_REDIS_TLS_CA} or die "Set TEST_REDIS_TLS_CA; see t/README.md\n";
my $http_config = qq{
    lua_package_path "$pwd/lib/?.lua;$pwd/t/lib/?.lua;$extra_lua_path;;";
    lua_shared_dict redis_cluster_slot_locks 64k;
    lua_shared_dict redis_cluster_health 1m;
    lua_ssl_trusted_certificate $ca;
    lua_ssl_verify_depth 3;
    init_worker_by_lua_block {
        require("resty.rediscluster").init()
    }
};

add_block_preprocessor(sub {
    my ($block) = @_;
    my $mode = $block->mode;
    $block->set_value("http_config", $http_config);
    $block->set_value("config", qq{
        location /t { content_by_lua_block { require("health_check_integration").run("$mode") } }
    });
    $block->set_value("request", "GET /t");
    $block->set_value("timeout", 8);
});

run_tests();
__DATA__

=== TEST 1: plain TCP node recovers
--- mode: plain
--- response_body
recovered

=== TEST 2: TLS-only node recovers with certificate verification
--- mode: tls
--- response_body
recovered

=== TEST 3: password-only node authenticates before PING
--- mode: auth
--- response_body
recovered

=== TEST 4: TLS and password node recovers
--- mode: tls-auth
--- response_body
recovered

=== TEST 5: wrong password must not recover
--- mode: wrong-auth
--- response_body
rejected

=== TEST 6: incorrect TLS server name must not recover
--- mode: wrong-name
--- response_body
rejected

=== TEST 7: latest credentials recover an existing failure record
--- mode: rotate
--- response_body
recovered

=== TEST 8: NOAUTH error on plain TCP must not be treated as successful PING
--- mode: wrong-auth-plain
--- response_body
rejected

=== TEST 9: a worker adopts an existing unhealthy node without another connection failure
--- mode: takeover
--- response_body
recovered
