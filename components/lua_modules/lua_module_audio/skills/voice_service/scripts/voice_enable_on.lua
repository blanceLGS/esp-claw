# enable voice via serial one-shot lua
# writes /fatfs/voice_enable=1 then runs keepalive
local storage = require("storage")
local function data_file(name)
    local ok, root = pcall(storage.get_root_dir)
    if ok and type(root) == "string" and root ~= "" then
        local jok, path = pcall(storage.join_path, root, name)
        if jok and type(path) == "string" and path ~= "" then
            return path
        end
        return root .. "/" .. name
    end
    return "/fatfs/" .. name
end
local p = data_file("voice_enable")
storage.write_file(p, "1")
print("[voice_enable_on] wrote " .. p .. " = 1")
local saved = _G.args
_G.args = { reason = "manual_enable" }
dofile("/system/skills/voice_service/scripts/voice_keepalive.lua")
_G.args = saved
