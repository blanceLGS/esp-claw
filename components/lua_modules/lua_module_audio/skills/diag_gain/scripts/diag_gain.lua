-- diag_gain.lua
-- Diagnostic: test ES7210 PGA gain response at different volume levels.
-- Records short clips at volume=30/60/80/100 and prints peak values.
-- If peaks don't scale with volume, PGA is not being applied correctly.

local audio = require("audio")
local board_manager = require("board_manager")
local storage = require("storage")
local delay = require("delay")

local WAV = "/ramfs/diag_gain.wav"

local function wav_peak(raw)
    if not raw or #raw < 44 then return 0 end
    local pos = 13
    local n = #raw
    while pos + 8 <= n do
        local id = raw:sub(pos, pos + 3)
        local size = string.byte(raw, pos + 4) +
                     string.byte(raw, pos + 5) * 256 +
                     string.byte(raw, pos + 6) * 65536 +
                     string.byte(raw, pos + 7) * 16777216
        local body = pos + 8
        if id == "data" then
            local endp = math.min(n, body + size - 1)
            local pcm = raw:sub(body, endp)
            local fpos = 13
            local ch = 1
            while fpos + 8 <= n do
                local fid = raw:sub(fpos, fpos + 3)
                local fsize = string.byte(raw, fpos + 4) +
                              string.byte(raw, fpos + 5) * 256 +
                              string.byte(raw, fpos + 6) * 65536 +
                              string.byte(raw, fpos + 7) * 16777216
                if fid == "fmt " and fsize >= 16 then
                    ch = string.byte(raw, fpos + 10) + string.byte(raw, fpos + 11) * 256
                    break
                end
                fpos = fpos + 8 + fsize
                if fsize % 2 == 1 then fpos = fpos + 1 end
            end
            local step = (ch == 2) and 4 or 2
            local peak = 0
            for i = 1, #pcm - 1, step do
                local v = string.byte(pcm, i) + string.byte(pcm, i + 1) * 256
                if v > 32767 then v = v - 65536 end
                local abs = v < 0 and -v or v
                if abs > peak then peak = abs end
            end
            return peak
        end
        pos = body + size
        if size % 2 == 1 then pos = pos + 1 end
    end
    return 0
end

local function run()
    local codec, rate, ch, bits = board_manager.get_audio_codec_input_params("audio_adc")
    if not codec then
        error("get_audio_codec_input_params(audio_adc) failed")
    end
    print("[diag] codec=" .. tostring(codec) .. " rate=" .. tostring(rate) .. " ch=" .. tostring(ch) .. " bits=" .. tostring(bits))

    local volumes = { 30, 60, 80, 100 }
    local results = {}

    for _, vol in ipairs(volumes) do
        print("[diag] --- volume=" .. vol .. " (expect PGA=" .. (vol * 37.5 / 100) .. "dB) ---")
        print("[diag] speak now...")

        local ok_input, inp = pcall(function()
            return audio.new_input({ codec, rate, ch, bits, volume = vol })
        end)
        if not ok_input or not inp then
            print("[diag] input open failed: " .. tostring(inp))
            goto continue
        end
        local ok_rec, r = pcall(function()
            return audio.recorder({ input = inp })
        end)
        if not ok_rec or not r then
            print("[diag] recorder open failed: " .. tostring(r))
            pcall(function() inp:close() end)
            goto continue
        end
        pcall(function()
            r:record(WAV, { duration_ms = 3000, sample_rate = 16000, channels = 2, bits = 16 })
        end)
        pcall(function() r:close() end)
        pcall(function() inp:close() end)

        local raw = storage.read_file(WAV)
        local peak = wav_peak(raw)
        results[vol] = peak
        print(string.format("[diag] volume=%d peak=%d", vol, peak))

        ::continue::
        delay.delay_ms(500)
    end

    print("[diag] === SUMMARY ===")
    for _, vol in ipairs(volumes) do
        local pk = results[vol] or 0
        print(string.format("[diag] vol=%d -> peak=%d", vol, pk))
    end
    -- Check if peak scales with volume
    local p30 = results[30] or 0
    local p100 = results[100] or 0
    if p30 > 0 and p100 > 0 then
        local ratio = p100 / p30
        print(string.format("[diag] peak ratio (100/30) = %.2f", ratio))
        if ratio > 5 then
            print("[diag] PGA IS responding to volume changes")
        else
            print("[diag] PGA NOT responding properly — gain may be stuck at 0dB")
        end
    end
    print("[diag] done")
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    local msg = tostring(err or "unknown")
    local first = msg:match("([^\n]+)") or msg
    print("[diag] ERR: " .. first)
    error(first)
end
