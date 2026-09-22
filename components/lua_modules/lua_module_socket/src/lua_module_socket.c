/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * High-level Lua socket module (luasocket-style subset for ESP-IDF / lwIP).
 */
#include "lua_module_socket.h"

#include <errno.h>
#include <netdb.h>
#include <string.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>

#include "cap_lua.h"
#include "esp_log.h"
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

static const char *TAG = "lua_module_socket";

#define LUA_SOCKET_MT "socket.tcp"
#define LUA_UDP_MT "socket.udp"
#define LUA_SOCKET_RECV_DEFAULT 4096
#define LUA_SOCKET_RECV_MAX (64 * 1024)
#define LUA_SOCKET_SEND_CHUNK 1460

typedef struct {
    int fd;
    int timeout_ms; /* <0: blocking forever; 0: non-blocking; >0: ms */
    bool connected;
} lua_socket_tcp_t;

typedef struct {
    int fd;
    int timeout_ms;
    bool peer_set;
} lua_socket_udp_t;

static int lua_socket_push_error(lua_State *L, const char *fallback)
{
    const char *msg = strerror(errno);

    lua_pushnil(L);
    lua_pushstring(L, (msg && msg[0]) ? msg : fallback);
    return 2;
}

static int lua_socket_set_fd_timeout(int fd, int timeout_ms)
{
    struct timeval tv;

    if (timeout_ms < 0) {
        tv.tv_sec = 0;
        tv.tv_usec = 0;
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
        return -1;
    }
    return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static int lua_socket_resolve_ipv4(const char *host, struct in_addr *out)
{
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    int err;

    if (!host || !host[0] || !out) {
        return -1;
    }
    if (inet_pton(AF_INET, host, out) == 1) {
        return 0;
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    err = getaddrinfo(host, NULL, &hints, &res);
    if (err != 0 || !res) {
        ESP_LOGW(TAG, "DNS resolve failed for %s: %d", host, err);
        return -1;
    }
    *out = ((struct sockaddr_in *)res->ai_addr)->sin_addr;
    freeaddrinfo(res);
    return 0;
}

/* ── TCP object ─────────────────────────────────────────────────────────── */

static lua_socket_tcp_t *lua_socket_tcp_check(lua_State *L, int index)
{
    return (lua_socket_tcp_t *)luaL_checkudata(L, index, LUA_SOCKET_MT);
}

static int lua_socket_tcp_close_impl(lua_State *L, lua_socket_tcp_t *tcp)
{
    if (tcp->fd >= 0) {
        close(tcp->fd);
        tcp->fd = -1;
    }
    tcp->connected = false;
    (void)L;
    return 0;
}

static int lua_socket_tcp_gc(lua_State *L)
{
    return lua_socket_tcp_close_impl(L, lua_socket_tcp_check(L, 1));
}

static int lua_socket_tcp_tostring(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);

    lua_pushfstring(L, "tcp{%d}", tcp->fd);
    return 1;
}

static int lua_socket_tcp_settimeout(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    int timeout_ms = -1;

    if (!lua_isnoneornil(L, 2)) {
        lua_Number seconds = luaL_checknumber(L, 2);

        timeout_ms = (int)(seconds * 1000.0);
        if (timeout_ms < 0) {
            timeout_ms = -1;
        }
    }
    tcp->timeout_ms = timeout_ms;
    if (tcp->fd >= 0) {
        lua_socket_set_fd_timeout(tcp->fd, timeout_ms);
    }
    return 0;
}

static int lua_socket_tcp_connect(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    const char *host = luaL_checkstring(L, 2);
    int port = (int)luaL_checkinteger(L, 3);
    struct in_addr addr;
    struct sockaddr_in sa;

    if (port <= 0 || port > 65535) {
        return luaL_error(L, "port must be 1..65535");
    }
    if (tcp->fd >= 0) {
        close(tcp->fd);
        tcp->fd = -1;
        tcp->connected = false;
    }
    if (lua_socket_resolve_ipv4(host, &addr) != 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot resolve host '%s'", host);
        return 2;
    }

    tcp->fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (tcp->fd < 0) {
        return lua_socket_push_error(L, "socket create failed");
    }
    lua_socket_set_fd_timeout(tcp->fd, tcp->timeout_ms);

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr = addr;
    if (connect(tcp->fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        int saved = errno;

        close(tcp->fd);
        tcp->fd = -1;
        errno = saved;
        return lua_socket_push_error(L, "connect failed");
    }

    tcp->connected = true;
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_socket_tcp_send(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    size_t data_len = 0;
    const char *data = luaL_checklstring(L, 2, &data_len);
    size_t sent_total = 0;

    if (tcp->fd < 0 || !tcp->connected) {
        lua_pushnil(L);
        lua_pushstring(L, "closed");
        return 2;
    }

    while (sent_total < data_len) {
        size_t chunk = data_len - sent_total;
        ssize_t n;

        if (chunk > LUA_SOCKET_SEND_CHUNK) {
            chunk = LUA_SOCKET_SEND_CHUNK;
        }
        n = send(tcp->fd, data + sent_total, chunk, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (sent_total > 0) {
                break;
            }
            return lua_socket_push_error(L, "send failed");
        }
        if (n == 0) {
            break;
        }
        sent_total += (size_t)n;
    }

    lua_pushinteger(L, (lua_Integer)sent_total);
    if (sent_total < data_len) {
        lua_pushstring(L, "timeout");
        return 2;
    }
    return 1;
}

static int lua_socket_tcp_receive(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    size_t want = LUA_SOCKET_RECV_DEFAULT;
    bool want_all = false;
    luaL_Buffer buf;
    size_t got = 0;

    if (tcp->fd < 0 || !tcp->connected) {
        lua_pushnil(L);
        lua_pushstring(L, "closed");
        return 2;
    }

    if (lua_type(L, 2) == LUA_TSTRING) {
        const char *pattern = lua_tostring(L, 2);

        if (strcmp(pattern, "*a") == 0 || strcmp(pattern, "*all") == 0) {
            want_all = true;
        } else if (strcmp(pattern, "*l") == 0 || strcmp(pattern, "*line") == 0) {
            /* Line mode: read until newline, max one default buffer. */
            char line[LUA_SOCKET_RECV_DEFAULT];
            size_t line_len = 0;

            while (line_len + 1 < sizeof(line)) {
                ssize_t n = recv(tcp->fd, line + line_len, 1, 0);

                if (n < 0) {
                    if (errno == EINTR) {
                        continue;
                    }
                    if (line_len > 0) {
                        break;
                    }
                    return lua_socket_push_error(L, "receive failed");
                }
                if (n == 0) {
                    break;
                }
                if (line[line_len] == '\n') {
                    line_len++;
                    break;
                }
                line_len++;
            }
            while (line_len > 0 && (line[line_len - 1] == '\n' || line[line_len - 1] == '\r')) {
                line_len--;
            }
            if (line_len == 0) {
                lua_pushnil(L);
                lua_pushstring(L, "closed");
                return 2;
            }
            lua_pushlstring(L, line, line_len);
            return 1;
        } else {
            want = (size_t)strtoul(pattern, NULL, 10);
            if (want == 0) {
                return luaL_error(L, "invalid receive pattern");
            }
        }
    } else if (lua_isinteger(L, 2)) {
        want = (size_t)lua_tointeger(L, 2);
    }

    if (want > LUA_SOCKET_RECV_MAX) {
        want = LUA_SOCKET_RECV_MAX;
    }
    if (want_all) {
        want = LUA_SOCKET_RECV_MAX;
    }

    luaL_buffinit(L, &buf);
    while (got < want) {
        char chunk[1024];
        size_t room = want - got;
        ssize_t n;

        if (room > sizeof(chunk)) {
            room = sizeof(chunk);
        }
        n = recv(tcp->fd, chunk, room, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (got > 0) {
                break;
            }
            return lua_socket_push_error(L, "receive failed");
        }
        if (n == 0) {
            break;
        }
        luaL_addlstring(&buf, chunk, (size_t)n);
        got += (size_t)n;
        if (!want_all && got >= want) {
            break;
        }
        if (!want_all && (size_t)n < room) {
            break;
        }
    }
    luaL_pushresult(&buf);

    if (got == 0) {
        lua_pushnil(L);
        lua_pushstring(L, "closed");
        return 2;
    }
    return 1;
}

static int lua_socket_tcp_getsockname(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    struct sockaddr_in sa;
    socklen_t len = sizeof(sa);
    char ip[INET_ADDRSTRLEN];

    if (tcp->fd < 0 || getsockname(tcp->fd, (struct sockaddr *)&sa, &len) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, "getsockname failed");
        return 2;
    }
    inet_ntop(AF_INET, &sa.sin_addr, ip, sizeof(ip));
    lua_pushstring(L, ip);
    lua_pushinteger(L, ntohs(sa.sin_port));
    return 2;
}

static int lua_socket_tcp_getpeername(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    struct sockaddr_in sa;
    socklen_t len = sizeof(sa);
    char ip[INET_ADDRSTRLEN];

    if (tcp->fd < 0 || !tcp->connected || getpeername(tcp->fd, (struct sockaddr *)&sa, &len) != 0) {
        lua_pushnil(L);
        lua_pushstring(L, "getpeername failed");
        return 2;
    }
    inet_ntop(AF_INET, &sa.sin_addr, ip, sizeof(ip));
    lua_pushstring(L, ip);
    lua_pushinteger(L, ntohs(sa.sin_port));
    return 2;
}

static int lua_socket_tcp_shutdown(lua_State *L)
{
    lua_socket_tcp_t *tcp = lua_socket_tcp_check(L, 1);
    const char *how = luaL_optstring(L, 2, "both");
    int mode = SHUT_RDWR;

    if (strcmp(how, "receive") == 0 || strcmp(how, "read") == 0) {
        mode = SHUT_RD;
    } else if (strcmp(how, "send") == 0 || strcmp(how, "write") == 0) {
        mode = SHUT_WR;
    }
    if (tcp->fd >= 0) {
        shutdown(tcp->fd, mode);
    }
    return 0;
}

static const luaL_Reg s_tcp_methods[] = {
    { "connect", lua_socket_tcp_connect },
    { "send", lua_socket_tcp_send },
    { "receive", lua_socket_tcp_receive },
    { "settimeout", lua_socket_tcp_settimeout },
    { "getsockname", lua_socket_tcp_getsockname },
    { "getpeername", lua_socket_tcp_getpeername },
    { "shutdown", lua_socket_tcp_shutdown },
    { "close", lua_socket_tcp_gc },
    { NULL, NULL },
};

/* ── UDP object ─────────────────────────────────────────────────────────── */

static lua_socket_udp_t *lua_socket_udp_check(lua_State *L, int index)
{
    return (lua_socket_udp_t *)luaL_checkudata(L, index, LUA_UDP_MT);
}

static int lua_socket_udp_close_impl(lua_State *L, lua_socket_udp_t *udp)
{
    if (udp->fd >= 0) {
        close(udp->fd);
        udp->fd = -1;
    }
    udp->peer_set = false;
    (void)L;
    return 0;
}

static int lua_socket_udp_gc(lua_State *L)
{
    return lua_socket_udp_close_impl(L, lua_socket_udp_check(L, 1));
}

static int lua_socket_udp_tostring(lua_State *L)
{
    lua_socket_udp_t *udp = lua_socket_udp_check(L, 1);

    lua_pushfstring(L, "udp{%d}", udp->fd);
    return 1;
}

static int lua_socket_udp_settimeout(lua_State *L)
{
    lua_socket_udp_t *udp = lua_socket_udp_check(L, 1);
    int timeout_ms = -1;

    if (!lua_isnoneornil(L, 2)) {
        lua_Number seconds = luaL_checknumber(L, 2);

        timeout_ms = (int)(seconds * 1000.0);
        if (timeout_ms < 0) {
            timeout_ms = -1;
        }
    }
    udp->timeout_ms = timeout_ms;
    if (udp->fd >= 0) {
        lua_socket_set_fd_timeout(udp->fd, timeout_ms);
    }
    return 0;
}

static int lua_socket_udp_setsockname(lua_State *L)
{
    lua_socket_udp_t *udp = lua_socket_udp_check(L, 1);
    const char *host = luaL_optstring(L, 2, "*");
    int port = (int)luaL_optinteger(L, 3, 0);
    struct sockaddr_in sa;

    if (udp->fd < 0) {
        udp->fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (udp->fd < 0) {
            return lua_socket_push_error(L, "udp socket create failed");
        }
        lua_socket_set_fd_timeout(udp->fd, udp->timeout_ms);
    }

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (!host[0] || strcmp(host, "*") == 0) {
        sa.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) {
        lua_pushnil(L);
        lua_pushstring(L, "invalid bind address");
        return 2;
    }
    if (bind(udp->fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        return lua_socket_push_error(L, "bind failed");
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_socket_udp_setpeername(lua_State *L)
{
    lua_socket_udp_t *udp = lua_socket_udp_check(L, 1);
    const char *host = luaL_checkstring(L, 2);
    int port = (int)luaL_checkinteger(L, 3);
    struct in_addr addr;
    struct sockaddr_in sa;

    if (port <= 0 || port > 65535) {
        return luaL_error(L, "port must be 1..65535");
    }
    if (udp->fd < 0) {
        udp->fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (udp->fd < 0) {
            return lua_socket_push_error(L, "udp socket create failed");
        }
        lua_socket_set_fd_timeout(udp->fd, udp->timeout_ms);
    }
    if (lua_socket_resolve_ipv4(host, &addr) != 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot resolve host '%s'", host);
        return 2;
    }

    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    sa.sin_addr = addr;
    if (connect(udp->fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        return lua_socket_push_error(L, "setpeername failed");
    }
    udp->peer_set = true;
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_socket_udp_send(lua_State *L)
{
    lua_socket_udp_t *udp = lua_socket_udp_check(L, 1);
    size_t data_len = 0;
    const char *data = luaL_checklstring(L, 2, &data_len);
    ssize_t n;

    if (udp->fd < 0) {
        return luaL_error(L, "udp socket not bound/created; call setsockname or setpeername first");
    }
    n = send(udp->fd, data, data_len, 0);
    if (n < 0) {
        return lua_socket_push_error(L, "udp send failed");
    }
    lua_pushinteger(L, (lua_Integer)n);
    return 1;
}

static int lua_socket_udp_receive(lua_State *L)
{
    lua_socket_udp_t *udp = lua_socket_udp_check(L, 1);
    size_t want = (size_t)luaL_optinteger(L, 2, LUA_SOCKET_RECV_DEFAULT);
    char *buf;
    ssize_t n;

    if (want == 0 || want > LUA_SOCKET_RECV_MAX) {
        want = 2048;
    }
    if (udp->fd < 0) {
        return luaL_error(L, "udp socket not bound/created; call setsockname or setpeername first");
    }
    buf = malloc(want);
    if (!buf) {
        return luaL_error(L, "out of memory");
    }
    n = recv(udp->fd, buf, want, 0);
    if (n < 0) {
        free(buf);
        return lua_socket_push_error(L, "udp receive failed");
    }
    lua_pushlstring(L, buf, (size_t)n);
    free(buf);
    return 1;
}

static const luaL_Reg s_udp_methods[] = {
    { "setsockname", lua_socket_udp_setsockname },
    { "setpeername", lua_socket_udp_setpeername },
    { "send", lua_socket_udp_send },
    { "receive", lua_socket_udp_receive },
    { "settimeout", lua_socket_udp_settimeout },
    { "close", lua_socket_udp_gc },
    { NULL, NULL },
};

/* ── Module constructors / helpers ──────────────────────────────────────── */

static void lua_socket_register_metatable(lua_State *L,
                                          const char *mt_name,
                                          const luaL_Reg *methods,
                                          lua_CFunction gc,
                                          lua_CFunction tostring)
{
    luaL_newmetatable(L, mt_name);
    luaL_setfuncs(L, methods, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, gc);
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, tostring);
    lua_setfield(L, -2, "__tostring");
    lua_pop(L, 1);
}

static int lua_socket_tcp_new(lua_State *L)
{
    lua_socket_tcp_t *tcp = (lua_socket_tcp_t *)lua_newuserdata(L, sizeof(*tcp));

    tcp->fd = -1;
    tcp->timeout_ms = -1;
    tcp->connected = false;
    luaL_setmetatable(L, LUA_SOCKET_MT);
    return 1;
}

static int lua_socket_udp_new(lua_State *L)
{
    lua_socket_udp_t *udp = (lua_socket_udp_t *)lua_newuserdata(L, sizeof(*udp));

    udp->fd = -1;
    udp->timeout_ms = -1;
    udp->peer_set = false;
    luaL_setmetatable(L, LUA_UDP_MT);
    return 1;
}

static int lua_socket_dns_toip(lua_State *L)
{
    const char *host = luaL_checkstring(L, 1);
    struct in_addr addr;
    char ip[INET_ADDRSTRLEN];

    if (lua_socket_resolve_ipv4(host, &addr) != 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "cannot resolve host '%s'", host);
        return 2;
    }
    inet_ntop(AF_INET, &addr, ip, sizeof(ip));
    lua_pushstring(L, ip);
    return 1;
}

static int lua_socket_gettime(lua_State *L)
{
    struct timeval tv;

    gettimeofday(&tv, NULL);
    lua_pushnumber(L, (lua_Number)tv.tv_sec + (lua_Number)tv.tv_usec / 1000000.0);
    return 1;
}

static int lua_socket_select(lua_State *L)
{
    /* socket.select(recvt, sendt [, timeout]) -> recvt, sendt, err */
    fd_set recv_set;
    fd_set send_set;
    int max_fd = -1;
    int table_idx;
    int ntables;
    double timeout_sec = -1.0;
    struct timeval tv;
    struct timeval *tv_ptr = NULL;
    int n;
    int out_slot;

    if (!lua_istable(L, 1) && !lua_isnil(L, 1)) {
        return luaL_error(L, "select expects a table of sockets for recvt");
    }
    if (!lua_istable(L, 2) && !lua_isnil(L, 2)) {
        return luaL_error(L, "select expects a table of sockets for sendt");
    }
    if (!lua_isnoneornil(L, 3)) {
        timeout_sec = luaL_checknumber(L, 3);
    }

    FD_ZERO(&recv_set);
    FD_ZERO(&send_set);

    for (ntables = 0; ntables < 2; ntables++) {
        table_idx = ntables + 1;
        if (lua_isnil(L, table_idx) || !lua_istable(L, table_idx)) {
            continue;
        }
        lua_pushnil(L);
        while (lua_next(L, table_idx) != 0) {
            int fd = -1;

            if (luaL_testudata(L, -1, LUA_SOCKET_MT)) {
                fd = lua_socket_tcp_check(L, -1)->fd;
            } else if (luaL_testudata(L, -1, LUA_UDP_MT)) {
                fd = lua_socket_udp_check(L, -1)->fd;
            }
            if (fd >= 0) {
                if (ntables == 0) {
                    FD_SET(fd, &recv_set);
                } else {
                    FD_SET(fd, &send_set);
                }
                if (fd > max_fd) {
                    max_fd = fd;
                }
            }
            lua_pop(L, 1);
        }
    }

    if (max_fd < 0) {
        lua_pushvalue(L, 1);
        lua_pushvalue(L, 2);
        lua_pushstring(L, "timeout");
        return 3;
    }

    if (timeout_sec >= 0) {
        tv.tv_sec = (time_t)timeout_sec;
        tv.tv_usec = (long)((timeout_sec - (double)tv.tv_sec) * 1000000.0);
        tv_ptr = &tv;
    }

    n = select(max_fd + 1, &recv_set, &send_set, NULL, tv_ptr);
    if (n < 0) {
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushstring(L, strerror(errno));
        return 3;
    }
    if (n == 0) {
        lua_newtable(L);
        lua_newtable(L);
        lua_pushstring(L, "timeout");
        return 3;
    }

    /* Rebuild filtered tables. */
    lua_newtable(L); /* recvt out */
    out_slot = 1;
    if (lua_istable(L, 1)) {
        lua_pushnil(L);
        while (lua_next(L, 1) != 0) {
            int fd = -1;

            if (luaL_testudata(L, -1, LUA_SOCKET_MT)) {
                fd = lua_socket_tcp_check(L, -1)->fd;
            } else if (luaL_testudata(L, -1, LUA_UDP_MT)) {
                fd = lua_socket_udp_check(L, -1)->fd;
            }
            if (fd >= 0 && FD_ISSET(fd, &recv_set)) {
                lua_pushvalue(L, -1);
                lua_rawseti(L, -3, out_slot++);
            }
            lua_pop(L, 1);
        }
    }

    lua_newtable(L); /* sendt out */
    out_slot = 1;
    if (lua_istable(L, 2)) {
        lua_pushnil(L);
        while (lua_next(L, 2) != 0) {
            int fd = -1;

            if (luaL_testudata(L, -1, LUA_SOCKET_MT)) {
                fd = lua_socket_tcp_check(L, -1)->fd;
            } else if (luaL_testudata(L, -1, LUA_UDP_MT)) {
                fd = lua_socket_udp_check(L, -1)->fd;
            }
            if (fd >= 0 && FD_ISSET(fd, &send_set)) {
                lua_pushvalue(L, -1);
                lua_rawseti(L, -3, out_slot++);
            }
            lua_pop(L, 1);
        }
    }

    return 2;
}

static const luaL_Reg s_socket_funcs[] = {
    { "tcp", lua_socket_tcp_new },
    { "udp", lua_socket_udp_new },
    { "select", lua_socket_select },
    { "gettime", lua_socket_gettime },
    { NULL, NULL },
};

static const luaL_Reg s_dns_funcs[] = {
    { "toip", lua_socket_dns_toip },
    { NULL, NULL },
};

int luaopen_socket(lua_State *L)
{
    lua_socket_register_metatable(L, LUA_SOCKET_MT, s_tcp_methods, lua_socket_tcp_gc, lua_socket_tcp_tostring);
    lua_socket_register_metatable(L, LUA_UDP_MT, s_udp_methods, lua_socket_udp_gc, lua_socket_udp_tostring);

    luaL_newlib(L, s_socket_funcs);

    luaL_newlib(L, s_dns_funcs);
    lua_setfield(L, -2, "dns");

    lua_pushstring(L, "ESP-Claw luasocket-subset/1.0");
    lua_setfield(L, -2, "_VERSION");
    return 1;
}

esp_err_t lua_module_socket_register(void)
{
    return cap_lua_register_module("socket", luaopen_socket);
}
