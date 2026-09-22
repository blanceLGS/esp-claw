-- voice_keepalive.lua
-- Phase-1 resident/restart + Phase-2 product switches:
--   ensure voice wake job "voice_wake" is running when enabled.
--   When disabled (DATA voice_enable / NVS voice_enable) stop a live job.
--   Optional DATA voice_wake.cmd: restart | stop | start
--   Optional DATA voice_tts_volume: passed into wake_listen tts_volume
--
-- Disable: pause scheduler id voice_keepalive and disable router rules
-- voice_service_startup / voice_keepalive_check; or write voice_enable=0.

local capability = require("capability")
local json = require("json")
local storage = require("storage")
local system = require("system")

local a = type(args) == "table" and args or {}

local JOB_NAME = "voice_wake"
local SERVICE_PATH = "/system/skills/wake_listen/scripts/wake_listen.lua"
local STATE_PATH = "/ramfs/voice_wake.keepalive"
local MIN_RESTART_GAP_MS = 15000

local function log(fmt, ...)
    print(string.format("[voice_keepalive] " .. fmt, ...))
end

local function parse_json(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, obj = pcall(json.decode, s)
    if ok and type(obj) == "table" then return obj end
    return nil
end

local function data_file(name)
    local ok, root = pcall(storage.get_root_dir)
    if ok and type(root) == "string" and root ~= "" then
        local jok, path = pcall(storage.join_path, root, name)
        if jok and type(path) == "string" and path ~= "" then
            return path
        end
        if root:sub(-1) == "/" then
            return root .. name
        end
        return root .. "/" .. name
    end
    return "/fatfs/" .. name
end

local function read_data_text(name)
    local ok, raw = pcall(storage.read_file, data_file(name))
    if not ok or type(raw) ~= "string" then
        return nil
    end
    return raw:match("^%s*(.-)%s*$") or ""
end

local function read_last_start_ms()
    local ok, raw = pcall(storage.read_file, STATE_PATH)
    if not ok or type(raw) ~= "string" or raw == "" then return 0 end
    return tonumber(raw) or 0
end

local function write_last_start_ms(ms)
    pcall(storage.write_file, STATE_PATH, tostring(ms))
end

local function job_is_alive(obj, raw)
    -- lua_get_async_job is line text, not JSON:
    --   job_id=...\nname=voice_wake\nstatus=running\n...
    -- "not found" / empty / unknown → NOT alive (must start on boot).
    if type(raw) == "string" then
        if raw:find("status=running", 1, true) or raw:find("status=queued", 1, true) then
            local id = raw:match("job_id=([^\r\n]+)") or JOB_NAME
            return true, raw:match("status=([^\r\n]+)") or "running", id
        end
        if raw:find("not found", 1, true)
            or raw:find("status=failed", 1, true)
            or raw:find("status=timeout", 1, true)
            or raw:find("status=stopped", 1, true)
            or raw:find("status=done", 1, true) then
            return false, raw:match("status=([^\r\n]+)") or "not_found", ""
        end
        if raw:find("job_id=", 1, true) then
            return false, raw:match("status=([^\r\n]+)") or "no-running-status", ""
        end
        return false, "empty-or-unknown", ""
    end
    if type(obj) == "table" then
        local job = obj.job
        if type(job) ~= "table" then job = obj end
        local status = tostring(job.status or obj.status or ""):lower()
        if status == "running" or status == "queued" then
            return true, status, job.name or job.job_id or JOB_NAME
        end
        return false, status ~= "" and status or "json-no-running", job.name or job.job_id or ""
    end
    return false, "no-output", ""
end

local function voice_disabled_by_config()
    -- DATA file first (web/serial product switch), then NVS voice_config.
    local raw_en = read_data_text("voice_enable")
    if type(raw_en) == "string" then
        local s = raw_en:lower()
        if s == "0" or s == "false" or s == "off" or s == "no" then
            return true, "file"
        end
    end
    local ok_cfg, cfg_out = capability.call("voice_config_get", {}, { source_cap = "voice_keepalive" })
    if ok_cfg and type(cfg_out) == "string" then
        local cfg = parse_json(cfg_out)
        if type(cfg) == "table" then
            local en = cfg.voice_enable
            if en == false or en == "false" or en == "0" or en == 0 then
                return true, "nvs"
            end
        end
    end
    return false, nil
end

local function stop_voice_job(reason)
    log("stop job name=%s reason=%s", JOB_NAME, tostring(reason))
    local ok, out = capability.call("lua_stop_async_job", {
        name = JOB_NAME,
        wait_ms = 2000,
    }, { source_cap = "voice_keepalive" })
    log("stop result ok=%s out=%s", tostring(ok), tostring(out):sub(1, 160))
end

local function start_voice_job(extra)
    local now = system.millis()
    local last = read_last_start_ms()
    if last > 0 and (now - last) < MIN_RESTART_GAP_MS then
        log("debounce: last start %dms ago, skip", now - last)
        return
    end

    local start_args = {
        service = true,
        max_iterations = 0,
        vad_wait_ms = 0,
        wake_only = false,
        exit_on_wake = false,
        use_local_vad = true,
        followup_ms = 20000,
        vad_threshold = 1200,
        local_hold_ms = 200,
        iat_min_peak = 2500,
        wake_ack = true,
        empty_retry = true,
        wake_record_ms = 4500,
        cmd_record_ms = 7000,
        loose_command = true,
    }
    local vol = tonumber(read_data_text("voice_tts_volume") or "")
    if vol then
        if vol < 0 then vol = 0 end
        if vol > 100 then vol = 100 end
        start_args.tts_volume = vol
        log("DATA tts_volume=%d", vol)
    end
    for _, k in ipairs({
        "wake_only", "exit_on_wake", "use_local_vad",
        "followup_ms", "vad_threshold", "wake_record_ms", "cmd_record_ms",
        "volume", "tts_volume",
    }) do
        if a[k] ~= nil then start_args[k] = a[k] end
    end
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            start_args[k] = v
        end
    end

    log("starting %s service async timeout_ms=0 name=%s", SERVICE_PATH, JOB_NAME)
    local ok_s, sout = capability.call("lua_run_script_async", {
        path = SERVICE_PATH,
        args = start_args,
        timeout_ms = 0,
        log_bytes = 8192,
        name = JOB_NAME,
        exclusive = "voice",
        replace = false,
    }, { source_cap = "voice_keepalive" })
    if not ok_s then
        log("start failed: %s", tostring(sout))
        return
    end
    write_last_start_ms(system.millis())
    log("started: %s", tostring(sout):sub(1, 200))
end

local function consume_cmd()
    local raw = read_data_text("voice_wake.cmd")
    if not raw or raw == "" then
        return nil
    end
    pcall(storage.remove, data_file("voice_wake.cmd"))
    local cmd = raw:lower()
    if cmd == "restart" or cmd == "reload" then
        return "restart"
    end
    if cmd == "stop" then
        return "stop"
    end
    if cmd == "start" then
        return "start"
    end
    log("unknown voice_wake.cmd=%s", raw)
    return nil
end

local function run()
    local reason = a.reason or "keepalive"
    log("check reason=%s name=%s", reason, JOB_NAME)

    local disabled, why = voice_disabled_by_config()
    local ok_j, jout = capability.call("lua_get_async_job", { name = JOB_NAME }, { source_cap = "voice_keepalive" })
    local obj = ok_j and parse_json(jout) or nil
    local alive, status, id = job_is_alive(obj, ok_j and jout or nil)

    local cmd = consume_cmd()
    if cmd == "stop" then
        if alive then
            stop_voice_job("cmd=stop")
        else
            log("cmd=stop but job not alive status=%s", tostring(status))
        end
        return
    end
    if cmd == "restart" then
        log("cmd=restart (force bounce)")
        if alive then
            stop_voice_job("cmd=restart")
            alive = false
            -- allow immediate start after explicit restart
            write_last_start_ms(0)
        end
    end

    if disabled then
        if alive then
            log("voice_enable=false (%s), stopping live job", tostring(why))
            stop_voice_job("disabled:" .. tostring(why))
        else
            log("voice_enable=false (%s), not starting", tostring(why))
        end
        return
    end

    if alive and cmd ~= "restart" and cmd ~= "start" then
        log("already alive status=%s id=%s", tostring(status), tostring(id))
        return
    end

    if cmd == "start" then
        write_last_start_ms(0)
    end
    log("job not alive status=%s raw=%s", tostring(status), tostring(jout):sub(1, 200))
    start_voice_job()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    local msg = tostring(err or "unknown")
    print("[voice_keepalive] ERR: " .. (msg:match("([^\n]+)") or msg))
    error(msg)
end
