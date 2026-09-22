-- TCP client smoke test against a local HTTP endpoint.
-- Adjust host/port before running on device.

local socket = require("socket")

local host = "192.168.1.1"
local port = 80

local client = socket.tcp()
client:settimeout(5)

local ok, err = client:connect(host, port)
if not ok then
    print("connect failed:", err)
    return
end

local sent, serr = client:send("GET / HTTP/1.0\r\nHost: " .. host .. "\r\n\r\n")
print("sent", sent, serr)

local data, rerr = client:receive("*a")
print("recv", data and #data or 0, rerr)
if data then
    print(data:sub(1, 200))
end

client:close()
print("done")
