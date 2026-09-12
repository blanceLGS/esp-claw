# Lua Socket

High-level TCP/UDP socket module for Lua scripts (luasocket-style subset on ESP-IDF / lwIP).

## How to call

```lua
local socket = require("socket")
```

## TCP

```lua
local client = socket.tcp()
client:settimeout(5)                 -- seconds; nil = blocking
local ok, err = client:connect("1.2.3.4", 80)
if not ok then error(err) end

local n, err = client:send("ping")
local data, err, partial = client:receive(16)   -- or "*l" / "*a"
client:close()
```

| Method | Returns | Notes |
|---|---|---|
| `socket.tcp()` | userdata | Create TCP client object |
| `client:settimeout(sec)` | - | Seconds (float); `nil` = block forever |
| `client:connect(host, port)` | `true` or `nil, err` | DNS or IPv4 literal |
| `client:send(data)` | `n` or `n, "timeout"` | Sends until done or error |
| `client:receive(pattern)` | `data` or `nil, err` | `"*l"`, `"*a"`, or byte count |
| `client:getsockname()` | `ip, port` | Local address |
| `client:getpeername()` | `ip, port` | Remote address |
| `client:shutdown(how)` | - | `"both"` / `"receive"` / `"send"` |
| `client:close()` | - | Idempotent; also runs on GC |

## UDP

```lua
local udp = socket.udp()
udp:settimeout(2)
udp:setpeername("1.2.3.4", 1234)
udp:send("hello")
local data = udp:receive(64)
udp:close()
```

| Method | Returns | Notes |
|---|---|---|
| `socket.udp()` | userdata | Create UDP object |
| `udp:setsockname(host, port)` | `true` or `nil, err` | Bind; `host="*"` = any |
| `udp:setpeername(host, port)` | `true` or `nil, err` | Connect peer (DNS ok) |
| `udp:send(data)` | `n` or `nil, err` | Requires peer or sendto path |
| `udp:receive([max])` | `data` or `nil, err` | Default max 2048 |
| `udp:settimeout(sec)` | - | Seconds |
| `udp:close()` | - | Idempotent |

## Helpers

```lua
local ip = socket.dns.toip("example.com")
local now = socket.gettime()          -- seconds since epoch (float)
local r, s, err = socket.select({client}, nil, 1.0)
```

## Limits and cleanup

- IPv4 only.
- `receive("*a")` is capped at 64 KiB per call; loop for larger payloads.
- Always `close()` sockets when done. GC closes leftovers, but explicit close frees fds sooner.
- Block until `cap_lua` stop is not special-cased here; use short timeouts in long scripts.

## Example (TCP echo probe)

```lua
local socket = require("socket")
local c = socket.tcp()
c:settimeout(3)
assert(c:connect("192.168.1.1", 80))
print(c:send("GET / HTTP/1.0\r\n\r\n"))
print(c:receive("*a"))
c:close()
```
