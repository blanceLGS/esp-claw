-- E' speak reply: take existing reply_text -> sentence trim -> SiliconFlow TTS -> play.
-- Does NOT call agent_ask (avoids root-agent re-entrancy deadlock).
-- Stream mode: background POST (stream:true + save_direct) then play once enough bytes.

local audio = require("audio")
local board_manager = require("board_manager")
local capability = require("capability")
local delay = require("delay")
local json = require("json")
local storage = require("storage")
local system = require("system")
local thread = require("thread")

local a = type(args) == "table" and args or {}

local DEFAULT_BASE = "https://api.siliconflow.cn/v1"
local DEFAULT_MODEL = "FunAudioLLM/CosyVoice2-0.5B"
local DEFAULT_VOICE = "FunAudioLLM/CosyVoice2-0.5B:alex"
local DEFAULT_VOLUME = 80
local DEFAULT_TTS_TIMEOUT_MS = 30000
local DEFAULT_MAX_SENTENCES = 6
local DEFAULT_MAX_CHARS = 400
local DEFAULT_MIN_PLAY_BYTES = 49152
local STREAM_SETTLE_MS = 120
local WORKER_PATH = "/system/skills/agent_then_tts/scripts/tts_http_worker.lua"
local STREAM_PATH = "/ramfs/tts_live.mp3"

local function string_arg(key, default)
    local v = a[key]
    if type(v) == "string" and v ~= "" then
        return v
    end
    return default
end

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

local function bool_arg(key, default)
    local v = a[key]
    if v == nil then
        return default
    end
    if type(v) == "boolean" then
        return v
    end
    if v == "true" or v == true or v == 1 or v == "1" then
        return true
    end
    if v == "false" or v == false or v == 0 or v == "0" then
        return false
    end
    return default
end

local function trim_slash(s)
    return (s:gsub("/+$", ""))
end

local function split_sentences(s)
    local out = {}
    local buf = ""
    for i = 1, #s do
        local ch = s:sub(i, i)
        buf = buf .. ch
        if ch == "。" or ch == "！" or ch == "？" or ch == "；" or ch == "…" or ch == "." or ch == "!" or ch == "?" or ch == ";" then
            local trimmed = buf:gsub("%s+$", "")
            if trimmed ~= "" then
                out[#out + 1] = trimmed
            end
            buf = ""
        end
    end
    local rest = buf:gsub("^%s+", ""):gsub("%s+$", "")
    if rest ~= "" then
        out[#out + 1] = rest
    end
    return out
end

local function tts_excerpt(text, max_sentences, max_chars)
    local parts = split_sentences(text or "")
    local picked = {}
    local len = 0
    for i = 1, math.min(max_sentences, #parts) do
        local piece = parts[i]
        if len + #piece > max_chars then
            break
        end
        picked[#picked + 1] = piece
        len = len + #piece
    end
    if #picked == 0 then
        return (text or ""):sub(1, max_chars)
    end
    return table.concat(picked, "")
end

local function load_voice_config()
    local ok, out, err = capability.call("voice_config_get", {}, {
        source_cap = "agent_then_tts",
    })
    if not ok or type(out) ~= "string" or out == "" then
        print(string.format("[agent_then_tts] voice_config_get failed: %s", tostring(err or out)))
        return {}
    end
    local decoded_ok, cfg = pcall(json.decode, out)
    if not decoded_ok or type(cfg) ~= "table" then
        print("[agent_then_tts] voice_config_get: bad JSON")
        return {}
    end
    return cfg
end

local function nonempty(s)
    if type(s) == "string" and s ~= "" then
        return s
    end
    return nil
end

local function open_player(volume)
    local codec, rate, channels, bits = board_manager.get_audio_codec_output_params("audio_dac")
    if not codec then
        error("get_audio_codec_output_params(audio_dac) failed: " .. tostring(rate))
    end
    local output = assert(audio.new_output({ codec, rate, channels, bits, volume = volume }))
    local player = assert(audio.player({ output = output }))
    return player, output
end

local function play_path(player, path)
    print(string.format("[agent_then_tts] play %s", path))
    player:play(path, { wait = true })
end

local function file_size(path)
    local st = storage.stat(path)
    return (st and st.size) or 0
end

-- Extract path[from_byte:] into a new MP3, aligned to the next frame sync.
local function write_remainder(src_path, from_byte, dst_path)
    local raw = storage.read_file(src_path)
    if type(raw) ~= "string" or from_byte >= #raw then
        return nil
    end
    local i = from_byte + 1
    if from_byte > 0 then
        -- Skip partial frame: next 0xFF Ex/Fx sync (MPEG audio).
        while i < #raw - 1 do
            local b = raw:byte(i)
            local b2 = raw:byte(i + 1)
            if b == 0xFF and b2 and (b2 >= 0xE0) then
                break
            end
            i = i + 1
        end
        if i >= #raw - 1 then
            return nil
        end
    end
    local chunk = raw:sub(i)
    if #chunk < 4 then
        return nil
    end
    pcall(storage.remove, dst_path)
    local ok = pcall(storage.write_file, dst_path, chunk)
    if not ok then
        return nil
    end
    return dst_path, #chunk
end

local function parse_job_id(raw)
    if type(raw) ~= "string" then
        return nil
    end
    -- thread.start: "Started Lua job <id> (name=...)"
    -- thread.get:   "job_id=<id>\nstatus=..."
    -- Never capture trailing prose after the id.
    local id = raw:match("job_id=([%w%-_]+)")
    if id then
        return id
    end
    return raw:match("Started Lua job ([%w%-_]+)")
end

local function job_finished(job_id)
    if not job_id or job_id == "" then
        return false
    end
    local ok, out = thread.get(job_id)
    if ok and type(out) == "string" then
        return out:find("status=done", 1, true) or out:find("status=failed", 1, true)
            or out:find("status=timeout", 1, true) or out:find("status=stopped", 1, true)
    end
    return false
end

-- Ready only when min_play bytes exist, or the download job has finished.
-- A paused HTTP body must NOT look "ready" — player sees only what is on disk
-- at open time (partial MP3 = truncated/empty speech).
local function wait_stream_ready(path, min_bytes, deadline_ms, job_id)
    while true do
        local size = file_size(path)
        if size >= min_bytes then
            return size
        end
        if job_finished(job_id) and size > 0 then
            return size
        end
        if system.millis() >= deadline_ms then
            if size > 0 then
                return size
            end
            error(string.format("stream timeout: only %d bytes (need %d)", size, min_bytes))
        end
        delay.delay_ms(30)
    end
end

-- Brief settle so the MP3 decoder does not start on a torn frame.
local function settle_stream(path, settle_ms)
    local last = file_size(path)
    local deadline = system.millis() + settle_ms
    while system.millis() < deadline do
        delay.delay_ms(30)
        local now = file_size(path)
        if now == last then
            return now
        end
        last = now
    end
    return last
end

local function wait_download_job(job_id, extra_ms)
    if not job_id or job_id == "" then
        return
    end
    local deadline = system.millis() + extra_ms
    while system.millis() < deadline do
        local ok, out = thread.get(job_id)
        if ok and type(out) == "string" then
            if out:find("status=done", 1, true) or out:find("status=failed", 1, true)
                    or out:find("status=timeout", 1, true) or out:find("status=stopped", 1, true) then
                print(string.format("[agent_then_tts] download job: %s", out:gsub("\n", " | ")))
                return
            end
        end
        delay.delay_ms(50)
    end
    print("[agent_then_tts] download job wait expired")
end

local function run_stream(cfg, spoken, url, volume, tts_timeout, min_play)
    local body = json.encode({
        model = string_arg("tts_model", nonempty(cfg.tts_model) or DEFAULT_MODEL),
        input = spoken,
        voice = string_arg("tts_voice", nonempty(cfg.tts_voice) or DEFAULT_VOICE),
        response_format = "mp3",
        stream = true,
    })
    local api_key = string_arg("tts_api_key", nonempty(cfg.tts_api_key))
    local out_path = STREAM_PATH
    pcall(storage.remove, out_path)

    local t0 = system.millis()
    local started, start_out = thread.start(WORKER_PATH, {
        url = url,
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        body = body,
        save_path = out_path,
        timeout_ms = tts_timeout,
        max_file_bytes = 1024 * 1024,
    }, {
        name = "tts_http",
        timeout_ms = tts_timeout + 5000,
    })
    if not started then
        error(string.format("failed to start tts download: %s", tostring(start_out)))
    end
    -- thread.start returns full status text (job_id=...\nname=...\nstatus=...).
    local job_id = parse_job_id(start_out) or "tts_http"
    print(string.format("[agent_then_tts] tts job_id=%s", tostring(job_id)))

    local ready_size = wait_stream_ready(out_path, min_play, t0 + tts_timeout, job_id)
    local ttfb = system.millis() - t0
    print(string.format("[agent_then_tts] stream ready bytes=%d ttfb_to_play_ms=%d",
                        ready_size, ttfb))

    -- 边下边播: play what is on disk; when the file EOF hits while HTTP is
    -- still writing, extract the new tail (frame-aligned) and continue.
    local player, output = open_player(volume)
    local consumed = 0
    local seg_path = "/ramfs/tts_seg.mp3"
    local pok, perr = xpcall(function()
        while true do
            local size = file_size(out_path)
            if size > consumed then
                local play_file = out_path
                local play_from = consumed
                if consumed > 0 then
                    local seg, seg_len = write_remainder(out_path, consumed, seg_path)
                    if seg then
                        play_file = seg
                        play_from = consumed + (size - consumed) - seg_len
                        -- consumed advances by bytes we are about to play
                        consumed = size
                    else
                        consumed = size
                        play_file = nil
                    end
                else
                    consumed = size
                end
                if play_file then
                    print(string.format("[agent_then_tts] play %s (from~%d size=%d)",
                                        play_file, play_from, file_size(play_file)))
                    play_path(player, play_file)
                end
            end
            if job_finished(job_id) then
                local final_size = file_size(out_path)
                if final_size <= consumed then
                    break
                end
                -- Tail still on disk: loop once more to play remainder.
            end
            if system.millis() >= t0 + tts_timeout then
                print("[agent_then_tts] stream play deadline")
                break
            end
            if file_size(out_path) <= consumed then
                if job_finished(job_id) then
                    break
                end
                delay.delay_ms(40)
            end
        end
    end, debug.traceback)
    pcall(storage.remove, seg_path)
    -- Let I2S TX drain before tearing down the shared full-duplex port.
    delay.delay_ms(200)
    pcall(function() player:close() end)
    pcall(function() output:close() end)
    delay.delay_ms(150)
    if not pok then
        pcall(thread.stop, job_id, 1000)
        pcall(storage.remove, out_path)
        error(perr)
    end
    wait_download_job(job_id, 3000)
    delay.delay_ms(80)
    pcall(storage.remove, out_path)
    print("[agent_then_tts] cleaned " .. out_path)
end

local function run_full_download(cfg, spoken, url, volume, tts_timeout)
    local root = storage.get_root_dir()
    local voice_dir = storage.join_path(root, "voice")
    local out_path = storage.join_path(voice_dir, "tts.mp3")
    storage.mkdir(voice_dir)

    local api_key = string_arg("tts_api_key", nonempty(cfg.tts_api_key))
    local model = string_arg("tts_model", nonempty(cfg.tts_model) or DEFAULT_MODEL)
    local voice = string_arg("tts_voice", nonempty(cfg.tts_voice) or DEFAULT_VOICE)

    local ok, out, err = capability.call("http_request", {
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        body = json.encode({
            model = model,
            input = spoken,
            voice = voice,
            response_format = "mp3",
            stream = true,
        }),
        timeout_ms = tts_timeout,
        save_path = out_path,
        max_file_bytes = 512 * 1024,
    }, {
        source_cap = "agent_then_tts",
    })
    if not ok then
        error(string.format("TTS HTTP failed: %s", tostring(err or out)))
    end

    local player, output = open_player(volume)
    local pok, perr = xpcall(function()
        play_path(player, out_path)
    end, debug.traceback)
    delay.delay_ms(200)
    pcall(function() player:close() end)
    pcall(function() output:close() end)
    delay.delay_ms(150)
    if not pok then
        error(perr)
    end
    pcall(storage.remove, out_path)
    print("[agent_then_tts] cleaned " .. out_path)
end

local function run()
    local reply = string_arg("reply_text", string_arg("text", nil))
    local status = string_arg("status", nil)
    if status and status ~= "" and status ~= "ok" then
        print(string.format("[agent_then_tts] skip non-ok status=%s", status))
        return
    end
    if not reply then
        error("reply_text is required: pass the agent reply to speak (do not call agent_ask from this skill)")
    end

    local cfg = load_voice_config()
    local api_key = string_arg("tts_api_key", nonempty(cfg.tts_api_key))
    local base = string_arg("tts_base_url", nonempty(cfg.tts_base_url) or DEFAULT_BASE)
    local volume = int_arg("tts_volume", tonumber(cfg.tts_volume) or DEFAULT_VOLUME, 0, 100)
    local tts_timeout = int_arg("tts_http_timeout_ms", DEFAULT_TTS_TIMEOUT_MS, 1000, 120000)
    local max_sentences = int_arg("tts_max_sentences", DEFAULT_MAX_SENTENCES, 1, 10)
    local max_chars = int_arg("tts_max_chars", DEFAULT_MAX_CHARS, 20, 500)
    local stream = bool_arg("tts_stream", true)
    local min_play = int_arg("tts_min_play_bytes", 0, 4096, 256 * 1024)
    if min_play == 0 then
        -- First-byte gate only; continuation covers the rest (真正边下边播).
        local spoken_len = #tts_excerpt(reply, max_sentences, max_chars)
        if spoken_len <= 20 then
            min_play = 8192
        elseif spoken_len <= 60 then
            min_play = 12288
        else
            min_play = 16384
        end
        if min_play > DEFAULT_MIN_PLAY_BYTES then
            min_play = DEFAULT_MIN_PLAY_BYTES
        end
    end
    print(string.format("[agent_then_tts] mode=%s min_play=%d", stream and "stream" or "full", min_play))

    if not api_key then
        error("tts_api_key missing: set it in LLM page Voice/ASR, or pass tts_api_key")
    end

    local spoken = tts_excerpt(reply, max_sentences, max_chars)
    if spoken == "" then
        error("reply_text is empty after trim")
    end
    print(string.format("[agent_then_tts] reply_len=%d spoken_len=%d stream=%s",
                        #reply, #spoken, tostring(stream)))
    print("[agent_then_tts] SPOKEN: " .. spoken)

    local url = trim_slash(base) .. "/audio/speech"
    if stream then
        run_stream(cfg, spoken, url, volume, tts_timeout, min_play)
    else
        run_full_download(cfg, spoken, url, volume, tts_timeout)
    end
    print("[agent_then_tts] done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    error(err)
end
