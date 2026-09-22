/*
 * SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * High-level Lua WebSocket client on top of esp_websocket_client.
 */
#include "lua_module_websocket.h"

#include <stdlib.h>
#include <string.h>

#include "cap_lua.h"
#include "esp_crt_bundle.h"
#include "esp_log.h"
#include "esp_transport_ws.h"
#include "esp_websocket_client.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

static const char *TAG = "lua_module_websocket";

#define LUA_WS_MT "websocket.client"
/* iFlytek IAT auth query is long (base64 authorization + date + host). */
#define LUA_WS_URI_MAX 768
#define LUA_WS_HEADER_MAX 8
#define LUA_WS_QUEUE_LEN 8
#define LUA_WS_PAYLOAD_MAX (32 * 1024)
#define LUA_WS_CONNECT_DEFAULT_MS 10000
#define LUA_WS_RECV_DEFAULT_MS 5000

typedef enum {
    LUA_WS_MSG_TEXT = 1,
    LUA_WS_MSG_BINARY = 2,
    LUA_WS_MSG_CLOSE = 8,
    LUA_WS_MSG_PING = 9,
    LUA_WS_MSG_PONG = 10,
} lua_ws_msg_opcode_t;

typedef struct {
    int opcode;
    size_t len;
    char *data;
} lua_ws_msg_t;

typedef struct {
    esp_websocket_client_handle_t client;
    QueueHandle_t queue;
    SemaphoreHandle_t lock;
    char uri[LUA_WS_URI_MAX];
    char extra_headers_blob[768];
    size_t extra_header_count;
    int connect_timeout_ms;
    int recv_timeout_ms;
    bool connected;
    bool started;
    bool destroyed;
} lua_ws_client_t;

static void lua_ws_msg_free(lua_ws_msg_t *msg)
{
    if (!msg) {
        return;
    }
    free(msg->data);
    free(msg);
}

static void lua_ws_queue_clear(QueueHandle_t queue)
{
    lua_ws_msg_t *msg = NULL;

    if (!queue) {
        return;
    }
    while (xQueueReceive(queue, &msg, 0) == pdTRUE) {
        lua_ws_msg_free(msg);
    }
}

static int lua_ws_push_error(lua_State *L, const char *message)
{
    lua_pushnil(L);
    lua_pushstring(L, message ? message : "websocket error");
    return 2;
}

static void lua_ws_on_event(void *handler_args, esp_event_base_t base, int32_t event_id, void *event_data)
{
    lua_ws_client_t *ws = (lua_ws_client_t *)handler_args;
    esp_websocket_event_data_t *data = (esp_websocket_event_data_t *)event_data;

    (void)base;
    if (!ws) {
        return;
    }

    switch (event_id) {
    case WEBSOCKET_EVENT_CONNECTED:
        xSemaphoreTake(ws->lock, portMAX_DELAY);
        ws->connected = true;
        xSemaphoreGive(ws->lock);
        ESP_LOGI(TAG, "connected to %s", ws->uri);
        break;
    case WEBSOCKET_EVENT_DISCONNECTED:
        xSemaphoreTake(ws->lock, portMAX_DELAY);
        ws->connected = false;
        xSemaphoreGive(ws->lock);
        ESP_LOGW(TAG, "disconnected from %s", ws->uri);
        break;
    case WEBSOCKET_EVENT_DATA:
    case WEBSOCKET_EVENT_ERROR:
        if (event_id == WEBSOCKET_EVENT_DATA && data) {
            lua_ws_msg_t *msg = NULL;
            const char *payload = data->data_ptr;
            size_t payload_len = (size_t)data->data_len;

            if (!payload || payload_len == 0) {
                break;
            }
            if (payload_len > LUA_WS_PAYLOAD_MAX) {
                ESP_LOGW(TAG, "drop oversized ws payload len=%u", (unsigned)payload_len);
                break;
            }
            msg = calloc(1, sizeof(*msg));
            if (!msg) {
                ESP_LOGE(TAG, "oom allocating ws message");
                break;
            }
            msg->data = malloc(payload_len + 1);
            if (!msg->data) {
                free(msg);
                ESP_LOGE(TAG, "oom allocating ws payload");
                break;
            }
            memcpy(msg->data, payload, payload_len);
            msg->data[payload_len] = '\0';
            msg->len = payload_len;
            /* RFC6455 opcodes: 1 text, 2 binary, 8 close, 9 ping, 10 pong */
            if (data->op_code == 0x2) {
                msg->opcode = LUA_WS_MSG_BINARY;
            } else if (data->op_code == 0x8) {
                msg->opcode = LUA_WS_MSG_CLOSE;
            } else if (data->op_code == 0x9) {
                msg->opcode = LUA_WS_MSG_PING;
            } else if (data->op_code == 0xA) {
                msg->opcode = LUA_WS_MSG_PONG;
            } else {
                msg->opcode = LUA_WS_MSG_TEXT;
            }

            if (ws->queue) {
                if (xQueueSend(ws->queue, &msg, 0) != pdTRUE) {
                    lua_ws_msg_t *old = NULL;

                    if (xQueueReceive(ws->queue, &old, 0) == pdTRUE) {
                        lua_ws_msg_free(old);
                    }
                    if (xQueueSend(ws->queue, &msg, 0) != pdTRUE) {
                        lua_ws_msg_free(msg);
                    }
                }
            } else {
                lua_ws_msg_free(msg);
            }
        } else if (event_id == WEBSOCKET_EVENT_ERROR) {
            ESP_LOGE(TAG, "websocket transport error");
        }
        break;
    default:
        break;
    }
}

static const char *lua_ws_opcode_name(int opcode)
{
    switch (opcode) {
    case LUA_WS_MSG_TEXT:
        return "text";
    case LUA_WS_MSG_BINARY:
        return "binary";
    case LUA_WS_MSG_CLOSE:
        return "close";
    case LUA_WS_MSG_PING:
        return "ping";
    case LUA_WS_MSG_PONG:
        return "pong";
    default:
        return "unknown";
    }
}

static lua_ws_client_t *lua_ws_check(lua_State *L, int index)
{
    return (lua_ws_client_t *)luaL_checkudata(L, index, LUA_WS_MT);
}

static void lua_ws_destroy_locked(lua_ws_client_t *ws)
{
    if (!ws || ws->destroyed) {
        return;
    }
    if (ws->client) {
        esp_websocket_client_stop(ws->client);
        esp_websocket_client_destroy(ws->client);
        ws->client = NULL;
    }
    ws->connected = false;
    ws->started = false;
    ws->destroyed = true;
    if (ws->queue) {
        lua_ws_queue_clear(ws->queue);
    }
}

static int lua_ws_close(lua_State *L)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);

    if (ws->lock) {
        xSemaphoreTake(ws->lock, portMAX_DELAY);
        lua_ws_destroy_locked(ws);
        xSemaphoreGive(ws->lock);
    } else {
        lua_ws_destroy_locked(ws);
    }
    return 0;
}

static int lua_ws_gc(lua_State *L)
{
    return lua_ws_close(L);
}

static int lua_ws_tostring(lua_State *L)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);

    lua_pushfstring(L, "websocket{%s,%s}", ws->uri[0] ? ws->uri : "-", ws->connected ? "connected" : "closed");
    return 1;
}

static int lua_ws_is_connected(lua_State *L)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);
    bool connected = false;

    if (ws->lock) {
        xSemaphoreTake(ws->lock, portMAX_DELAY);
        connected = ws->connected && ws->client && esp_websocket_client_is_connected(ws->client);
        xSemaphoreGive(ws->lock);
    }
    lua_pushboolean(L, connected ? 1 : 0);
    return 1;
}

static int lua_ws_send_impl(lua_State *L, bool binary)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);
    size_t len = 0;
    const char *data = luaL_checklstring(L, 2, &len);
    int timeout_ms = ws->recv_timeout_ms;
    int sent;

    if (!lua_isnoneornil(L, 3)) {
        timeout_ms = (int)(luaL_checknumber(L, 3) * 1000.0);
        if (timeout_ms < 0) {
            timeout_ms = ws->recv_timeout_ms;
        }
    }
    if (!ws->client || !ws->connected) {
        return lua_ws_push_error(L, "not connected");
    }

    if (binary) {
        sent = esp_websocket_client_send_bin(ws->client, data, len, pdMS_TO_TICKS(timeout_ms));
    } else {
        sent = esp_websocket_client_send_text(ws->client, data, len, pdMS_TO_TICKS(timeout_ms));
    }
    if (sent < 0) {
        return lua_ws_push_error(L, "send failed");
    }
    lua_pushinteger(L, sent);
    return 1;
}

static int lua_ws_send(lua_State *L)
{
    return lua_ws_send_impl(L, false);
}

static int lua_ws_send_bin(lua_State *L)
{
    return lua_ws_send_impl(L, true);
}

static int lua_ws_ping(lua_State *L)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);
    size_t len = 0;
    const char *data = luaL_optlstring(L, 2, "", &len);
    int timeout_ms = ws->recv_timeout_ms;
    int sent;

    if (!ws->client || !ws->connected) {
        return lua_ws_push_error(L, "not connected");
    }
    sent = esp_websocket_client_send_with_opcode(ws->client,
                                                         WS_TRANSPORT_OPCODES_PING,
                                                         (const uint8_t *)data,
                                                         (int)len,
                                                         pdMS_TO_TICKS(timeout_ms));
    if (sent < 0) {
        return lua_ws_push_error(L, "ping failed");
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_ws_receive(lua_State *L)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);
    int timeout_ms = ws->recv_timeout_ms;
    lua_ws_msg_t *msg = NULL;

    if (!lua_isnoneornil(L, 2)) {
        timeout_ms = (int)(luaL_checknumber(L, 2) * 1000.0);
        if (timeout_ms < 0) {
            timeout_ms = 0;
        }
    }
    if (!ws->queue) {
        return lua_ws_push_error(L, "client closed");
    }
    if (!ws->connected && uxQueueMessagesWaiting(ws->queue) == 0) {
        return lua_ws_push_error(L, "closed");
    }

    if (xQueueReceive(ws->queue, &msg, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) {
        lua_pushnil(L);
        lua_pushstring(L, "timeout");
        return 2;
    }

    if (msg->opcode == LUA_WS_MSG_CLOSE) {
        const char *payload = msg->data ? msg->data : "";

        lua_ws_msg_free(msg);
        lua_pushnil(L);
        lua_pushstring(L, "closed");
        if (payload[0]) {
            lua_pushstring(L, payload);
            return 3;
        }
        return 2;
    }

    lua_pushlstring(L, msg->data ? msg->data : "", msg->len);
    lua_pushstring(L, lua_ws_opcode_name(msg->opcode));
    lua_ws_msg_free(msg);
    return 2;
}

static int lua_ws_settimeout(lua_State *L)
{
    lua_ws_client_t *ws = lua_ws_check(L, 1);

    if (lua_isnoneornil(L, 2)) {
        ws->recv_timeout_ms = LUA_WS_RECV_DEFAULT_MS;
    } else {
        int timeout_ms = (int)(luaL_checknumber(L, 2) * 1000.0);

        ws->recv_timeout_ms = timeout_ms > 0 ? timeout_ms : 0;
    }
    return 0;
}

static const luaL_Reg s_ws_methods[] = {
    { "send", lua_ws_send },
    { "send_bin", lua_ws_send_bin },
    { "receive", lua_ws_receive },
    { "ping", lua_ws_ping },
    { "settimeout", lua_ws_settimeout },
    { "is_connected", lua_ws_is_connected },
    { "close", lua_ws_close },
    { NULL, NULL },
};

static bool lua_ws_uri_supported(const char *uri)
{
    return uri &&
           (strncmp(uri, "ws://", 5) == 0 || strncmp(uri, "wss://", 6) == 0);
}

static void lua_ws_collect_headers(lua_State *L, int table_index, lua_ws_client_t *ws)
{
    size_t used;

    if (!lua_istable(L, table_index)) {
        return;
    }
    ws->extra_headers_blob[0] = '\0';
    used = 0;
    lua_pushnil(L);
    while (lua_next(L, table_index) != 0 && ws->extra_header_count < LUA_WS_HEADER_MAX) {
        if (lua_type(L, -2) == LUA_TSTRING && lua_type(L, -1) == LUA_TSTRING) {
            const char *key = lua_tostring(L, -2);
            const char *value = lua_tostring(L, -1);
            int written = snprintf(ws->extra_headers_blob + used,
                                   sizeof(ws->extra_headers_blob) - used,
                                   "%s: %s\r\n",
                                   key,
                                   value);

            if (written > 0 && (size_t)written < sizeof(ws->extra_headers_blob) - used) {
                used += (size_t)written;
                ws->extra_header_count++;
            }
        }
        lua_pop(L, 1);
    }
}

static int lua_ws_wait_connected(lua_ws_client_t *ws, int timeout_ms)
{
    int waited = 0;

    while (waited <= timeout_ms) {
        bool connected = false;

        xSemaphoreTake(ws->lock, portMAX_DELAY);
        connected = ws->connected;
        xSemaphoreGive(ws->lock);
        if (connected) {
            return 0;
        }
        if (ws->client && esp_websocket_client_is_connected(ws->client)) {
            return 0;
        }
        vTaskDelay(pdMS_TO_TICKS(50));
        waited += 50;
    }
    return -1;
}

/*
 * websocket.connect(uri [, opts]) -> client | nil, err
 * opts.timeout (seconds), opts.headers (table)
 */
static int lua_ws_connect(lua_State *L)
{
    const char *uri = luaL_checkstring(L, 1);
    lua_ws_client_t *ws = NULL;
    esp_websocket_client_config_t config = {0};

    if (!lua_ws_uri_supported(uri)) {
        return luaL_error(L, "uri must start with ws:// or wss://");
    }
    if (strlen(uri) >= LUA_WS_URI_MAX) {
        return luaL_error(L, "uri too long");
    }

    ws = (lua_ws_client_t *)lua_newuserdata(L, sizeof(*ws));
    memset(ws, 0, sizeof(*ws));
    ws->connect_timeout_ms = LUA_WS_CONNECT_DEFAULT_MS;
    ws->recv_timeout_ms = LUA_WS_RECV_DEFAULT_MS;
    strlcpy(ws->uri, uri, sizeof(ws->uri));
    luaL_setmetatable(L, LUA_WS_MT);

    ws->queue = xQueueCreate(LUA_WS_QUEUE_LEN, sizeof(lua_ws_msg_t *));
    ws->lock = xSemaphoreCreateMutex();
    if (!ws->queue || !ws->lock) {
        if (ws->queue) {
            vQueueDelete(ws->queue);
        }
        if (ws->lock) {
            vSemaphoreDelete(ws->lock);
        }
        ws->queue = NULL;
        ws->lock = NULL;
        return luaL_error(L, "out of memory");
    }

    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "timeout");
        if (lua_isnumber(L, -1)) {
            int timeout_ms = (int)(lua_tonumber(L, -1) * 1000.0);

            if (timeout_ms > 0) {
                ws->connect_timeout_ms = timeout_ms;
                ws->recv_timeout_ms = timeout_ms;
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 2, "headers");
        lua_ws_collect_headers(L, lua_gettop(L), ws);
        lua_pop(L, 1);
    }

    config.uri = ws->uri;
    /* IAT/TTS JSON+base64 frames exceed 2KB. */
    config.buffer_size = 4096;
    config.task_stack = 6144;
    config.task_prio = 5;
    config.network_timeout_ms = (uint32_t)ws->connect_timeout_ms;
    config.disable_auto_reconnect = true;
    config.keep_alive_enable = true;
    config.keep_alive_idle = 5;
    config.keep_alive_interval = 5;
    config.keep_alive_count = 3;
    if (ws->extra_header_count > 0 && ws->extra_headers_blob[0]) {
        config.headers = ws->extra_headers_blob;
    }
    if (strncmp(ws->uri, "wss://", 6) == 0) {
        config.crt_bundle_attach = esp_crt_bundle_attach;
    }

    ws->client = esp_websocket_client_init(&config);
    if (!ws->client) {
        lua_ws_destroy_locked(ws);
        return lua_ws_push_error(L, "websocket client init failed");
    }

    if (esp_websocket_register_events(ws->client, WEBSOCKET_EVENT_ANY, lua_ws_on_event, ws) != ESP_OK) {
        lua_ws_destroy_locked(ws);
        return lua_ws_push_error(L, "websocket register events failed");
    }
    if (esp_websocket_client_start(ws->client) != ESP_OK) {
        lua_ws_destroy_locked(ws);
        return lua_ws_push_error(L, "websocket start failed");
    }
    ws->started = true;

    if (lua_ws_wait_connected(ws, ws->connect_timeout_ms) != 0) {
        ESP_LOGW(TAG, "connect timeout for %s", ws->uri);
        lua_ws_destroy_locked(ws);
        return lua_ws_push_error(L, "connect timeout");
    }

    return 1;
}

static const luaL_Reg s_ws_funcs[] = {
    { "connect", lua_ws_connect },
    { NULL, NULL },
};

static void lua_ws_register_metatable(lua_State *L)
{
    luaL_newmetatable(L, LUA_WS_MT);
    luaL_setfuncs(L, s_ws_methods, 0);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, lua_ws_gc);
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, lua_ws_tostring);
    lua_setfield(L, -2, "__tostring");
    lua_pop(L, 1);
}

int luaopen_websocket(lua_State *L)
{
    lua_ws_register_metatable(L);
    luaL_newlib(L, s_ws_funcs);
    lua_pushstring(L, "ESP-Claw websocket-client/1.0");
    lua_setfield(L, -2, "_VERSION");
    return 1;
}

esp_err_t lua_module_websocket_register(void)
{
    return cap_lua_register_module("websocket", luaopen_websocket);
}
