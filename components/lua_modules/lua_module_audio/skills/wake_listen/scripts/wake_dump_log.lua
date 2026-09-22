-- wake_dump_log.lua
-- Print the on-device wake_listen log (complete history, not 4KiB CLI tail).

local path = "/ramfs/wake_listen.log"
local fh = io.open(path, "r")
if not fh then
    print("[wake_dump] no log at " .. path)
    return
end
print("[wake_dump] ---- " .. path .. " ----")
local n = 0
while true do
    local line = fh:read("*l")
    if not line then break end
    print(line)
    n = n + 1
end
fh:close()
print("[wake_dump] ---- end lines=" .. n .. " ----")
