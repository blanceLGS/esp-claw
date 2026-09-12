# Common Gotchas

## Capability and Lua selection are config-driven

Enabled capability groups, LLM-visible groups, and enabled Lua modules come from app configuration. Empty selections usually mean "use defaults" or "enable available modules"; unknown tokens are ignored with warnings.

When adding a new capability group or Lua module, update the app registration table and the relevant Kconfig/default configuration path.

## Lua driver READMEs are for agents

`components/lua_modules/lua_driver_xxx/README.md` files are agent-facing documentation. They explain how an agent should use the Lua driver and are meant to be read as operating instructions, not as user marketing docs or full developer manuals.

Keep these READMEs concise, capability-oriented, and accurate for runtime Lua usage.

## Windows firmware builds need response files

Include paths for `edge_agent` make compile lines exceed CreateProcess limits. Project `CMakeLists.txt` sets `set(CMAKE_NINJA_FORCE_RESPONSE_FILE ON)` before `project()`. Removing this breaks Windows ninja builds with `CreateProcess: The parameter is incorrect`.

## SoftAP is not internet by itself

Starting SoftAP does not share STA internet. Enable `CONFIG_LWIP_IP_FORWARD` + `CONFIG_LWIP_IPV4_NAPT` and call `esp_netif_napt_enable(AP)` after STA gets IP. Also relay DNS to AP DHCP clients.

## Board custom devices vs display_lcd types

If `board_devices.yaml` uses `type: custom`, board `setup_device.c` must use `gen_board_device_custom.h` types. Using `dev_display_lcd_config_t` fails to compile unless a real `display_lcd` device is declared and `CONFIG_ESP_BOARD_DEV_DISPLAY_LCD_SUPPORT` is enabled.
