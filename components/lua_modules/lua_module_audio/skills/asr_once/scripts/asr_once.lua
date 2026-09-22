-- A'+B': stream mic -> iFlytek IAT (no intermediate file).

local a = type(args) == "table" and args or {}

local IAT_DIR = "/system/skills/asr_iat/scripts"

local function run()
    _G.args = {
        stream = true,
        duration_ms = a.duration_ms or 6000,
        volume = a.volume,
        asr_app_id = a.asr_app_id,
        asr_api_key = a.asr_api_key,
        asr_api_secret = a.asr_api_secret,
        asr_endpoint = a.asr_endpoint,
        timeout_ms = a.timeout_ms,
    }
    dofile(IAT_DIR .. "/asr_iat_file.lua")
    print("[asr_once] done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    local msg = tostring(err or "unknown")
    local first = msg:match("([^\n]+)") or msg
    print("[asr_once] ERR: " .. first)
    error(first)
end
