-- Manual voice turn: ASR -> agent_ask -> TTS play. No wake.
-- Must not be invoked from inside the root agent tool callback (agent_ask re-entrancy).

local capability = require("capability")
local json = require("json")

local a = type(args) == "table" and args or {}

local IAT_DIR = "/system/skills/asr_iat/scripts"
local TTS_DIR = "/system/skills/agent_then_tts/scripts"

local function int_arg(key, default, lo, hi)
    local n = tonumber(a[key])
    if not n then
        return default
    end
    n = math.floor(n)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

local function run()
    _G.asr_final_text = nil
    _G.args = {
        stream = true,
        duration_ms = int_arg("duration_ms", 6000, 500, 55000),
        volume = int_arg("volume", 100, 0, 100),
        timeout_ms = int_arg("timeout_ms", 60000, 1000, 120000),
    }
    dofile(IAT_DIR .. "/asr_iat_file.lua")
    local heard = _G.asr_final_text
    if type(heard) ~= "string" or heard == "" then
        error("ASR empty; speak after SPEAK_NOW")
    end
    print("[voice_turn] HEARD: " .. heard)

    local agent_timeout = int_arg("agent_timeout_ms", 90000, 5000, 180000)
    -- Prefer spoken Chinese so TTS does not read an English agent reply.
    local prompt = "请用简短的中文口语回答（一两句即可），不要输出英文或Markdown。用户说：" .. heard
    print("[voice_turn] agent_ask ...")
    local ok, reply, err = capability.call("agent_ask", {
        text = prompt,
        timeout_ms = agent_timeout,
    }, { source_cap = "voice_turn" })
    if not ok then
        error("agent_ask failed: " .. tostring(err or reply))
    end
    if type(reply) ~= "string" or reply == "" then
        error("agent_ask returned empty reply")
    end
    if reply:sub(1, 1) == '"' then
        local dok, decoded = pcall(json.decode, reply)
        if dok and type(decoded) == "string" then
            reply = decoded
        end
    end
    print("[voice_turn] REPLY: " .. reply)

    _G.args = {
        reply_text = reply,
        tts_volume = a.tts_volume,
    }
    dofile(TTS_DIR .. "/agent_then_tts.lua")
    print("[voice_turn] done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    local msg = tostring(err or "unknown")
    local first = msg:match("([^\n]+)") or msg
    print("[voice_turn] ERR: " .. first)
    error(first)
end
