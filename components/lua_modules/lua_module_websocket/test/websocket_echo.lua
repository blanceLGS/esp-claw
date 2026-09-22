-- WebSocket client smoke test.
-- Adjust host/port/path before running on device.

local websocket = require("websocket")

local uri = "ws://192.168.1.10:9000/ws"

local ws, err = websocket.connect(uri, { timeout = 5 })
if not ws then
    print("connect failed:", err)
    return
end

print("connected", ws:is_connected())

local n, serr = ws:send("hello from esp-claw")
print("send", n, serr)

local data, op = ws:receive(3)
print("recv", op, data)

ws:close()
print("done")
