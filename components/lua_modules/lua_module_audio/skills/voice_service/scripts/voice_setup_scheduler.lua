-- voice_setup_scheduler.lua
-- Merge voice_keepalive interval into DATA scheduler definitions and reload.
-- Avoids serial CLI JSON-quoting issues.

local storage = require("storage")
local capability = require("capability")
local json = require("json")

local PATH = "/fatfs/scheduler/schedules.json"

local function log(fmt, ...)
    print(string.format("[voice_setup_scheduler] " .. fmt, ...))
end

local function run()
    local entry = {
        id = "voice_keepalive",
        enabled = true,
        kind = "interval",
        interval_ms = 60000,
        event_type = "schedule",
        event_key = "voice_keepalive",
        source_channel = "time",
        content_type = "trigger",
        session_policy = "trigger",
        text = "voice_keepalive",
        payload_json = "{\"message\":\"ensure voice_wake resident job\",\"kind\":\"voice_keepalive\"}",
        max_runs = 0,
    }

    local list = {}
    local ok_r, raw = pcall(storage.read_file, PATH)
    if ok_r and type(raw) == "string" and raw ~= "" then
        local dok, arr = pcall(json.decode, raw)
        if dok and type(arr) == "table" then
            list = arr
        else
            log("WARN schedules.json parse failed, rewriting")
        end
    else
        log("no schedules.json yet, creating")
    end

    local found = false
    for i = 1, #list do
        if type(list[i]) == "table" and list[i].id == "voice_keepalive" then
            list[i] = entry
            found = true
            break
        end
    end
    if not found then
        list[#list + 1] = entry
    end

    local encoded = json.encode(list)
    if not encoded or encoded == "" then
        error("json.encode schedules failed")
    end
    pcall(storage.mkdir, "/fatfs/scheduler")
    local ok_w, werr = pcall(storage.write_file, PATH, encoded)
    if not ok_w then
        error("write schedules.json failed: " .. tostring(werr))
    end
    log("wrote %s (%d entries)", PATH, #list)

    -- Reload scheduler runtime from disk.
    -- Best-effort: if no Lua binding, device restart also reloads.
    local ok_c, cout = pcall(function()
        return capability.call("scheduler_reload", {}, { source_cap = "voice_setup_scheduler" })
    end)
    if ok_c then
        log("scheduler_reload: %s", tostring(cout))
    else
        log("scheduler_reload cap unavailable (%s); reboot or CLI scheduler --reload", tostring(cout))
    end

    -- Trigger keepalive once.
    dofile("/system/skills/voice_service/scripts/voice_keepalive.lua")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[voice_setup_scheduler] ERR: " .. tostring(err))
    error(err)
end
