-- E' tts_only: fixed text -> SiliconFlow TTS -> play MP3.
-- Requires web-configured TTS key (same as LLM page Voice/ASR).

local audio = require("audio")
local board_manager = require("board_manager")
local capability = require("capability")
local json = require("json")
local storage = require("storage")

local a = type(args) == "table" and args or {}

local DEFAULT_TEXT = "你好，我是小依"
local DEFAULT_BASE = "https://api.siliconflow.cn/v1"
local DEFAULT_MODEL = "FunAudioLLM/CosyVoice2-0.5B"
local DEFAULT_VOICE = "FunAudioLLM/CosyVoice2-0.5B:alex"
local DEFAULT_TIMEOUT_MS = 30000
local DEFAULT_VOLUME = 80
local MAX_TEXT_CHARS = 200

local function string_arg(key, default)
    local v = a[key]
    if type(v) == "string" and v ~= "" then
        return v
    end
    return default
end

local function trim_slash(s)
    return (s:gsub("/+$", ""))
end

local function join_url(base, path)
    return trim_slash(base) .. path
end

local function truncate_text(s, max_chars)
    if #s <= max_chars then
        return s
    end
    return s:sub(1, max_chars)
end

-- Read NVS-backed TTS settings from the running app (Web UI Voice/ASR).
local function load_voice_config()
    local ok, out, err = capability.call("voice_config_get", {}, {
        source_cap = "tts_only",
    })
    if not ok or type(out) ~= "string" or out == "" then
        print(string.format("[tts_only] voice_config_get failed: %s", tostring(err or out)))
        return {}
    end
    local decoded_ok, cfg = pcall(json.decode, out)
    if not decoded_ok or type(cfg) ~= "table" then
        print("[tts_only] voice_config_get: bad JSON")
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

local function run()
    local cfg = load_voice_config()
    local text = truncate_text(string_arg("text", DEFAULT_TEXT), MAX_TEXT_CHARS)
    local api_key = string_arg("tts_api_key", nonempty(cfg.tts_api_key))
    local base = string_arg("tts_base_url", nonempty(cfg.tts_base_url) or DEFAULT_BASE)
    local model = string_arg("tts_model", nonempty(cfg.tts_model) or DEFAULT_MODEL)
    local voice = string_arg("tts_voice", nonempty(cfg.tts_voice) or DEFAULT_VOICE)
    local volume = tonumber(a.tts_volume) or tonumber(cfg.tts_volume) or DEFAULT_VOLUME
    if volume < 0 then volume = 0 end
    if volume > 100 then volume = 100 end
    local timeout_ms = tonumber(a.timeout_ms) or DEFAULT_TIMEOUT_MS

    if not api_key then
        error("tts_api_key missing: set it in LLM page Voice/ASR, or pass tts_api_key")
    end

    local url = join_url(base, "/audio/speech")
    local body = json.encode({
        model = model,
        input = text,
        voice = voice,
        response_format = "mp3",
    })

    local root = storage.get_root_dir()
    local voice_dir = storage.join_path(root, "voice")
    local out_path = storage.join_path(voice_dir, "tts.mp3")
    storage.mkdir(voice_dir)

    print(string.format("[tts_only] text=%s", text))
    print(string.format("[tts_only] url=%s", url))

    local ok, out, err = capability.call("http_request", {
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        body = body,
        timeout_ms = timeout_ms,
        save_path = out_path,
        max_file_bytes = 512 * 1024,
    }, {
        source_cap = "tts_only",
    })

    if not ok then
        error(string.format("TTS HTTP failed: %s", tostring(err or out)))
    end
    print(string.format("[tts_only] http out=%s", tostring(out)))

    local codec, rate, channels, bits = board_manager.get_audio_codec_output_params("audio_dac")
    if not codec then
        error("get_audio_codec_output_params(audio_dac) failed: " .. tostring(rate))
    end

    local output = assert(audio.new_output({ codec, rate, channels, bits, volume = volume }))
    local player = assert(audio.player({ output = output }))

    local pok, perr = xpcall(function()
        print(string.format("[tts_only] play %s", out_path))
        player:play(out_path, { wait = true })
    end, debug.traceback)

    pcall(function() player:close() end)
    pcall(function() output:close() end)

    if not pok then
        error(perr)
    end
    print("[tts_only] done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    error(err)
end
