-- DNS + UDP send smoke test.

local socket = require("socket")

local host = "192.168.1.1"
local port = 1234

local ip, err = socket.dns.toip(host)
print("resolve", ip, err)

local udp = socket.udp()
udp:settimeout(2)
local ok, perr = udp:setpeername(ip or host, port)
if not ok then
    print("setpeername failed:", perr)
    return
end

local n, serr = udp:send("ping")
print("udp send", n, serr)
udp:close()
print("done")
