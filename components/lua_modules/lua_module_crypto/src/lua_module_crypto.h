#pragma once

#include "esp_err.h"
#include "lauxlib.h"

#ifdef __cplusplus
extern "C" {
#endif

int luaopen_crypto(lua_State *L);
esp_err_t lua_module_crypto_register(void);

#ifdef __cplusplus
}
#endif
