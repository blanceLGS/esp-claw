# Agents.md

This file provides guidance to agents when working with code in this repository.

## Project Overview

ESP-Claw is an ESP-IDF firmware project for running an AI agent framework on Espressif IoT devices. The main application is `application/edge_agent/`; reusable firmware components live under `components/`. The repo also contains board definitions, build-time FATFS content, documentation, and the embedded device settings UI.

## Development Commands

Export ESP-IDF before firmware work:

```bash
. $IDF_PATH/export.sh
```

Generate board manager files and build from the app directory:

```bash
cd application/edge_agent
idf.py bmgr -c ./boards -b esp32_S3_DevKitC_1
idf.py build
idf.py flash monitor
```

Windows (ESP-IDF PowerShell profile, example paths):

```powershell
. "C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1"
cd application\edge_agent
$env:IDF_CCACHE_ENABLE = "0"   # optional; shortens command lines
idf.py bmgr -c ./boards -b waveshare_ESP32_S3_RLCD_4_2
idf.py build
```

If ninja fails with `CreateProcess: The parameter is incorrect` (command line too long), keep `CMAKE_NINJA_FORCE_RESPONSE_FILE ON` in `application/edge_agent/CMakeLists.txt` (already set). Do not remove it for Windows builds.

Docs site:

```bash
cd docs
pnpm install
pnpm build
pnpm dev
```

Embedded settings UI:

```bash
cd application/edge_agent/components/http_server/frontend_source
pnpm build
pnpm typecheck
```

## High-Level Architecture

### Boot and Runtime Flow

The main entry point is `application/edge_agent/main/main.c`. 

### Core Data Flow

1. IM channels, scheduler jobs, Lua scripts, startup hooks, or CLI commands publish events or submit requests.
2. `claw_event_router` matches events against the DATA root's `router_rules/router_rules.json` and can call capabilities, run scripts, run the agent, send messages, emit events, or drop events.
3. `claw_core` builds context from memory, session history, skills, and other providers; calls the configured LLM backend; executes capability tool calls; persists context; and returns responses.
4. Outbound messages are routed back through registered IM bindings or local/web channels.

## Key Subsystems

- **Application shell** (`application/edge_agent/main/main.c`, `components/common/app_claw/`): boot flow, storage paths, capability registration, Lua module registration, CLI, and agent startup.
- **Agent core** (`components/claw_modules/claw_core/`): request queue, context building, LLM backend runtime, tool-call loop, media inference, interrupts, context persistence, and response delivery.
- **Event router** (`components/claw_modules/claw_event_router/`): declarative event routing and actions backed by router rules in FATFS.
- **Capability registry** (`components/claw_modules/claw_cap/`): common registration and dispatch layer for model-callable capabilities.
- **Capabilities** (`components/claw_capabilities/`): concrete agent capabilities such as Lua execution, files, IM platforms, MCP, skill management, router management, scheduler, session management, time, HTTP requests, web search, system, and LLM inspection.
- **Memory** (`components/claw_modules/claw_memory/`): session history, profile/long-term memory providers, memory persistence, request gating, and stage notes.
- **Skills** (`components/claw_modules/claw_skill/`, component `skills/` directories): user-facing skill documents and activation state.
- **Lua modules** (`components/lua_modules/`): Lua drivers and higher-level modules for hardware, media, HTTP server, storage, threading, JSON, board manager, capability calls, TCP/UDP sockets (`lua_module_socket`), and WebSocket client (`lua_module_websocket`).
- **Board manager** (`application/edge_agent/boards/`): board metadata, peripheral YAML, board setup code, board defaults, optional local components, and optional board FATFS overlays.
- **Wi-Fi manager** (`components/common/wifi_manager/`): STA connect/reconnect, SoftAP provisioning, and AP↔STA internet sharing via NAPT (see below).
- **FATFS images** (`application/edge_agent/fatfs_image/`): build-time source trees for the read-only SYSTEM image and writable DATA seed image.
- **HTTP config service** (`application/edge_agent/components/http_server/`): local device configuration server and embedded frontend.

### Runtime Path Rules

The firmware uses two logical filesystem roots, configured at boot through `claw_paths`:

- `CLAW_PATH_SYSTEM` is mounted at `/system`. It is read-only and contains firmware-baked skills, skill assets, built-in Lua modules, Lua docs/tests, board image overlays, and `.recovery` seed files.
- `CLAW_PATH_DATA` is the writable storage root. It is `/fatfs` when flash storage is used, or the board-manager SD card mount point when an SD card is available.
- Never hard-code `/fatfs` for writable paths in reusable code or docs. Use `claw_paths_join(CLAW_PATH_DATA, ...)` in C and `storage.get_root_dir()` plus `storage.join_path(...)` in Lua.
- Firmware-baked skill scripts must be referenced with `{CUR_SKILL_DIR}/scripts/...` inside `SKILL.md`; do not write fixed `/fatfs/skills/...` paths.
- Runtime-installed/user skills live under the DATA root's `skills/`. Firmware-baked skills live under `/system/skills/`; the skill registry scans both, with DATA skills taking priority when ids conflict.
- Router rules, scheduler rules, memory, sessions, inbox, and user-generated files live under DATA. Recovery defaults are stored under `/system/.recovery` and copied into DATA only when missing.
- Built-in Lua libraries are staged under `/system/scripts/builtin/lib`; generated Lua module docs/tests are bundled into the `builtin_lua_modules` skill and should be accessed via that skill's `{CUR_SKILL_DIR}` paths.
- Board-specific `boards/<vendor>/<board>/fatfs_image/` content overlays the SYSTEM image at build time. Board image content does not target DATA and hidden board folders are not considered.

## Project-Specific Notes

- Architecture constraints: [`design.md`](.agents/design.md)
- docs guide: [`docs.md`](.agents/docs.md)
- Common gotchas: [`gotchas.md`](.agents/gotchas.md)
- Specs (`.agents/spec/`):
  - lua module spec: [lua-module-spec.md](.agents/spec/lua-module-spec.md)
  - claw skill spec: [claw-skill-spec.md](.agents/spec/claw-skill-spec.md)

### Session slash commands must bypass the agent path

`/session new|list|switch|delete` is handled **locally** in `claw_event_router` before default agent routing (`claw_event_router_parse_local_session_command` / `claw_event_router_handle_local_session_command` in `components/claw_modules/claw_event_router/src/claw_event_router.c`). It calls capability `session_command` (`components/claw_capabilities/cap_session_mgr/`) and replies over the IM outbound path.

Do **not** route `/session` through the LLM. When session history is oversized, `claw_memory_request_gate_callback` rejects agent requests for that session and tells the user to use `/session`; routing the recovery command through the agent would block the only escape path.

Session alias maps live under DATA `sessions/chat_map/`. Delete history also removes skill session state via `app_claw_delete_session_history`.

Session history compaction (`claw_memory_session.c`):
- Cap: `CLAW_MEMORY_SESSION_SIZE_LIMIT` 150 KiB; `CLAW_MEMORY_SESSION_MAX_TURNS` 24 complete turns; `CLAW_MEMORY_SESSION_MIN_KEEP_TURNS` 6.
- Always strip tool records (keep at most `CLAW_MEMORY_SESSION_COMPACT_TOOL_TURNS`).
- If still oversized or turn count exceeds the cap, drop **oldest complete turns** (user + assistant_final) until under limit, never below the min keep window.
- Only block the session and ask for `/session new` when even the min keep window cannot fit.

### SoftAP internet sharing (NAPT)

AP clients can use the internet only after STA is connected. `wifi_manager` enables this on `IP_EVENT_STA_GOT_IP`:

- `esp_netif_set_default_netif(STA)`
- AP DHCP offers STA DNS (fallback `8.8.8.8`)
- `esp_netif_napt_enable(AP)` when `CONFIG_LWIP_IP_FORWARD` and `CONFIG_LWIP_IPV4_NAPT` are set in `application/edge_agent/sdkconfig.defaults`

If AP is up but cannot reach the internet, check STA connectivity first, then NAPT logs (`AP NAPT enabled`), then client DHCP/DNS renewal.

### waveshare_ESP32_S3_RLCD_4_2 board notes

- Panel is registered as `type: custom` in `board_devices.yaml`. `setup_device.c` must use generated custom types from `gen_board_device_custom.h` (`dev_custom_display_lcd_config_t`), not `dev_display_lcd_*`.
- Keep `set(CMAKE_NINJA_FORCE_RESPONSE_FILE ON)` in project `CMakeLists.txt` for Windows builds.

## General Engineering Rules

- Use modular design. Each module should have clear responsibilities, ownership, and boundaries.
- Keep source files under 1500 lines where practical; split files by responsibility when they grow beyond that.
- Keep functions focused and reviewable; split large functions instead of adding deeply nested branches.
- Avoid magic numbers and magic strings. Use named constants, enums, macros, Kconfig options, or shared config keys.
- Prefer explicit ownership and explicit data flow over hidden global state.
- Keep public headers small and avoid exposing private implementation details.
- Avoid circular dependencies between components and modules.
- Check return values, handle allocation failures, and clean up partially initialized resources.
- Protect shared mutable state with documented ownership or synchronization.

## Code Style

- Implement the module in ESP-IDF using C-style object-oriented design, not C++.
- Represent each module as an object with an opaque handle: typedef struct xxx_t *xxx_handle_t.
- The header should expose only the handle, config, events, callbacks, and public APIs.
- Define struct xxx_t only in the .c file to store object state and resources.
- Use ESP-IDF-style APIs: xxx_create/delete/start/stop/read/write/set/get.
- Use xxx_handle_t handle as the first parameter of object methods.
- Prefer esp_err_t as the return type for public APIs.
- Use const xxx_config_t *config as create input and xxx_handle_t *ret_handle as output.
- Resources must be allocated in create and fully released in delete.
- Internal resources may include memory, GPIO, I2C, SPI, timers, tasks, queues, and mutexes.
- Protect shared state with mutexes or semaphores when accessed by multiple tasks.
- Register callbacks with xxx_register_cb(), using handle, event, and user_ctx.
- For polymorphism, use an xxx_ops_t function pointer table and put base struct as the first member.

## Memory Allocation and Release

- All runtime states must belong to a certain object instance.
- Avoid creating local variables larger than 128 bytes on task stacks; 
- Pre-allocated buffers, memory pools or ring buffers should be used in high-frequency scenarios.

## Testing

- Firmware changes should at minimum run `idf.py build` for the affected board configuration after exporting ESP-IDF and generating board manager config.
- Component test apps live under `components/claw_modules/*/test_apps/`.
- Lua module tests live beside modules under `components/lua_modules/<module>/test/` with descriptive names such as `json_roundtrip.lua`.
- Embedded frontend changes should run `cd application/edge_agent/components/http_server/frontend_source && pnpm build` and `pnpm typecheck`.

## Common File Locations

- App entry point: `application/edge_agent/main/main.c`
- Capability registration: `components/common/app_claw/app_capabilities.c`
- Lua module registration: `components/common/app_claw/app_lua_modules.c`
- App config schema/storage: `application/edge_agent/components/app_config/`
- Board definitions: `application/edge_agent/boards/`
- Session manager cap: `components/claw_capabilities/cap_session_mgr/src/cap_session_mgr.c`
- Event router (incl. local `/session`): `components/claw_modules/claw_event_router/src/claw_event_router.c`
- Wi-Fi / SoftAP NAPT: `components/common/wifi_manager/wifi_manager.c`
- High-level socket Lua: `components/lua_modules/lua_module_socket/`
- WebSocket client Lua: `components/lua_modules/lua_module_websocket/`

## AGENTS.md Best-Practice Notes

Use this file as a compact router, not an encyclopedia.

- Keep instructions specific to this repository and this documentation workflow.
- Prefer exact file paths and commands over broad principles.
- Point agents to the right source files instead of duplicating long architecture explanations here.
- Document boundaries and exceptions explicitly, especially when "do not create a page by default" is the expected behavior.
- Update this guide when the docs workflow changes; stale agent docs are worse than missing prose.
