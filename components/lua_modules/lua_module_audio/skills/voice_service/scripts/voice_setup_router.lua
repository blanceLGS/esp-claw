-- voice_setup_router.lua
-- Merge Phase-1 voice keepalive rules into DATA router_rules.json.

local storage = require("storage")
local json = require("json")

local PATH = "/fatfs/router_rules/router_rules.json"

local function log(fmt, ...)
    print(string.format("[voice_setup_router] " .. fmt, ...))
end

local NEW_RULES = {
    {
        id = "voice_service_startup",
        description = "Phase-1: start resident voice wake service after boot via keepalive.",
        enabled = true,
        consume_on_match = false,
        fail_open = true,
        ack = "voice keepalive boot check queued",
        match = {
            source_cap = "app_claw",
            event_type = "startup",
            event_key = "boot_completed",
            content_type = "trigger",
        },
        actions = {
            {
                type = "run_script",
                fail_open = true,
                input = {
                    async = true,
                    path = "/system/skills/voice_service/scripts/voice_keepalive.lua",
                    timeout_ms = 30000,
                    args = { reason = "boot" },
                },
            },
        },
    },
    {
        id = "voice_keepalive_check",
        description = "Phase-1: scheduler tick ensures voice_wake async job is running.",
        enabled = true,
        consume_on_match = false,
        fail_open = true,
        ack = "voice keepalive tick handled",
        match = {
            event_type = "schedule",
            event_key = "voice_keepalive",
        },
        actions = {
            {
                type = "run_script",
                fail_open = true,
                input = {
                    async = true,
                    path = "/system/skills/voice_service/scripts/voice_keepalive.lua",
                    timeout_ms = 20000,
                    args = { reason = "scheduler" },
                },
            },
        },
    },
}

local function run()
    local rules = {}
    local ok_r, raw = pcall(storage.read_file, PATH)
    if ok_r and type(raw) == "string" and raw ~= "" then
        local dok, arr = pcall(json.decode, raw)
        if dok and type(arr) == "table" then
            rules = arr
        else
            error("parse router_rules.json failed")
        end
    else
        log("no router_rules.json, creating")
    end

    for _, new in ipairs(NEW_RULES) do
        local found = false
        for i = 1, #rules do
            if type(rules[i]) == "table" and rules[i].id == new.id then
                rules[i] = new
                found = true
                log("updated rule %s", new.id)
                break
            end
        end
        if not found then
            rules[#rules + 1] = new
            log("added rule %s", new.id)
        end
    end

    local encoded = json.encode(rules)
    if not encoded or encoded == "" then
        error("json.encode router rules failed")
    end
    pcall(storage.mkdir, "/fatfs/router_rules")
    local ok_w, werr = pcall(storage.write_file, PATH, encoded)
    if not ok_w then
        error("write router_rules.json failed: " .. tostring(werr))
    end
    log("wrote %s (%d rules)", PATH, #rules)
    log("router reload: restart device or use existing router reload CLI if available")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    print("[voice_setup_router] ERR: " .. tostring(err))
    error(err)
end
