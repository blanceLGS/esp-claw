# Lua WebSocket

High-level WebSocket **client** for Lua scripts, backed by `esp_websocket_client`.

## How to call

```lua
local websocket = require("websocket")
```

## Connect

```lua
local ws, err = websocket.connect("ws://192.168.1.10:9000/ws", {
    timeout = 5,  -- seconds (connect + default receive/send)
    -- headers = { Authorization = "Bearer token" },
})
if not ws then error(err) end
```

- URI must be `ws://` or `wss://`. `wss://` uses the ESP certificate bundle.
- `connect` blocks until the handshake completes or `timeout` elapses.

## Methods

| Method | Returns | Notes |
|---|---|---|
| `ws:send(text [, timeout_sec])` | `n` or `nil, err` | Text frame |
| `ws:send_bin(data [, timeout_sec])` | `n` or `nil, err` | Binary frame |
| `ws:receive([timeout_sec])` | `data, opcode` or `nil, err` | opcode: `"text"` / `"binary"` / `"ping"` / `"pong"`; `"closed"` on close |
| `ws:ping([payload])` | `true` or `nil, err` | Application ping |
| `ws:settimeout(sec)` | - | Default receive/send timeout |
| `ws:is_connected()` | boolean | Live connection check |
| `ws:close()` | - | Stop and free; also on GC |

## Receive loop

```lua
ws:settimeout(1)
while ws:is_connected() do
    local data, op = ws:receive(1)
    if data then
        print(op, data)
    elseif op == "closed" then
        break
    end
end
ws:close()
```

Incoming frames are queued (depth 8, each payload ≤ 32 KiB). Oldest frames are dropped if the queue is full.

## Example (echo)

```lua
local websocket = require("websocket")
local ws = assert(websocket.connect("ws://192.168.1.10:9000/ws", { timeout = 5 }))
assert(ws:send("hello"))
local data, op = ws:receive(3)
print(op, data)
ws:close()
```

## Limits and cleanup

- Client only (no built-in server).
- IPv4 network; Wi-Fi must already be up.
- Always `close()` when done. GC will close leftovers.
- Large payloads: max 32 KiB per received frame in this wrapper.
