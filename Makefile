OPENRESTY_PREFIX ?=/usr/local/openresty
PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

LUAJIT ?= $(OPENRESTY_PREFIX)/luajit/bin/luajit
TEST_NGINX_LIB ?= ../test-nginx/lib

.PHONY: all test test-unit test-health install

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)$(LUA_LIB_DIR)/resty
	$(INSTALL) lib/resty/*.lua $(DESTDIR)$(LUA_LIB_DIR)/resty

test: all test-unit
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I$(TEST_NGINX_LIB) -r t

test-unit:
	LUA_PATH="$$LUA_PATH;$(OPENRESTY_PREFIX)/lualib/?.lua;;" \
	LUA_CPATH="$$LUA_CPATH;$(OPENRESTY_PREFIX)/lualib/?.so;;" \
	$(LUAJIT) t/health_check.lua

test-health:
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I$(TEST_NGINX_LIB) t/health-check.t

