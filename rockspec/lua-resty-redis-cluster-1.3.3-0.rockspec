package = "lua-resty-redis-cluster"
version = "1.3.3-0"

source = {
    url = "git+https://github.com/iresty/lua-resty-redis-cluster.git",
    tag = "v1.3.3"
}


description = {
    summary = "Openresty lua client for redis cluster",
    detailed = [[
        Openresty environment lua client with redis cluster support.
        This is a wrapper around the 'resty.redis' library with cluster discovery
        and failover recovery support.
    ]],
    homepage = "https://github.com/iresty/lua-resty-redis-cluster",
    license = "Apache License 2.0",
}

build = {
    type = "builtin",
    modules = {
        ["resty.rediscluster"] = "lib/resty/rediscluster.lua",
        ["resty.xmodem"] = "lib/resty/xmodem.lua"
    }
}
