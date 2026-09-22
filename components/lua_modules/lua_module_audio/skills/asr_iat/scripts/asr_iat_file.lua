-- B': iFlytek Spark IAT file ASR (16kHz mono WAV/raw PCM -> final text).
-- Does not capture mic; caller supplies a file path.

local capability = require("capability")
local crypto = require("crypto")
local json = require("json")
local storage = require("storage")
local system = require("system")
local websocket = require("websocket")

local a = type(args) == "table" and args or {}

-- iFlytek IAT v2 voicedictation (zh_cn, domain=iat)
-- Official endpoint for 语音听写 — not the old Spark LLM wss://iat.xf-yun.com/v1
local DEFAULT_ENDPOINT = "wss://iat-api.xfyun.cn/v2/iat"
local DEFAULT_FRAME_MS = 40
local DEFAULT_TIMEOUT_MS = 30000
local SAMPLE_RATE = 16000
local CHANNELS = 1
local BITS = 16
local BYTES_PER_MS = SAMPLE_RATE * CHANNELS * (BITS / 8) / 1000 -- 32

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

local function nonempty(s)
    if type(s) == "string" and s ~= "" then
        return s
    end
    return nil
end

-- IAT only speaks WebSocket. Web config may hold an HTTPS console URL like
-- https://iat-api.xfyun.cn/v1; normalise it to the real WSS endpoint before
-- signing and connecting, otherwise the HMAC host and the socket host diverge
-- and iFlytek returns 403 "Sec-WebSocket-Accept not found".
local function normalize_asr_endpoint(ep)
    local fallback = DEFAULT_ENDPOINT
    if type(ep) ~= "string" or ep == "" then
        return fallback
    end
    -- Accept official IAT v2 endpoints as-is
    if ep:match("^wss://iat%-api%.xfyun%.cn/v2/iat") then
        return ep
    end
    if ep:match("^wss://ws%-api%.xfyun%.cn/v2/iat") then
        return ep
    end
    -- Legacy/wrong endpoints -> rewrite to official v2
    if ep:match("^https?://iat%-api%.xfyun%.cn") then
        return fallback
    end
    if ep:match("^wss://iat%.xf%-yun%.com") then
        return fallback
    end
    if ep:match("^wss://") then
        return ep
    end
    return fallback
end

local function load_voice_config()
    local ok, out = capability.call("voice_config_get", {}, { source_cap = "asr_iat" })
    if not ok or type(out) ~= "string" or out == "" then
        return {}
    end
    local dok, cfg = pcall(json.decode, out)
    if dok and type(cfg) == "table" then
        return cfg
    end
    return {}
end

-- RFC1123 GMT date, e.g. "Mon, 13 Sep 2026 08:00:00 GMT"
local function http_date_now()
    -- IAT auth requires GMT / UTC date string.
    local ok, s = pcall(function()
        return os.date("!%a, %d %b %Y %H:%M:%S GMT")
    end)
    if ok and type(s) == "string" and #s > 10 then
        return s
    end
    -- Fallback: system.date is local time; only use if TZ is already UTC.
    if system.date then
        local ok2, s2 = pcall(system.date, "%a, %d %b %Y %H:%M:%S GMT")
        if ok2 and type(s2) == "string" and #s2 > 10 then
            return s2
        end
    end
    error("cannot format GMT date for IAT auth")
end

local function parse_wav_pcm(raw)
    if not raw or #raw < 44 then
        return nil, "file too small"
    end
    if raw:sub(1, 4) ~= "RIFF" or raw:sub(9, 12) ~= "WAVE" then
        -- treat as raw PCM
        return raw
    end
    -- Find "data" chunk
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
            -- fmt chunk is earlier; stereo files are 4 bytes/frame — take left channel
            local ch = 1
            local fpos = 13
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
                if fsize % 2 == 1 then
                    fpos = fpos + 1
                end
            end
            if ch == 2 then
                -- ES7210 dual-mic, near-co-located: MIC1 (L) is the speech channel,
                -- MIC2 (R) is the reference. The two mics sit close together and face
                -- the same direction, so their signals are highly correlated — averaging
                -- or differencing them does NOT improve SNR here, it only scales the
                -- amplitude. Take L (MIC1) as-is; auto-gain below lifts the level.
                local frames = math.floor(#pcm / 4)
                local lsum, rsum, lpeak, rpeak = 0, 0, 0, 0
                local out = {}
                local dokd, delaym = pcall(require, "delay")
                for i = 0, frames - 1 do
                    local o = i * 4
                    local lv = string.byte(pcm, o + 1) + string.byte(pcm, o + 2) * 256
                    local rv = string.byte(pcm, o + 3) + string.byte(pcm, o + 4) * 256
                    if lv > 32767 then lv = lv - 65536 end
                    if rv > 32767 then rv = rv - 65536 end
                    local la = lv < 0 and -lv or lv
                    local ra = rv < 0 and -rv or rv
                    lsum = lsum + la
                    rsum = rsum + ra
                    if la > lpeak then lpeak = la end
                    if ra > rpeak then rpeak = ra end
                    out[#out + 1] = pcm:sub(o + 1, o + 2)
                    -- ponytail: yield every 1024 frames (~23ms of 16k audio) to feed the
                    -- task_wdt; 4096 was too coarse and starved IDLE0.
                    if dokd and delaym and delaym.delay_ms and (i % 1024) == 1023 and i > 0 then
                        delaym.delay_ms(1)
                    end
                end
                print(string.format("[asr_iat] stereo frames=%d Lavg=%d Ravg=%d Lpeak=%d Rpeak=%d use=L",
                                    frames,
                                    frames > 0 and math.floor(lsum / frames) or 0,
                                    frames > 0 and math.floor(rsum / frames) or 0,
                                    lpeak, rpeak))
                local mono = table.concat(out)
                print(string.format("[asr_iat] mono_bytes=%d", #mono))
                return mono
            end
            return pcm
        end
        pos = body + size
        if size % 2 == 1 then
            pos = pos + 1
        end
    end
    return nil, "WAV data chunk not found"
end

local function build_auth_url(endpoint, app_id, api_key, api_secret)
    -- endpoint like wss://iat.xf-yun.com/v1
    local scheme, hostport, path = endpoint:match("^(wss?)://([^/]+)(/.*)$")
    if not scheme then
        return nil, "bad asr_endpoint"
    end
    path = path or "/v1"
    local host = hostport:match("^([^:]+)") or hostport
    local date = http_date_now()
    -- signature_origin = "host: " .. host .. "\n" .. "date: " .. date .. "\n" .. "GET " .. path .. " HTTP/1.1"
    local origin = "host: " .. host .. "\ndate: " .. date .. "\nGET " .. path .. " HTTP/1.1"
    local mac = crypto.hmac_sha256(api_secret, origin)
    local auth_b64 = crypto.base64_encode(mac)
    local authorization_origin = string.format(
        "api_key=\"%s\", algorithm=\"hmac-sha256\", headers=\"host date request-line\", signature=\"%s\"",
        api_key, auth_b64)
    -- iFlytek expects authorization = base64(auth string), then URL-encoded
    local authorization = crypto.base64_encode(authorization_origin)
    local function enc(s)
        return (s:gsub("([^%w%-_%.~])", function(c)
            if c == " " then
                return "+"
            end
            return string.format("%%%02X", string.byte(c))
        end))
    end
    local url = string.format("%s://%s%s?authorization=%s&date=%s&host=%s",
                              scheme, hostport, path,
                              enc(authorization), enc(date), enc(host))
    return url, nil, date, host
end

local function send_frame(ws, status, audio_b64, app_id, seq)
    -- iFlytek IAT v2 WebSocket protocol (official format):
    --   common.app_id + business (first frame only) + data (every frame)
    --   data.status: 0=first, 1=middle, 2=last
    seq = seq or 1
    local audio = audio_b64 or ""
    local body
    if status == 0 then
        body = string.format(
            '{"common":{"app_id":"%s"},"business":{"language":"zh_cn","domain":"iat","accent":"mandarin","vad_eos":2000},"data":{"status":0,"format":"audio/L16;rate=16000","encoding":"raw","audio":"%s"}}',
            app_id, audio)
        print("[asr_iat] first_frame_head=" .. body:sub(1, 200))
    elseif status == 2 then
        body = string.format(
            '{"common":{"app_id":"%s"},"business":{"language":"zh_cn","domain":"iat","accent":"mandarin"},"data":{"status":2,"format":"audio/L16;rate=16000","encoding":"raw","audio":""}}',
            app_id)
    else
        -- Middle frame: only data block, no common/business
        body = string.format(
            '{"data":{"status":1,"format":"audio/L16;rate=16000","encoding":"raw","audio":"%s"}}',
            audio)
    end
    local n, err = ws:send(body, 10)
    if not n then
        return nil, err or "send failed"
    end
    return true
end

local function extract_finals(msg)
    local dok, obj = pcall(json.decode, msg)
    if not dok or type(obj) ~= "table" then
        return nil
    end
    -- IAT v2 response: { code, message, sid, data: { result: { ws[], ls, sn }, status } }
    local data = obj.data
    if type(data) ~= "table" or type(data.result) ~= "table" then
        return nil
    end
    local r = data.result
    local text = {}
    if type(r.ws) == "table" then
        for i = 1, #r.ws do
            local w = r.ws[i]
            if type(w) == "table" and type(w.cw) == "table" then
                for j = 1, #w.cw do
                    local cw = w.cw[j]
                    if type(cw) == "table" and type(cw.w) == "string" then
                        text[#text + 1] = cw.w
                    end
                end
            end
        end
    end
    local joined = table.concat(text)
    if joined == "" then
        return nil
    end
    -- IAT v2 returns incremental results per sn; return this segment's text + ls flag
    return joined, r.ls == true
end

local function stereo_pick_mono(stereo)
    -- ES7210 interleaved L/R; pick the louder channel per clip section.
    local frames = math.floor(#stereo / 4)
    if frames == 0 then
        return nil, 0, 0
    end
    local lsum, rsum = 0, 0
    for i = 0, frames - 1 do
        local o = i * 4
        local lv = string.byte(stereo, o + 1) + string.byte(stereo, o + 2) * 256
        local rv = string.byte(stereo, o + 3) + string.byte(stereo, o + 4) * 256
        if lv > 32767 then lv = lv - 65536 end
        if rv > 32767 then rv = rv - 65536 end
        lsum = lsum + (lv < 0 and -lv or lv)
        rsum = rsum + (rv < 0 and -rv or rv)
    end
    local use_right = rsum > lsum
    local out = {}
    for i = 0, frames - 1 do
        local o = i * 4
        if use_right then
            out[#out + 1] = stereo:sub(o + 3, o + 4)
        else
            out[#out + 1] = stereo:sub(o + 1, o + 2)
        end
    end
    return table.concat(out), lsum // frames, rsum // frames
end

local function drain_iat(ws, state)
    while true do
        local data, op = ws:receive(0)
        if not data then
            break
        end
        if op == "text" then
            state.last_raw = data
            state.rx_n = (state.rx_n or 0) + 1
            if state.rx_n <= 5 then
                print(string.format("[asr_iat] rx%d: %s", state.rx_n, tostring(data):sub(1, 200)))
            end
            local piece, ls = extract_finals(data)
            if piece then
                -- IAT v2 returns incremental segments; accumulate all text
                if state.accum then
                    state.accum = state.accum .. piece
                else
                    state.accum = piece
                end
                if ls then
                    state.text = state.accum
                    state.ls = true
                else
                    state.partial = state.accum
                end
            end
        elseif op == "closed" then
            state.closed = true
            break
        end
    end
end

local function run()
    local path = string_arg("path", nil)
    local stream = path == nil or a.stream == true
    local cfg = load_voice_config()
    local app_id = string_arg("asr_app_id", nonempty(cfg.asr_app_id))
    local api_key = string_arg("asr_api_key", nonempty(cfg.asr_api_key))
    local api_secret = string_arg("asr_api_secret", nonempty(cfg.asr_api_secret))
    local endpoint = normalize_asr_endpoint(string_arg("asr_endpoint", nonempty(cfg.asr_endpoint)))
    print(string.format("[asr_iat] endpoint=%s", endpoint))
    local timeout_ms = int_arg("timeout_ms", DEFAULT_TIMEOUT_MS, 1000, 120000)
    local duration_ms = int_arg("duration_ms", 8000, 500, 55000)

    if not app_id or not api_key or not api_secret then
        error("asr_app_id / asr_api_key / asr_api_secret required (LLM page Voice/ASR)")
    end
    -- IAT HMAC requires the device clock within ±300s of UTC.
    -- skip_time_sync=true skips forced re-sync (wake_listen loops sync once at start).
    if not a.skip_time_sync then
        pcall(function()
            local ok, out = capability.call("get_current_time", { force = true }, { source_cap = "asr_iat" })
            if ok and type(out) == "string" then
                print("[asr_iat] time_synced=" .. out)
            else
                print("[asr_iat] time_sync_failed=" .. tostring(out))
            end
        end)
    else
        print("[asr_iat] time_sync=skipped")
    end

    local url, aerr = build_auth_url(endpoint, app_id, api_key, api_secret)
    if not url then
        error("auth url failed: " .. tostring(aerr))
    end
    -- Connect is deferred to just before sending: iFlytek IAT closes an idle
    -- session ~10s after connect if no first frame arrives. Doing record +
    -- digital makeup first would let the WSS sit idle and get reaped.
    local ws = nil
    local function connect_ws()
        if ws then
            return ws
        end
        local c, cerr = websocket.connect(url, { timeout = 10 })
        if not c then
            error("websocket connect failed: " .. tostring(cerr))
        end
        ws = c
        return ws
    end

    local state = { text = nil, partial = nil, ls = false, closed = false, last_raw = nil }
    local first = true
    local seq = 1
    local t0 = system.millis()

    local function send_mono(status, mono)
        local b64 = crypto.base64_encode(mono or "")
        local ok, serr = send_frame(ws, status, b64, app_id, seq)
        if not ok then
            error("send frame failed: " .. tostring(serr))
        end
        seq = seq + 1
    end

    if stream then
        -- Use the proven recorder pipeline (input:read yields near-silence on this board).
        -- Capture + process first, connect right before the first frame.
        local audio = require("audio")
        local bm = require("board_manager")
        local codec, rate, ch, bits = bm.get_audio_codec_input_params("audio_adc")
        if not codec then
            error("get_audio_codec_input_params(audio_adc) failed")
        end
        local volume = int_arg("volume", 100, 0, 100)
        local pre_roll_ms = int_arg("pre_roll_ms", 1200, 0, 5000)
        local speak_prompt = a.speak_prompt ~= false
        local min_peak = int_arg("min_peak", 0, 0, 32767)
        local wav_path = "/ramfs/asr_stream.wav"
        local dokd, delaym = pcall(require, "delay")
        -- Record one clip and return (mono_pcm, peak_amplitude).
        local function record_once(vol)
            local inp = assert(audio.new_input({ codec, rate, ch, bits, volume = vol }))
            local r = assert(audio.recorder({ input = inp }))
            pcall(function()
                -- Record immediately. A delay here loses the utterance that
                -- already triggered VAD (user finishes before SPEAK_NOW).
                if speak_prompt then
                    print("[asr_iat] SPEAK_NOW 请开始说话")
                end
                r:record(wav_path, {
                    duration_ms = duration_ms,
                    sample_rate = SAMPLE_RATE,
                    channels = 2,
                    bits = 16,
                })
            end)
            pcall(function() r:close() end)
            pcall(function() inp:close() end)
            local raw = storage.read_file(wav_path)
            local mono, perr = parse_wav_pcm(raw)
            pcall(storage.remove, wav_path)
            if not mono then
                error("parse stream wav failed: " .. tostring(perr))
            end
            local peak = 0
            local lsum = 0
            local nsamp = 0
            -- Skip first ~250ms: I2S/codec open often spikes to 32767.
            local skip_bytes = 8000
            if skip_bytes >= #mono - 4 then skip_bytes = 0 end
            for i = 1 + skip_bytes, #mono - 1, 2 do
                local v = string.byte(mono, i) + string.byte(mono, i + 1) * 256
                if v > 32767 then v = v - 65536 end
                local av = v < 0 and -v or v
                if av > peak then peak = av end
                lsum = lsum + av
                nsamp = nsamp + 1
            end
            local lavg = (nsamp > 0) and math.floor(lsum / nsamp) or 0
            _G.asr_last_lavg = lavg
            return mono, peak
        end

        local pcm, pk, rec_info
        pcm, pk = record_once(volume)
        _G.asr_last_peak = pk
        rec_info = { bytes = #pcm * 2, duration_ms = duration_ms }
        print(string.format("[asr_iat] recorded %dms bytes=%d in %dms mono peak=%d vol=%d",
                            duration_ms, rec_info.bytes, duration_ms, pk, volume))

        -- Local energy VAD gate: skip cloud IAT when the clip is silence/noise.
        if min_peak > 0 and pk < min_peak then
            print(string.format("[asr_iat] VAD_SKIP peak=%d < min_peak=%d", pk, min_peak))
            _G.asr_final_text = ""
            _G.asr_skipped = true
            return ""
        end
        -- Probe-only: never open WebSocket / never speak. wake_listen uses this.
        if a.local_only then
            print(string.format("[asr_iat] local_only peak=%d lavg=%d — no cloud",
                                pk, _G.asr_last_lavg or 0))
            _G.asr_final_text = ""
            _G.asr_skipped = true
            _G.asr_skipped_reason = "local_only"
            return ""
        end
        _G.asr_skipped = false

        -- Auto-gain: if the capture's peak is too low, the on-board input gain
        -- has drifted (PGA) and the stream is mostly noise. Re-record with a
        -- higher PGA so the voice becomes recognisable again.
        if pk < 3000 and volume < 100 then
            local v2 = math.min(100, volume + 20)
            print(string.format("[asr_iat] low signal, retry gain vol=%d->%d", volume, v2))
            local pcm2, pk2 = record_once(v2)
            if pk2 > pk then
                pcm, pk = pcm2, pk2
                print(string.format("[asr_iat] retry peak=%d", pk2))
            end
        end

        -- Digital makeup gain: scale PCM so peak sits near 80% of full scale.
        -- Only apply if signal is above noise floor (pk >= MIN_USEFUL_PEAK);
        -- otherwise the amplified noise triggers iFlytek 10106 / empty FINAL.
        local TARGET_PEAK = 26000
        -- Recorder path often shows pk≈3k on room noise; makeup on that is useless.
        local MIN_USEFUL_PEAK = int_arg("min_makeup_peak", 2500, 0, 32767)
        local MAKEUP_SKIP_PEAK = 7000
        if pk >= MAKEUP_SKIP_PEAK then
            print(string.format("[asr_iat] skip makeup pk=%d (already loud)", pk))
        elseif pk >= MIN_USEFUL_PEAK and pk < TARGET_PEAK then
            local scale = TARGET_PEAK / pk
            -- Cap at 150x to avoid extreme noise amplification
            if scale > 150 then scale = 150 end
            local boosted = {}
            for i = 1, #pcm - 1, 2 do
                local v = string.byte(pcm, i) + string.byte(pcm, i + 1) * 256
                if v > 32767 then v = v - 65536 end
                local s = math.floor(v * scale + 0.5)
                if s > 32767 then s = 32767 end
                if s < -32768 then s = -32768 end
                local u = s + (s < 0 and 65536 or 0)
                boosted[#boosted + 1] = string.char(u % 256, math.floor(u / 256) % 256)
                if (i % 8192) == 8191 then
                    delaym.delay_ms(1)
                end
            end
            pcm = table.concat(boosted)
            print(string.format("[asr_iat] digital makeup x%.1f -> peak~%d", scale, TARGET_PEAK))
        elseif pk < MIN_USEFUL_PEAK then
            print(string.format("[asr_iat] signal too low (pk=%d < %d), skip makeup — speak closer/louder",
                                pk, MIN_USEFUL_PEAK))
        end
        local lavg = _G.asr_last_lavg or 0
        if pk >= 4000 and lavg > 0 and lavg < 80 then
            print(string.format("[asr_iat] WARN peak=%d lavg=%d impulse-like (not sustained speech?)", pk, lavg))
        end
        local dok, delay = pcall(require, "delay")
        ws = connect_ws()
        local frame_bytes = 1280
        local offset = 1
        local sent = 0
        while offset <= #pcm do
            if system.millis() - t0 > timeout_ms then
                break
            end
            if state.closed or (state.last_raw and state.last_raw:find('"code":%s*[1-9]')) then
                print("[asr_iat] stop after server error, sent=" .. sent)
                break
            end
            local chunk = pcm:sub(offset, offset + frame_bytes - 1)
            offset = offset + #chunk
            send_mono(first and 0 or 1, chunk)
            first = false
            sent = sent + 1
            drain_iat(ws, state)
            -- ponytail: yield per-frame so the task_wdt stays fed during the long
            -- base64+send loop; the 40ms pacing below is enough on its own but the
            -- per-frame sub/b64 burst can exceed the 5s task_wdt window when the
            -- previous parse loop already ate part of it.
            if dok and delay and delay.delay_ms then
                delay.delay_ms(1)
            end
            -- Wait for first ACK before flooding the rest.
            if sent == 1 then
                local ack_t0 = system.millis()
                while system.millis() - ack_t0 < 2000 and not state.last_raw do
                    drain_iat(ws, state)
                    if dok and delay and delay.delay_ms then
                        delay.delay_ms(20)
                    end
                end
                print("[asr_iat] after_first_ack sent=" .. sent)
            end
            if dok and delay and delay.delay_ms then
                delay.delay_ms(40)
            end
        end
        print(string.format("[asr_iat] sent_frames=%d", sent))
    else
        local raw = storage.read_file(path)
        if not raw or #raw == 0 then
            error("cannot read path: " .. tostring(path))
        end
        local pcm, perr = parse_wav_pcm(raw)
        if not pcm then
            error("parse audio failed: " .. tostring(perr))
        end
        print(string.format("[asr_iat] file=%s pcm_bytes=%d", path, #pcm))
        ws = connect_ws()
        local dok, delay = pcall(require, "delay")
        local frame_bytes = 1280
        local offset = 1
        while offset <= #pcm do
            if system.millis() - t0 > timeout_ms then
                break
            end
            local chunk = pcm:sub(offset, offset + frame_bytes - 1)
            offset = offset + #chunk
            send_mono(first and 0 or 1, chunk)
            first = false
            drain_iat(ws, state)
            if dok and delay and delay.delay_ms then
                delay.delay_ms(20)
            end
        end
    end

    send_mono(2, "")
    local deadline = system.millis() + 4000
    local last_raw = nil
    while system.millis() < deadline and not state.closed and not state.ls do
        local data, op = ws:receive(0.2)
        if data and op == "text" then
            last_raw = data
            state.last_raw = data
            local piece, ls = extract_finals(data)
            if piece then
                -- Continue accumulating incremental sn segments (same as drain_iat).
                if state.accum then
                    state.accum = state.accum .. piece
                else
                    state.accum = piece
                end
                if ls then
                    state.text = state.accum
                    state.ls = true
                    break
                else
                    state.partial = state.accum
                end
            end
        elseif op == "closed" then
            break
        end
    end
    pcall(function() ws:close() end)

    local text = state.text or state.partial or state.accum or ""
    local last = state.last_raw or last_raw
    if (text == "" or text:match("^[%.。，！？%s]+$")) and last then
        print("[asr_iat] last_rx: " .. tostring(last):sub(1, 280))
    end
    _G.asr_final_text = text
    print(string.format("[asr_iat] final_len=%d ls=%s", #text, tostring(state.ls)))
    print("[asr_iat] FINAL: " .. text)
    return text
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    local msg = tostring(err or "unknown")
    local first = msg:match("([^\n]+)") or msg
    print("[asr_iat] ERR: " .. first)
    error(first)
end
