-- A': record fixed-length 16kHz mono WAV from board mic (ES7210 / audio_adc).

local audio = require("audio")
local board_manager = require("board_manager")
local storage = require("storage")

local a = type(args) == "table" and args or {}

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

local function run()
    local duration_ms = int_arg("duration_ms", 10000, 500, 55000)
    local out_path = string_arg("path", nil)
    local volume = int_arg("volume", 100, 0, 100)

    if not out_path then
        out_path = "/fatfs/temp/asr_in.wav"
    end

    local codec, rate, channels, bits = board_manager.get_audio_codec_input_params("audio_adc")
    if not codec then
        error("get_audio_codec_input_params(audio_adc) failed: " .. tostring(rate))
    end

    local input = assert(audio.new_input({ codec, rate, channels, bits, volume = volume }))
    local recorder = assert(audio.recorder({ input = input }))

    local ok, info_or_err = xpcall(function()
        local info = input:info()
        print(string.format("[asr_record] input=%dHz/%dch/%dbit", info.sample_rate, info.channels, info.bits))
        local rec = recorder:record(out_path, {
            duration_ms = duration_ms,
            sample_rate = 16000,
            -- Keep stereo as captured; ASRC stereo->mono currently yields silence.
            channels = 2,
            bits = 16,
        })
        print(string.format("[asr_record] path=%s bytes=%d duration_ms=%d",
                            rec.path, rec.bytes, rec.duration_ms))
        return rec
    end, debug.traceback)

    pcall(function() recorder:close() end)
    pcall(function() input:close() end)

    if not ok then
        error(info_or_err)
    end
    return info_or_err
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    error(err)
end
