/*
 * Minimal crypto helpers for iFlytek IAT auth (HMAC-SHA256 + base64).
 */
#include "lua_module_crypto.h"

#include <stdlib.h>
#include <string.h>

#include "cap_lua.h"
#include "esp_check.h"
#include "lauxlib.h"
#include "mbedtls/base64.h"
#include "mbedtls/md.h"

static int lua_crypto_hmac_sha256(lua_State *L)
{
    size_t key_len = 0;
    size_t msg_len = 0;
    const char *key = luaL_checklstring(L, 1, &key_len);
    const char *msg = luaL_checklstring(L, 2, &msg_len);
    unsigned char out[32];
    size_t out_len = 0;
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);

    if (!key || !msg || !info) {
        return luaL_error(L, "crypto.hmac_sha256: invalid args");
    }
    if (mbedtls_md_hmac(info,
                        (const unsigned char *)key,
                        key_len,
                        (const unsigned char *)msg,
                        msg_len,
                        out) != 0) {
        return luaL_error(L, "crypto.hmac_sha256: hmac failed");
    }
    out_len = 32;
    lua_pushlstring(L, (const char *)out, out_len);
    return 1;
}

static int lua_crypto_base64_encode(lua_State *L)
{
    size_t in_len = 0;
    const char *in = luaL_checklstring(L, 1, &in_len);
    size_t need = 0;
    size_t written = 0;
    unsigned char *buf = NULL;

    if (!in) {
        return luaL_error(L, "crypto.base64_encode: invalid input");
    }
    if (mbedtls_base64_encode(NULL, 0, &need, (const unsigned char *)in, in_len) != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL) {
        /* empty input */
        lua_pushliteral(L, "");
        return 1;
    }
    buf = malloc(need + 1);
    if (!buf) {
        return luaL_error(L, "crypto.base64_encode: out of memory");
    }
    if (mbedtls_base64_encode(buf, need, &written, (const unsigned char *)in, in_len) != 0) {
        free(buf);
        return luaL_error(L, "crypto.base64_encode: encode failed");
    }
    lua_pushlstring(L, (const char *)buf, written);
    free(buf);
    return 1;
}

static int lua_crypto_base64_decode(lua_State *L)
{
    size_t in_len = 0;
    const char *in = luaL_checklstring(L, 1, &in_len);
    size_t need = 0;
    size_t written = 0;
    unsigned char *buf = NULL;

    if (!in) {
        return luaL_error(L, "crypto.base64_decode: invalid input");
    }
    if (mbedtls_base64_decode(NULL, 0, &need, (const unsigned char *)in, in_len) !=
            MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL) {
        lua_pushliteral(L, "");
        return 1;
    }
    buf = malloc(need + 1);
    if (!buf) {
        return luaL_error(L, "crypto.base64_decode: out of memory");
    }
    if (mbedtls_base64_decode(buf, need, &written, (const unsigned char *)in, in_len) != 0) {
        free(buf);
        return luaL_error(L, "crypto.base64_decode: decode failed");
    }
    lua_pushlstring(L, (const char *)buf, written);
    free(buf);
    return 1;
}

int luaopen_crypto(lua_State *L)
{
    lua_newtable(L);
    lua_pushcfunction(L, lua_crypto_hmac_sha256);
    lua_setfield(L, -2, "hmac_sha256");
    lua_pushcfunction(L, lua_crypto_base64_encode);
    lua_setfield(L, -2, "base64_encode");
    lua_pushcfunction(L, lua_crypto_base64_decode);
    lua_setfield(L, -2, "base64_decode");
    return 1;
}

esp_err_t lua_module_crypto_register(void)
{
    return cap_lua_register_module("crypto", luaopen_crypto);
}
