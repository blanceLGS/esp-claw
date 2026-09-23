-- wake_listen.lua
-- C' slice: local energy VAD + iFlytek IAT + wake word (default 小依) + command mode.
-- CLI only — do NOT call from root agent tool callback (agent_ask re-entrancy).
--
-- Logs go to serial print AND /ramfs/wake_listen.log (ring-safe append+flush)
-- because lua --run only keeps a 4KiB capture and the CLI tail hides history.

local capability = require("capability")
local json = require("json")
local delay = require("delay")
local system = require("system")
local storage = require("storage")

local a = type(args) == "table" and args or {}

local IAT_DIR = "/system/skills/asr_iat/scripts"
local TTS_DIR = "/system/skills/agent_then_tts/scripts"
local LOG_PATH = "/ramfs/wake_listen.log"
local KEEPALIVE_PATH = "/system/skills/voice_service/scripts/voice_keepalive.lua"
local DATA_VOLUME_NAME = "voice_tts_volume"
local DATA_ENABLE_NAME = "voice_enable"
local DATA_CMD_NAME = "voice_wake.cmd"
local DATA_WEATHER_CITY_NAME = "voice_weather_city"

local WAKE_ALIASES = {
    ["小依"] = {
        "小依", "小一", "小衣", "小医", "小椅", "小以", "小伊", "小仪",
        "晓依", "晓一", "肖依", "小意思",
        -- iFlytek common mis-hearings of xiǎo yī
        "小于", "小鱼", "小雨", "小宇", "小玉", "小予", "小瑜", "小虞",
        "小禹", "小屿", "小於", "小易", "小意", "小艺", "小翼", "小逸",
        "小谊", "小怡", "小宜", "小益", "小毅", "小忆", "小亦", "小奕",
        "晓宇", "晓鱼", "晓雨", "晓玉", "肖一", "肖宇", "肖玉",
        "校医", "小姨",
    },
    ["小Q"] = {
        "小Q", "小q", "SQ", "sq", "XQ", "xq",
        "小克", "小客", "小课", "小柯", "小可", "小渴", "小科", "小刻",
        "小颗", "小棵", "小苛", "小珂", "小轲", "小蝌",
        "晓Q", "肖Q", "小丘", "小秋", "小球", "小求",
    },
}

-- Always-on extra wake words (in addition to config CSV).
local BUILTIN_EXTRA_WAKE = { "小Q" }

-- ── Logging ───────────────────────────────────────────────────────────────

local log_fh = nil
local log_bytes = 0
-- RAMFS max is 512KiB; keep the voice log small so WAV/TTS still fit.
local LOG_MAX_BYTES = 32 * 1024

local function log_open()
    pcall(function()
        if log_fh then log_fh:close() end
    end)
    log_fh = io.open(LOG_PATH, "w")
    log_bytes = 0
    if log_fh then
        pcall(function() log_fh:setvbuf("no") end)
        local head = string.format("[wake_listen] log_open path=%s\n", LOG_PATH)
        log_fh:write(head)
        log_bytes = #head
    else
        print("[wake_listen] WARN cannot open log file " .. LOG_PATH)
    end
end

local function log_close()
    if log_fh then
        pcall(function() log_fh:close() end)
        log_fh = nil
    end
end

local function log_rotate_if_needed(add_len)
    if not log_fh then return end
    if (log_bytes + add_len) < LOG_MAX_BYTES then return end
    pcall(function() log_fh:close() end)
    log_fh = io.open(LOG_PATH, "w")
    log_bytes = 0
    if log_fh then
        pcall(function() log_fh:setvbuf("no") end)
        local head = "[wake_listen] log rotated (RAMFS cap)\n"
        log_fh:write(head)
        log_bytes = #head
    end
end

local function logf(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then
        line = fmt
    end
    print(line)
    if log_fh then
        local n = #line + 1
        log_rotate_if_needed(n)
        if log_fh then
            pcall(function()
                log_fh:write(line)
                log_fh:write("\n")
            end)
            log_bytes = log_bytes + n
        end
    end
end

local function cleanup_ramfs_temps()
    pcall(storage.remove, "/ramfs/asr_stream.wav")
    pcall(storage.remove, "/ramfs/tts_live.mp3")
    pcall(storage.remove, "/ramfs/voice_wake.keepalive")
end

-- ── DATA root helpers (phase-2 product switches / persisted volume) ───────

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

local function write_data_text(name, text)
    local path = data_file(name)
    local ok, err = pcall(storage.write_file, path, tostring(text or ""))
    return ok == true, err
end

-- ── Config helpers ────────────────────────────────────────────────────────

local function int_arg(key, default, lo, hi)
    local n = tonumber(a[key])
    if not n then return default end
    n = math.floor(n)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

local function bool_arg(key, default)
    local v = a[key]
    if v == nil then return default end
    if v == true or v == 1 or v == "1" or v == "true" then return true end
    if v == false or v == 0 or v == "0" or v == "false" then return false end
    return default
end

local function load_voice_config()
    local ok, out = capability.call("voice_config_get", {}, { source_cap = "wake_listen" })
    if not ok or type(out) ~= "string" or out == "" then return {} end
    local dok, cfg = pcall(json.decode, out)
    if dok and type(cfg) == "table" then return cfg end
    return {}
end

local function parse_wake_words(csv)
    local words = {}
    local seen = {}
    local function add(w)
        if type(w) ~= "string" then return end
        local trimmed = w:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" and not seen[trimmed] then
            seen[trimmed] = true
            words[#words + 1] = trimmed
        end
    end
    if type(csv) == "string" and csv ~= "" then
        for w in csv:gmatch("[^,]+") do
            add(w)
        end
    end
    if #words == 0 then
        add("小依")
    end
    for _, w in ipairs(BUILTIN_EXTRA_WAKE) do
        add(w)
    end
    return words
end

local function expand_wake_words(words)
    local out, seen = {}, {}
    for _, w in ipairs(words) do
        if not seen[w] then
            seen[w] = true
            out[#out + 1] = w
        end
        local aliases = WAKE_ALIASES[w]
        if aliases then
            for _, al in ipairs(aliases) do
                if not seen[al] then
                    seen[al] = true
                    out[#out + 1] = al
                end
            end
        end
    end
    return out
end

-- ── Wake word matching ────────────────────────────────────────────────────

local function match_wake_word(text, wake_words)
    if type(text) ~= "string" or text == "" then return nil end
    local sorted = {}
    for i = 1, #wake_words do sorted[i] = wake_words[i] end
    table.sort(sorted, function(x, y) return #x > #y end)
    for _, word in ipairs(sorted) do
        if text:find(word, 1, true) then
            return word
        end
    end
    return nil
end

local function is_wake_like(text, wake_words)
    if type(text) ~= "string" or text == "" then return true end
    for _, w in ipairs(wake_words) do
        if text == w or text:find(w, 1, true) then
            return true
        end
    end
    -- Too short to be a real command after stripping wake words.
    local cleaned = text:gsub("[%s%.,!%?;:]+", "")
    for _, p in ipairs({ "，", "。", "！", "？", "、", "；", "：" }) do
        cleaned = (cleaned:gsub(p, ""))
    end
    -- 1 CJK char is 3 bytes; anything shorter than that is not a command.
    return #cleaned < 3
end

local function strip_all_wake(text, wake_words)
    if type(text) ~= "string" or text == "" then return "" end
    local t = text
    -- Longest aliases first so 小意思 is not partially eaten by 小一.
    local sorted = {}
    for i = 1, #wake_words do sorted[i] = wake_words[i] end
    table.sort(sorted, function(x, y) return #x > #y end)
    for _, w in ipairs(sorted) do
        while true do
            local i = t:find(w, 1, true)
            if not i then break end
            t = t:sub(1, i - 1) .. t:sub(i + #w)
        end
    end
    t = t:gsub("^[%s，。！？、；：,.!?;:]+", "")
    t = t:gsub("[%s，。！？、；：,.!?;:]+$", "")
    return t
end

-- Pure noise / filler ASR output should not enter Agent.
local FILLER_TEXTS = {
    ["嗯"] = true, ["嗯嗯"] = true, ["啊"] = true, ["啊啊"] = true,
    ["哦"] = true, ["噢"] = true, ["喔"] = true, ["呃"] = true,
    ["喂"] = true, ["哎"] = true, ["唉"] = true, ["咦"] = true,
    ["哈"] = true, ["呵"] = true, ["嘿嘿"] = true, ["哈哈"] = true,
    ["嗯啊"] = true, ["啊嗯"] = true,
    ["好"] = true, ["好的"] = true, ["行"] = true, ["行吧"] = true,
    ["可以"] = true, ["知道了"] = true, ["没事"] = true,
}

local function utf8_char_len(s)
    if type(s) ~= "string" or s == "" then return 0 end
    local oku, utf8 = pcall(require, "utf8")
    if oku and utf8 and utf8.len then
        local n = utf8.len(s)
        if type(n) == "number" and n > 0 then return n end
    end
    local n, i = 0, 1
    while i <= #s do
        local c = s:byte(i)
        if c >= 240 then i = i + 4
        elseif c >= 224 then i = i + 3
        elseif c >= 192 then i = i + 2
        else i = i + 1 end
        n = n + 1
    end
    return n
end

local function is_valid_command(text, wake_words)
    if type(text) ~= "string" or text == "" then
        return false, "empty"
    end
    local stripped = strip_all_wake(text, wake_words)
    -- ASCII-only punct strip (byte-safe). CJK punct is left in place.
    local cleaned = stripped:gsub("[%s%.,!%?;:]+", ""):gsub("^[，。！？、；：]+", ""):gsub("[，。！？、；：]+$", "")
    -- Also trim CJK punctuation by plain gsub of whole multi-byte chars.
    local CJK_PUNCT = { "，", "。", "！", "？", "、", "；", "：", "“", "”", "‘", "’", "…", "—" }
    for i = 1, #CJK_PUNCT do
        cleaned = (cleaned:gsub(CJK_PUNCT[i], ""))
    end
    cleaned = cleaned:gsub("%s+", "")
    if cleaned == "" then
        return false, "punct-only"
    end
    if FILLER_TEXTS[cleaned] or FILLER_TEXTS[stripped] then
        return false, "filler"
    end
    if is_wake_like(stripped, wake_words) then
        return false, "wake-like"
    end
    -- Lua # is bytes; CJK is 3 bytes/char. Count chars, not bytes.
    if utf8_char_len(cleaned) < 2 then
        return false, "too-short"
    end
    return true, stripped ~= "" and stripped or cleaned
end

-- Forward decls: try_agent_from_command must see agent_and_tts (Lua locals).
local agent_and_tts
local speak_wake_ack
local followup_until = 0
local wake_ack_on = true
local tts_volume_on = nil
local handle_local_device
-- Half-duplex: ignore VAD while TTS speaker is still ringing (echo).
local echo_guard_until = 0
local echo_guard_ms = 500

local LIVE_INFO_KEYS = {
    "天气", "新闻", "气温", "温度", "实时",
    "股市", "股价", "汇率", "比赛", "比分",
}
-- 几点/日期 handled locally; keep them out of live search.

local function wants_live_info(text)
    if type(text) ~= "string" then return false end
    for i = 1, #LIVE_INFO_KEYS do
        if text:find(LIVE_INFO_KEYS[i], 1, true) then
            return true
        end
    end
    return false
end

local function wants_weather(text)
    return type(text) == "string" and (
        text:find("天气", 1, true) or text:find("气温", 1, true) or text:find("温度", 1, true))
end

local WEATHER_CITY = {
    ["北京"] = { lat = 39.90, lon = 116.40 },
    ["上海"] = { lat = 31.23, lon = 121.47 },
    ["广州"] = { lat = 23.13, lon = 113.26 },
    ["深圳"] = { lat = 22.54, lon = 114.06 },
    ["杭州"] = { lat = 30.27, lon = 120.15 },
    ["成都"] = { lat = 30.57, lon = 104.07 },
    ["武汉"] = { lat = 30.59, lon = 114.31 },
    ["西安"] = { lat = 34.34, lon = 108.94 },
    ["南京"] = { lat = 32.06, lon = 118.80 },
    ["重庆"] = { lat = 29.56, lon = 106.55 },
    ["厦门"] = { lat = 24.48, lon = 118.09 },
    ["福州"] = { lat = 26.07, lon = 119.30 },
    ["苏州"] = { lat = 31.30, lon = 120.58 },
    ["天津"] = { lat = 39.13, lon = 117.20 },
    ["长沙"] = { lat = 28.23, lon = 112.94 },
    ["郑州"] = { lat = 34.75, lon = 113.63 },
    ["青岛"] = { lat = 36.07, lon = 120.38 },
    ["大连"] = { lat = 38.91, lon = 121.61 },
    ["昆明"] = { lat = 25.04, lon = 102.71 },
    ["合肥"] = { lat = 31.82, lon = 117.23 },
    ["济南"] = { lat = 36.65, lon = 117.12 },
    ["沈阳"] = { lat = 41.80, lon = 123.43 },
    ["哈尔滨"] = { lat = 45.80, lon = 126.53 },
    ["石家庄"] = { lat = 38.04, lon = 114.51 },
    ["南昌"] = { lat = 28.68, lon = 115.86 },
    ["贵阳"] = { lat = 26.65, lon = 106.63 },
    ["南宁"] = { lat = 22.82, lon = 108.32 },
    ["海口"] = { lat = 20.04, lon = 110.34 },
    ["三亚"] = { lat = 18.25, lon = 109.51 },
    ["兰州"] = { lat = 36.06, lon = 103.83 },
    ["太原"] = { lat = 37.87, lon = 112.55 },
    ["无锡"] = { lat = 31.49, lon = 120.31 },
    ["宁波"] = { lat = 29.87, lon = 121.55 },
    ["温州"] = { lat = 28.00, lon = 120.67 },
    ["佛山"] = { lat = 23.02, lon = 113.12 },
    ["东莞"] = { lat = 23.02, lon = 113.75 },
    ["珠海"] = { lat = 22.27, lon = 113.58 },
    ["香港"] = { lat = 22.32, lon = 114.17 },
    ["澳门"] = { lat = 22.19, lon = 113.54 },
    ["台北"] = { lat = 25.03, lon = 121.57 },
}

-- Geocode pinyin/English names when Chinese name is not in the table.
local WEATHER_CITY_EN = {
    ["厦门"] = "Xiamen",
    ["北京"] = "Beijing",
    ["上海"] = "Shanghai",
    ["广州"] = "Guangzhou",
    ["深圳"] = "Shenzhen",
    ["杭州"] = "Hangzhou",
    ["成都"] = "Chengdu",
    ["武汉"] = "Wuhan",
    ["西安"] = "Xian",
    ["南京"] = "Nanjing",
    ["重庆"] = "Chongqing",
    ["香港"] = "Hong Kong",
}

local CITY_STOPWORDS = {
    ["今天"] = true, ["明天"] = true, ["后天"] = true, ["昨天"] = true,
    ["怎么"] = true, ["什么"] = true, ["如何"] = true, ["那边"] = true,
    ["现在"] = true, ["今日"] = true, ["的"] = true, ["查"] = true,
    ["一下"] = true, ["帮我"] = true, ["请问"] = true,
}

local WEATHER_CODE_CN = {
    [0] = "晴", [1] = "基本晴", [2] = "多云", [3] = "阴",
    [45] = "雾", [48] = "雾凇",
    [51] = "小毛毛雨", [53] = "毛毛雨", [55] = "大毛毛雨",
    [61] = "小雨", [63] = "中雨", [65] = "大雨",
    [66] = "冻雨", [67] = "强冻雨",
    [71] = "小雪", [73] = "中雪", [75] = "大雪", [77] = "雪粒",
    [80] = "小阵雨", [81] = "阵雨", [82] = "强阵雨",
    [85] = "小阵雪", [86] = "大阵雪",
    [95] = "雷阵雨", [96] = "雷阵雨伴冰雹", [99] = "强雷暴冰雹",
}

local function url_encode(s)
    return (tostring(s):gsub("[^%w%-%.~_]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function city_from_command(command)
    if type(command) ~= "string" then return nil end
    -- Longest city name first so 哈尔滨 wins over 哈.
    local names = {}
    for name in pairs(WEATHER_CITY) do
        names[#names + 1] = name
    end
    table.sort(names, function(a, b) return #a > #b end)
    for _, name in ipairs(names) do
        if command:find(name, 1, true) then
            return name
        end
    end
    -- 2-CJK-char city just before 天气/气温/温度 (e.g. 查一下厦门天气).
    local pat = "([\228-\233][\128-\191][\128-\191][\228-\233][\128-\191][\128-\191])"
    local two = command:match(pat .. "天气") or command:match(pat .. "气温")
        or command:match(pat .. "温度")
    if two and not CITY_STOPWORDS[two] then
        return two
    end
    return nil
end

local function geocode_city(name)
    if type(name) ~= "string" or name == "" then return nil, nil, nil end
    local q = WEATHER_CITY_EN[name] or name
    local url = "https://geocoding-api.open-meteo.com/v1/search?name="
        .. url_encode(q) .. "&count=1&language=zh&format=json"
    local ok, out = capability.call("http_request", {
        url = url,
        method = "GET",
        timeout_ms = 6000,
        max_body_bytes = 2048,
    }, { source_cap = "wake_listen" })
    if not ok or type(out) ~= "string" then
        return nil, nil, nil
    end
    local body = out:gsub("^HTTP %d+[^\r\n]*\r?\n", "")
    local dok, obj = pcall(json.decode, body)
    if not dok or type(obj) ~= "table" or type(obj.results) ~= "table" then
        return nil, nil, nil
    end
    local hit = obj.results[1]
    if type(hit) ~= "table" or not hit.latitude or not hit.longitude then
        return nil, nil, nil
    end
    local label = hit.name or name
    return label, tonumber(hit.latitude), tonumber(hit.longitude)
end

local function resolve_weather_city()
    local raw = read_data_text(DATA_WEATHER_CITY_NAME) or ""
    if raw ~= "" and WEATHER_CITY[raw] then
        return raw, WEATHER_CITY[raw].lat, WEATHER_CITY[raw].lon
    end
    local lat, lon = raw:match("^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*$")
    lat, lon = tonumber(lat), tonumber(lon)
    if lat and lon then
        return raw, lat, lon
    end
    return "北京", WEATHER_CITY["北京"].lat, WEATHER_CITY["北京"].lon
end

local function arm_echo_guard()
    local ms = tonumber(echo_guard_ms) or 500
    if ms < 100 then ms = 100 end
    if ms > 3000 then ms = 3000 end
    echo_guard_until = system.millis() + ms
end

local function echo_guard_active()
    return system.millis() < echo_guard_until
end

local function wait_echo_guard()
    local step = require("delay")
    while echo_guard_active() do
        pcall(function() step.delay_ms(30) end)
    end
end

local function speak_text(msg, volume)
    if type(msg) ~= "string" or msg == "" then
        return false
    end
    -- Half-duplex: TTS owns the speaker; do not listen while it plays.
    arm_echo_guard()
    _G.args = { reply_text = msg, tts_volume = volume or tts_volume_on }
    local ok, err = pcall(dofile, TTS_DIR .. "/agent_then_tts.lua")
    -- Ring-out after play (codec close + room).
    arm_echo_guard()
    if not ok then
        logf("[wake_listen] tts failed: %s", tostring(err))
        return false
    end
    return true
end

local function extract_search_query(command)
    if type(command) ~= "string" then return "" end
    local q = command
    local drop = {
        "帮我查一下", "帮我查查", "帮我看看", "帮我搜一下",
        "查一下今天", "查一下", "查查", "查询一下", "查询",
        "搜索一下", "搜一下", "告诉我",
    }
    for i = 1, #drop do
        local p = drop[i]
        local s = q:find(p, 1, true)
        if s == 1 then
            q = q:sub(#p + 1)
        end
    end
    q = q:gsub("^[%s，。！？、；：,.!?;:]+", "")
    q = q:gsub("[%s，。！？、；：,.!?;:]+$", "")
    -- Bare weather phrases search poorly ("这天气"); pin a Chinese city.
    if q ~= "" and (q:find("天气", 1, true) or q:find("气温", 1, true)) then
        local city = city_from_command(q) or select(1, resolve_weather_city())
        return city .. "今天天气 气温"
    end
    if q == "" then
        return command
    end
    return q
end

local function looks_chinese(s)
    return type(s) == "string" and s:find("[\228-\233]") ~= nil
end

local function clean_snippet(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("##+%s*", "")
    s = s:gsub("[%*`_]", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if #s < 8 then return nil end
    return s
end

-- SEO / wrong-region titles make terrible speech.
local SEO_MARKERS = {
    "14天", "15天", "7天预报", "天气预报一周", "天气预报15天",
    "休斯敦", "休士頓", "纽约", "美国", "WeatherBug", "National Weather",
}
local function looks_seo(s)
    if type(s) ~= "string" then return true end
    for i = 1, #SEO_MARKERS do
        if s:find(SEO_MARKERS[i], 1, true) then
            return true
        end
    end
    return false
end

local function build_search_spoken(raw)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    if raw:find("No web results", 1, true) then
        return "没有查到相关实时信息。"
    end
    local titles = {}
    local desc = nil
    local temps = {}
    for line in raw:gmatch("[^\r\n]+") do
        for t in line:gmatch("[+-]?%d+%.?%d*°C") do
            temps[#temps + 1] = t
        end
        local title = line:match("^%s*%d+%.%s*(.+)$")
        if title then
            title = clean_snippet(title)
            if title and title ~= "(no title)" and not looks_seo(title) then
                if looks_chinese(title) and #title <= 36 then
                    table.insert(titles, 1, title)
                elseif not looks_seo(title) and #title <= 48 then
                    titles[#titles + 1] = title
                end
            end
        elseif not desc then
            local d = clean_snippet(line:match("^%s+(%S.*)$"))
            if d and not d:find("^https?://", 1) and looks_chinese(d)
                    and not looks_seo(d) and #d <= 80 then
                desc = d
            end
        end
    end
    if #temps > 0 then
        local msg = "现在气温大约" .. temps[1]:gsub("°C", "度")
        if titles[1] and not looks_seo(titles[1]) then
            msg = msg .. "，" .. titles[1]
        end
        return msg .. "。"
    end
    if #titles == 0 then
        return "搜索没有返回可用结果。"
    end
    local msg = "查到了。" .. titles[1]
    if desc and not desc:find(titles[1], 1, true) then
        if #desc > 50 then
            desc = desc:sub(1, 50)
        end
        msg = msg .. "。" .. desc
    end
    return msg
end

-- Weather first-party: Open-Meteo current conditions (no web_search SEO).
local function try_weather_speak(command, volume)
    local cmd_city = city_from_command(command)
    local city, lat, lon = resolve_weather_city()
    if cmd_city then
        if WEATHER_CITY[cmd_city] then
            city = cmd_city
            lat, lon = WEATHER_CITY[cmd_city].lat, WEATHER_CITY[cmd_city].lon
        else
            local label, glat, glon = geocode_city(cmd_city)
            if glat and glon then
                city = label or cmd_city
                lat, lon = glat, glon
            else
                city = cmd_city
            end
        end
    end
    local url = string.format(
        "https://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&current=temperature_2m,weather_code&timezone=auto",
        lat, lon)
    logf("[wake_listen] weather city=%s lat=%.2f lon=%.2f", city, lat, lon)
    local ok, out, err = capability.call("http_request", {
        url = url,
        method = "GET",
        timeout_ms = 8000,
        max_body_bytes = 4096,
    }, { source_cap = "wake_listen" })
    if not ok then
        logf("[wake_listen] weather http failed: %s", tostring(err or out))
        return nil
    end
    local body = out
    if type(body) == "string" then
        -- cap_http_request returns "HTTP <status>\n<body>"
        body = body:gsub("^HTTP %d+[^\r\n]*\r?\n", "")
    end
    logf("[wake_listen] weather body=%s", tostring(body):sub(1, 180))
    if type(body) == "string" and body:find("{", 1, true) then
        local dok, obj = pcall(json.decode, body)
        if dok and type(obj) == "table" then
            local cur = obj.current or obj
            local temp = cur and (cur.temperature_2m or cur.temp)
            local code = cur and (cur.weather_code or cur.weathercode)
            if temp then
                local desc = WEATHER_CODE_CN[tonumber(code) or -1] or ""
                local spoken
                if desc ~= "" then
                    spoken = string.format("%s现在%s，气温大约%d度。", city, desc, math.floor(tonumber(temp) + 0.5))
                else
                    spoken = string.format("%s现在气温大约%d度。", city, math.floor(tonumber(temp) + 0.5))
                end
                logf("[wake_listen] weather SPOKEN: %s", spoken)
                if speak_text(spoken, volume) then
                    return spoken
                end
                return nil
            end
        end
    end
    logf("[wake_listen] weather body parse miss")
    return nil
end

-- Direct live info path: weather via Open-Meteo; else web_search + short TTS.
local function try_live_info_speak(command, volume)
    if wants_weather(command) then
        local spoken = try_weather_speak(command, volume)
        if spoken then
            return spoken
        end
        logf("[wake_listen] weather miss, fallback web_search")
    end
    local query = extract_search_query(command)
    logf("[wake_listen] live web_search query=%s", query)
    local ok, out, err = capability.call("web_search", {
        query = query,
    }, { source_cap = "wake_listen" })
    if not ok then
        logf("[wake_listen] web_search failed: %s", tostring(err or out))
        return nil
    end
    local spoken = build_search_spoken(out)
    if not spoken then
        return nil
    end
    logf("[wake_listen] live search SPOKEN: %s", spoken)
    if not speak_text(spoken, volume) then
        return nil
    end
    return spoken
end

local function stop_voice_job_soon()
    pcall(function()
        capability.call("lua_stop_async_job", {
            name = "voice_wake",
            wait_ms = 800,
        }, { source_cap = "wake_listen" })
    end)
end

local function start_voice_keepalive(reason)
    local saved = _G.args
    _G.args = { reason = reason or "voice_local" }
    local ok, err = pcall(dofile, KEEPALIVE_PATH)
    _G.args = saved
    if not ok then
        logf("[wake_listen] keepalive start failed: %s", tostring(err))
    end
end

local function try_agent_from_command(raw_command, wake_words, wake_only, agent_timeout, tts_volume, followup_ms)
    local ok_cmd, payload = is_valid_command(raw_command, wake_words)
    if not ok_cmd then
        logf("[wake_listen] command rejected (%s): %q", tostring(payload), tostring(raw_command))
        return false, "rejected"
    end
    local command = payload
    if type(command) ~= "string" or command == "" then
        command = strip_all_wake(raw_command, wake_words)
    end
    logf("[wake_listen] COMMAND: %s", command)
    if wake_only then
        logf("[wake_listen] wake_only=true, skip agent")
        return false, "wake_only"
    end
    if handle_local_device and handle_local_device(command) then
        return true, "local_device"
    end
    if type(agent_and_tts) ~= "function" then
        logf("[wake_listen] ERR agent_and_tts not ready")
        return false, "agent_nil"
    end
    if agent_and_tts(command, agent_timeout, tts_volume) and followup_ms > 0 then
        followup_until = system.millis() + followup_ms
        return true, "followup"
    end
    return false, "handled_or_fail"
end

-- ── Local energy VAD (audio.analyzer) ─────────────────────────────────────

local function open_vad(volume)
    if echo_guard_active() then
        wait_echo_guard()
    end
    local ok_audio, audio = pcall(require, "audio")
    local ok_bm, bm = pcall(require, "board_manager")
    if not ok_audio or not ok_bm then
        logf("[wake_listen] audio/board_manager unavailable, VAD=ASR-peak only")
        return nil
    end
    local codec, rate, ch, bits = bm.get_audio_codec_input_params("audio_adc")
    if not codec then
        logf("[wake_listen] codec params failed, VAD=ASR-peak only")
        return nil
    end
    local ok_inp, inp = pcall(audio.new_input, { codec, rate, ch, bits, volume = volume })
    if not ok_inp or not inp then
        logf("[wake_listen] audio.new_input failed, VAD=ASR-peak only")
        return nil
    end
    local ok_an, an = pcall(audio.analyzer, { input = inp })
    if not ok_an or not an then
        pcall(function() inp:close() end)
        logf("[wake_listen] audio.analyzer failed, VAD=ASR-peak only")
        return nil
    end
    for i = 1, 5 do
        pcall(function() an:read_level({ duration_ms = 30 }) end)
        delay.delay_ms(40)
    end
    delay.delay_ms(150)
    logf("[wake_listen] VAD analyzer ready")
    return { analyzer = an, input = inp, hits = 0, opened_at = system.millis() }
end

local function close_vad(vad)
    if not vad then return end
    pcall(function() vad.analyzer:close() end)
    pcall(function() vad.input:close() end)
end

local function poll_speech(vad, threshold, check_ms)
    if not vad then return false, 0, 0, "no_vad" end
    if echo_guard_active() then
        vad.hits = 0
        return false, 0, 0, "echo"
    end
    local ok, level = pcall(function()
        return vad.analyzer:read_level({ duration_ms = check_ms })
    end)
    if not ok or type(level) ~= "table" then
        return false, 0, 0, tostring(level)
    end
    local peak = tonumber(level.peak) or 0
    local rms = tonumber(level.rms) or 0
    local age = system.millis() - (vad.opened_at or 0)
    if age < 400 then
        vad.hits = 0
        return false, rms, peak, "warm"
    end
    if peak >= 32000 then
        vad.hits = 0
        return false, rms, peak, "sat"
    end
    -- Local speech: energy above threshold AND sustained consecutive polls.
    local loud = (peak >= threshold) and (rms >= math.floor(threshold / 3))
    -- soft_hit is for quiet lead-in only; ambient chatter stays "maybe".
    local soft = peak >= math.floor(threshold * 0.75)
    if loud then
        vad.hits = (vad.hits or 0) + 1
        return true, rms, peak, "hit"
    end
    if soft then
        vad.hits = (vad.hits or 0) + 1
        if vad.hits >= 2 then
            return true, rms, peak, "soft_hit"
        end
        return false, rms, peak, "maybe"
    end
    vad.hits = 0
    return false, rms, peak, "low"
end

-- ── ASR / agent ───────────────────────────────────────────────────────────

local time_synced = false
local last_command = nil
local last_reply = nil

local function run_asr(duration_ms, volume, opts)
    opts = opts or {}
    _G.asr_final_text = nil
    _G.asr_last_peak = nil
    _G.asr_skipped = nil
    _G.asr_last_lavg = nil
    _G.args = {
        stream = true,
        duration_ms = duration_ms,
        volume = volume,
        timeout_ms = opts.timeout_ms or 30000,
        skip_time_sync = time_synced,
        pre_roll_ms = opts.pre_roll_ms or 200,
        speak_prompt = opts.speak_prompt or false,
        min_peak = opts.min_peak or 0,
        min_makeup_peak = opts.min_makeup_peak,
        local_only = opts.local_only == true,
        -- Real-time: 400ms slices; cloud opens only after peak>=min_peak.
        chunk_ms = opts.chunk_ms or 400,
        silence_end_ms = opts.silence_end_ms or 1000,
    }
    -- Network blips must not kill the resident service.
    local ok, err = pcall(dofile, IAT_DIR .. "/asr_iat_file.lua")
    if not ok then
        logf("[wake_listen] ASR script failed (kept alive): %s", tostring(err))
        _G.asr_final_text = nil
        _G.asr_last_peak = 0
        _G.asr_skipped = true
        return "", 0, true
    end
    time_synced = true
    return _G.asr_final_text, _G.asr_last_peak or 0, _G.asr_skipped == true
end

agent_and_tts = function(command, agent_timeout, tts_volume)
    local live = wants_live_info(command)
    if live then
        -- Prefer deterministic live path (weather API / web_search) + short TTS.
        local spoken = try_live_info_speak(command, tts_volume)
        if spoken then
            last_command = command
            last_reply = spoken
            return true
        end
        logf("[wake_listen] live info miss, fallback agent_ask")
    end
    local prompt
    local tail
    if live then
        tail = "请用中文口语一两句回答；可以调用 web_search 查询实时信息（天气/新闻等）；有结果就直接总结，查不到就说明原因。"
        agent_timeout = math.max(agent_timeout or 0, 120000)
    else
        tail = "请只用中文口语一两句回答；禁止英文；禁止调用搜索或其它工具；信息不足就直接说不知道。"
    end
    if last_command and last_reply and last_command ~= "" then
        prompt = tail .. string.format("上一轮：%s；你：%s；用户：%s", last_command, last_reply, command)
    else
        prompt = tail .. "用户说：" .. command
    end
    logf("[wake_listen] agent_ask live=%s cmd=%s", tostring(live), command)
    local ok, reply, err = capability.call("agent_ask", {
        text = prompt,
        timeout_ms = agent_timeout,
    }, { source_cap = "wake_listen" })
    if not ok then
        logf("[wake_listen] agent_ask failed: %s", tostring(err or reply))
        return false
    end
    if type(reply) ~= "string" or reply == "" then
        logf("[wake_listen] agent_ask empty reply")
        return false
    end
    if reply:sub(1, 1) == '"' then
        local dok, decoded = pcall(json.decode, reply)
        if dok and type(decoded) == "string" then reply = decoded end
    end
    if not reply:find("[\228-\233]") then
        logf("[wake_listen] non-Chinese reply -> fallback: %s", reply)
        reply = "我没听清，请用中文再说一遍。"
    end
    logf("[wake_listen] REPLY: %s", reply)
    last_command = command
    last_reply = reply
    speak_text(reply, tts_volume)
    return true
end

handle_local_device = function(text)
    if type(text) ~= "string" or text == "" then return false end
    local base = tonumber(tts_volume_on) or 80

    -- Voice service on/off (no agent). Keepalive honors DATA voice_enable.
    if text:find("关闭语音", 1, true) or text:find("暂停语音", 1, true)
            or text:find("停止语音", 1, true) or text:find("停止监听", 1, true)
            or text:find("关闭监听", 1, true) then
        write_data_text(DATA_ENABLE_NAME, "0")
        logf("[wake_listen] local voice_enable=0 (no agent)")
        speak_text("好的，语音服务已关闭", base)
        stop_voice_job_soon()
        return true
    end
    if text:find("打开语音", 1, true) or text:find("开启语音", 1, true)
            or text:find("开始监听", 1, true) or text:find("恢复语音", 1, true) then
        write_data_text(DATA_ENABLE_NAME, "1")
        logf("[wake_listen] local voice_enable=1 (no agent)")
        speak_text("好的，语音服务已打开", base)
        start_voice_keepalive("voice_local_enable")
        return true
    end

    -- Local clock (no agent, no web_search).
    if text:find("几点", 1, true) or text:find("什么时间", 1, true)
            or text:find("现在时间", 1, true) or text:find("日期", 1, true)
            or text:find("几号", 1, true) then
        local ok, out = capability.call("get_current_time", {}, { source_cap = "wake_listen" })
        if ok and type(out) == "string" and out ~= "" then
            local spoken = out
            local mo, dy = out:match("%d+%-(%d+)%-(%d+)")
            local time_part = out:match("(%d+:%d+)")
            if mo and dy and time_part then
                spoken = string.format("%s月%s日 %s", mo, dy, time_part)
            elseif time_part then
                spoken = time_part
            end
            logf("[wake_listen] local time -> %s (raw=%s)", spoken, out)
            speak_text("现在是" .. spoken, tts_volume_on)
            return true
        end
        logf("[wake_listen] get_current_time failed: %s", tostring(out))
        speak_text("抱歉，现在还拿不到时间。", tts_volume_on)
        return true
    end

    local new_vol = nil
    local msg = nil
    -- Volume verbs must be explicit; bare "大声"/"N%" in TV speech must NOT count.
    if text:find("静音", 1, true) and not text:find("取消", 1, true) then
        new_vol = 0
        msg = "好的，已静音"
    elseif text:find("取消静音", 1, true) or text:find("恢复音量", 1, true) then
        new_vol = 80
        if base > 0 then new_vol = base end
        if new_vol < 40 then new_vol = 80 end
        msg = string.format("好的，音量已恢复到百分之%d", new_vol)
    end
    local pct = text:match("音量调到%s*(%d+)") or text:match("音量设为%s*(%d+)")
        or (text:find("音量", 1, true) and text:match("(%d+)%s*%%"))
    if not new_vol and pct then
        new_vol = tonumber(pct)
        if new_vol then
            if new_vol < 0 then new_vol = 0 end
            if new_vol > 100 then new_vol = 100 end
            msg = string.format("好的，音量已调到百分之%d", new_vol)
        end
    end
    local louder = text:find("大声点", 1, true) or text:find("大点声", 1, true)
        or text:find("大声一些", 1, true) or text:find("音量大", 1, true)
        or text:find("说大声", 1, true)
    local softer = text:find("小声点", 1, true) or text:find("小点声", 1, true)
        or text:find("小声一些", 1, true) or text:find("音量小", 1, true)
        or text:find("说小声", 1, true)
    if not new_vol and louder then
        new_vol = math.min(100, base + 15)
        msg = string.format("好的，音量已调到百分之%d", new_vol)
    elseif not new_vol and softer then
        new_vol = math.max(10, base - 15)
        msg = string.format("好的，音量已调到百分之%d", new_vol)
    end
    if not new_vol then return false end
    tts_volume_on = new_vol
    write_data_text(DATA_VOLUME_NAME, tostring(new_vol))
    logf("[wake_listen] local volume -> %d (no agent, persisted)", new_vol)
    speak_text(msg or string.format("好的，音量已调到百分之%d", new_vol), new_vol)
    return true
end

-- Short fixed TTS so the user knows mic is in command mode (no agent_ask).
speak_wake_ack = function(tts_volume)
    logf("[wake_listen] wake ack TTS: 我在")
    speak_text("我在", tts_volume)
end

local function is_command_like(text)
    if type(text) ~= "string" or text == "" then return false end
    -- Do NOT byte-class-strip CJK punctuation: Lua patterns are byte-based and
    -- will corrupt UTF-8. Match on raw text.
    local short_keys = {
        "音量", "大声点", "小声点", "大点声", "小点声", "静音",
        "几点", "几号", "日期", "时间",
        "天气", "气温", "温度", "新闻", "查询", "查下", "帮我",
        "关闭语音", "打开语音", "暂停语音", "停止监听", "开始监听",
    }
    for i = 1, #short_keys do
        if text:find(short_keys[i], 1, true) then return true end
    end
    -- Loose weather needs a real question, not TV noise like "1今天天气".
    if text:find("天气", 1, true) or text:find("气温", 1, true) then
        if text:find("怎么样", 1, true) or text:find("如何", 1, true)
                or text:find("查", 1, true) or text:find("多少", 1, true)
                or text:find("今天", 1, true) or text:find("明天", 1, true) then
            return true
        end
    end
    local keys = {
        "什么", "打开", "播放", "翻译", "提醒", "定时", "实时",
    }
    for i = 1, #keys do
        if text:find(keys[i], 1, true) and utf8_char_len(text) >= 4 then
            return true
        end
    end
    return false
end

-- Local verbs safe to run without wake word (high precision).
local function is_safe_local_without_wake(text)
    if type(text) ~= "string" then return false end
    local safe = {
        "关闭语音", "打开语音", "暂停语音", "开启语音", "恢复语音",
        "停止监听", "开始监听", "关闭监听",
        "静音", "取消静音",
        "音量", "大声点", "小声点", "大点声", "小点声",
    }
    for i = 1, #safe do
        if text:find(safe[i], 1, true) then return true end
    end
    return false
end

local function handle_wake_text(heard, wake_words, wake_only, agent_timeout, tts_volume, exit_on_wake, followup_ms)
    local wake_word = match_wake_word(heard, wake_words)
    if not wake_word then
        -- Without wake word: only high-precision local verbs (volume/service).
        -- Never enter Agent on ambient speech (loose-wake false triggers).
        if handle_local_device and is_safe_local_without_wake(heard)
                and handle_local_device(heard) then
            logf("[wake_listen] loose local device: %q", heard)
            return true, "local_device"
        end
        logf("[wake_listen] no wake word in: %s", tostring(heard))
        return false, nil
    end
    logf("[wake_listen] WAKE WORD DETECTED: %s  (heard=%s)", wake_word, tostring(heard))
    if exit_on_wake then
        return true, "exit"
    end
    local ok_cmd, payload = is_valid_command(heard, wake_words)
    if ok_cmd and payload and payload ~= "" and not is_wake_like(payload, wake_words) then
        logf("[wake_listen] command in same utterance: %s", payload)
        -- Same-utterance command: skip "我在" so the answer is not delayed.
        if handle_local_device and handle_local_device(payload) then
            return true, "local_device"
        end
        if not wake_only then
            if agent_and_tts(payload, agent_timeout, tts_volume) then
                followup_until = system.millis() + (followup_ms or 0)
                return true, followup_ms > 0 and "followup" or "handled"
            end
        else
            logf("[wake_listen] wake_only=true, skip agent")
        end
        return true, "handled"
    end
    -- Wake-only: short ack so user knows to speak the command.
    if wake_ack_on then
        speak_wake_ack(tts_volume_on)
    end
    if ok_cmd == false then
        logf("[wake_listen] same-utterance command rejected (%s), enter command mode", tostring(payload))
    end
    logf("[wake_listen] entering command mode (remainder=%q), speak your command...",
         strip_all_wake(heard, wake_words))
    return true, "need_command"
end

local function dump_log_tail()
    if not log_fh then
        return
    end
    logf("[wake_listen] log_bytes=%d path=%s (rotated at %d)", log_bytes, LOG_PATH, LOG_MAX_BYTES)
end

-- ── Main ──────────────────────────────────────────────────────────────────

local function run()
    cleanup_ramfs_temps()
    log_open()
    local cfg = load_voice_config()
    local configured = parse_wake_words(cfg.voice_wake_words)
    local wake_words = expand_wake_words(configured)
    logf("[wake_listen] wake configured: %s", table.concat(configured, ", "))
    logf("[wake_listen] wake match set : %s", table.concat(wake_words, ", "))

    local vad_threshold = int_arg("vad_threshold", 2000, 200, 20000)
    local vad_check_ms = int_arg("vad_check_ms", 80, 20, 500)
    -- Local energy must stay "speech-like" this long before any cloud IAT call.
    local local_hold_ms = int_arg("local_hold_ms", 350, 80, 2000)
    -- Recorder peak below this never opens IAT (local-only reject).
    local iat_min_peak = int_arg("iat_min_peak", 2500, 500, 25000)
    local session_ms = int_arg("vad_wait_ms", 0, 0, 600000)
    local listen_window_ms = int_arg("listen_window_ms", 20000, 2000, 120000)
    local wake_record_ms = int_arg("wake_record_ms", int_arg("vad_clip_ms", 4500, 1000, 8000), 1000, 8000)
    local cmd_record_ms = int_arg("cmd_record_ms", 6000, 2000, 15000)
    local agent_timeout = int_arg("agent_timeout_ms", 120000, 5000, 180000)
    local tts_volume = a.tts_volume
    if tts_volume == nil then
        local persisted = tonumber(read_data_text(DATA_VOLUME_NAME) or "")
        if persisted then
            if persisted < 0 then persisted = 0 end
            if persisted > 100 then persisted = 100 end
            tts_volume = persisted
            logf("[wake_listen] tts_volume from DATA file: %d", persisted)
        end
    end
    local volume = int_arg("volume", 100, 0, 100)
    local max_iterations = int_arg("max_iterations", 0, 0, 1000)
    local wake_only = bool_arg("wake_only", false) or bool_arg("skip_agent", false)
    local exit_on_wake = bool_arg("exit_on_wake", false)
    local use_local_vad = bool_arg("use_local_vad", true)
    local followup_ms = int_arg("followup_ms", 20000, 0, 60000)
    local service = bool_arg("service", false)
    local wake_ack = bool_arg("wake_ack", true)
    wake_ack_on = wake_ack
    tts_volume_on = tts_volume
    echo_guard_ms = int_arg("echo_guard_ms", 500, 100, 3000)
    local rollover_ms = int_arg("rollover_ms", 60000, 10000, 600000)

    local function call_handle(heard)
        return handle_wake_text(
            heard, wake_words, wake_only, agent_timeout, tts_volume,
            exit_on_wake, followup_ms)
    end
    local cmd_pre_roll = int_arg("cmd_pre_roll_ms", 200, 0, 2000)
    local empty_retry = bool_arg("empty_retry", true)

    -- Service/resident mode: never auto-bound the loop (keepalive restarts job).
    -- CLI demo without service=true still gets a finite max_iterations for clean logs.
    if service then
        if a.max_iterations == nil then
            max_iterations = 0
        end
        if a.vad_wait_ms == nil then
            session_ms = 0
        end
        logf("[wake_listen] SERVICE mode: resident loop (job timeout_ms=0; keepalive restarts if killed)")
    elseif max_iterations == 0 and session_ms == 0 and not wake_only then
        max_iterations = 20
        logf("[wake_listen] auto max_iterations=20 for unbounded CLI run (service=true or max_iterations=0 for resident)")
    end

    logf("[wake_listen] vad_threshold=%d vad_check_ms=%d local_hold_ms=%d iat_min_peak=%d",
         vad_threshold, vad_check_ms, local_hold_ms, iat_min_peak)
    logf("[wake_listen] session_ms=%d listen_window_ms=%d", session_ms, listen_window_ms)
    logf("[wake_listen] wake_record_ms=%d cmd_record_ms=%d wake_only=%s exit_on_wake=%s use_local_vad=%s",
         wake_record_ms, cmd_record_ms, tostring(wake_only), tostring(exit_on_wake), tostring(use_local_vad))
    logf("[wake_listen] max_iterations=%s volume=%d tts_volume=%s followup_ms=%d echo_guard=%dms rollover=%dms log=%s",
         max_iterations == 0 and "infinite" or tostring(max_iterations), volume,
         tostring(tts_volume_on), followup_ms, echo_guard_ms, rollover_ms, LOG_PATH)
    logf("[wake_listen] *** SPEAK 小依 NEAR MIC after SPEAK_NOW / VAD poll ***")
    if followup_ms > 0 then
        logf("[wake_listen] after reply you have %ds to speak follow-up WITHOUT wake word", followup_ms // 1000)
    end

    pcall(function()
        local ok, out = capability.call("get_current_time", { force = true }, { source_cap = "wake_listen" })
        if ok and type(out) == "string" then
            logf("[wake_listen] time_synced=%s", out)
        end
    end)
    time_synced = true

    local t0 = system.millis()
    local session_deadline = (session_ms > 0) and (t0 + session_ms) or nil
    local iteration = 0
    local state = "listening"
    local woke_count = 0
    local vad = nil
    local vad_fail_streak = 0
    local asr_peak_mode = not use_local_vad
    local command_retry = false
    local wake_asr_retried = false
    local asr_quiet_streak = 0
    local last_beat = t0
    local last_heartbeat = t0

    if use_local_vad and not asr_peak_mode then
        vad = open_vad(volume)
        if not vad then
            asr_peak_mode = true
        end
    end

    local function session_left()
        if not session_deadline then return math.huge end
        return session_deadline - system.millis()
    end

    while true do
        iteration = iteration + 1
        if max_iterations > 0 and iteration > max_iterations then
            logf("[wake_listen] max iterations reached, exiting")
            break
        end
        if session_deadline and system.millis() >= session_deadline then
            logf("[wake_listen] session time elapsed (%dms), exiting", session_ms)
            break
        end

        if state == "listening" then
            local mode_name = "asr_peak"
            if (not asr_peak_mode) and vad then
                mode_name = "analyzer_vad"
            end
            logf("[wake_listen] #%d listening mode=%s elapsed=%dms",
                 iteration, mode_name, system.millis() - t0)

            local heard, peak, skipped = "", 0, false
            local got_speech = false

            if (not asr_peak_mode) and vad then
                local left = session_left()
                local window = math.min(listen_window_ms, left)
                if window < 500 then window = 500 end
                local poll_until = system.millis() + window
                local n = 0
                logf("[wake_listen] VAD poll thr=%d hold=%dms window=%dms (local first)",
                     vad_threshold, local_hold_ms, window)
                local hold_t0 = nil
                while system.millis() < poll_until do
                    n = n + 1
                    local speech, rms, vpeak, tag = poll_speech(vad, vad_threshold, vad_check_ms)
                    if tag == "hit" or tag == "soft_hit" then
                        -- Record immediately: extra hold delay clips the wake word.
                        logf("[wake_listen] VAD %s rms=%d peak=%d -> record now",
                             tag, rms, vpeak)
                        got_speech = true
                        break
                    elseif speech then
                        if not hold_t0 then
                            hold_t0 = system.millis()
                        end
                        if (system.millis() - hold_t0) >= local_hold_ms then
                            logf("[wake_listen] VAD hit rms=%d peak=%d held=%dms -> local gate OK",
                                 rms, vpeak, system.millis() - hold_t0)
                            got_speech = true
                            break
                        end
                    else
                        hold_t0 = nil
                    end
                    if n % 50 == 0 then
                        logf("[wake_listen] VAD listening rms=%d peak=%d tag=%s", rms, vpeak, tostring(tag))
                    end
                    delay.delay_ms(vad_check_ms)
                end
                if not got_speech then
                    -- Silence is normal. Do NOT abandon analyzer VAD.
                    logf("[wake_listen] VAD window silent, keep analyzer listening")
                    goto continue
                end
                vad_fail_streak = 0
                close_vad(vad)
                vad = nil
            else
                -- ASR-peak fallback: local-only energy probe (no cloud, no SPEAK_NOW).
                local asr_quiet = false
                if asr_peak_mode then
                    logf("[wake_listen] ASR-peak local-only probe...")
                    _, probe_peak, probe_skip = run_asr(1200, volume, {
                        min_peak = iat_min_peak,
                        pre_roll_ms = 80,
                        speak_prompt = false,
                        timeout_ms = 6000,
                        min_makeup_peak = 99999,
                        local_only = true,
                    })
                    local lavg = _G.asr_last_lavg or 0
                    -- I2S open glitch often yields peak=32767; judge by sustained lavg.
                    -- Successful wake clips had lavg>=200; room noise ~30-100 on analyzer.
                    local looks_speech = (not probe_skip)
                        and probe_peak >= iat_min_peak
                        and lavg >= 200
                    if not looks_speech then
                        asr_quiet_streak = asr_quiet_streak + 1
                        logf("[wake_listen] quiet probe pk=%d lavg=%d streak=%d — no SPEAK_NOW/cloud",
                             probe_peak, lavg, asr_quiet_streak)
                        if asr_quiet_streak >= 3 and use_local_vad then
                            logf("[wake_listen] reopen analyzer VAD")
                            vad = open_vad(volume)
                            if vad then
                                asr_peak_mode = false
                                asr_quiet_streak = 0
                            end
                        end
                        asr_quiet = true
                    else
                        asr_quiet_streak = 0
                        logf("[wake_listen] speech-like pk=%d lavg=%d -> full ASR + SPEAK_NOW",
                             probe_peak, lavg)
                    end
                end
                if asr_quiet then
                    goto continue
                end
            end

            logf("[wake_listen] ASR clip for wake check...")
            heard, peak, skipped = run_asr(wake_record_ms, volume, {
                min_peak = iat_min_peak,
                -- VAD already fired; open recorder ASAP (pre_roll_ms is unused delay).
                pre_roll_ms = 0,
                speak_prompt = false,
                timeout_ms = 25000,
                min_makeup_peak = iat_min_peak,
            })
            logf("[wake_listen] clip done: peak=%d skipped=%s text=%q (iat_min_peak=%d)",
                 peak, tostring(skipped), tostring(heard), iat_min_peak)

            -- Only re-hit cloud if local peak is clearly speech (not room noise).
            if empty_retry and (skipped or heard == "" or heard == nil)
                    and peak >= (iat_min_peak + 3000) then
                if not wake_asr_retried then
                    wake_asr_retried = true
                    logf("[wake_listen] wake ASR empty peak=%d -> re-record now (SPEAK AGAIN)", peak)
                    heard, peak, skipped = run_asr(wake_record_ms, volume, {
                        min_peak = iat_min_peak,
                        pre_roll_ms = 0,
                        speak_prompt = false,
                        timeout_ms = 25000,
                        min_makeup_peak = iat_min_peak,
                    })
                    logf("[wake_listen] re-clip peak=%d skipped=%s text=%q",
                         peak, tostring(skipped), tostring(heard))
                end
            end

            if skipped or type(heard) ~= "string" or heard == "" then
                logf("[wake_listen] ASR empty/skipped (peak=%d), back to listening", peak)
            else
                wake_asr_retried = false
                local ok_wake, action = call_handle(heard)
                if ok_wake then
                    woke_count = woke_count + 1
                    if action == "exit" then
                        logf("[wake_listen] exit_on_wake=true, stopping after wake #%d", woke_count)
                        break
                    elseif action == "need_command" then
                        state = "command"
                        command_retry = false
                        -- handle_wake_text already played "我在" on wake; do not speak twice.
                        logf("[wake_listen] wake -> command (wake_ack=%s, ack already played)", tostring(wake_ack))
                        wait_echo_guard()
                        logf("[wake_listen] command window open — speak now")
                    elseif action == "followup" then
                        state = "followup"
                        logf("[wake_listen] follow-up window open %dms — speak without wake word", followup_ms)
                    end
                end
            end
            -- Skip VAD reopen when entering command — recorder opens next anyway.
            if state ~= "command" and use_local_vad and (not asr_peak_mode) and (not vad) then
                vad = open_vad(volume)
                if not vad then
                    asr_peak_mode = true
                end
            end

        elseif state == "command" then
            logf("[wake_listen] command mode: recording (%dms) pre_roll=%d...",
                 cmd_record_ms, cmd_pre_roll)
            if vad then
                close_vad(vad)
                vad = nil
            end
            local command, cpeak, cskip = run_asr(cmd_record_ms, volume, {
                min_peak = math.max(1200, math.floor(iat_min_peak * 0.6)),
                pre_roll_ms = 0,
                -- "我在" is the cue; a second SPEAK_NOW arrives after the user finished.
                speak_prompt = false,
                timeout_ms = 30000,
                min_makeup_peak = 1200,
            })
            logf("[wake_listen] command peak=%d skipped=%s text=%q",
                 cpeak, tostring(cskip), tostring(command))
            if type(command) == "string" and command ~= "" and not cskip then
                local acted, act = try_agent_from_command(
                    command, wake_words, wake_only, agent_timeout, tts_volume, followup_ms)
                command_retry = false
                if acted and act == "followup" then
                    state = "followup"
                    logf("[wake_listen] follow-up window open %dms — speak without wake word", followup_ms)
                else
                    state = "listening"
                end
            else
                -- Empty ASR: re-recognize immediately, no TTS ack / no long wait.
                if empty_retry and not command_retry then
                    command_retry = true
                    state = "command"
                    logf("[wake_listen] command empty -> re-record immediately")
                else
                    command_retry = false
                    state = "listening"
                    logf("[wake_listen] command empty after retry, back to listening")
                end
            end
            if state ~= "command" and use_local_vad and (not asr_peak_mode) and (not vad) then
                vad = open_vad(volume)
                if not vad then
                    asr_peak_mode = true
                end
            end

        elseif state == "followup" then
            local left = followup_until - system.millis()
            if left <= 0 then
                logf("[wake_listen] follow-up window expired, wake word required again")
                state = "listening"
            else
                logf("[wake_listen] follow-up %dms left — say next part (no wake word needed)", left)
                if vad then
                    close_vad(vad)
                    vad = nil
                end
                local ftext, fpeak, fskip = run_asr(5000, volume, {
                    min_peak = math.floor(vad_threshold * 0.5),
                    pre_roll_ms = 150,
                    speak_prompt = false,
                    timeout_ms = 25000,
                    min_makeup_peak = 1200,
                })
                logf("[wake_listen] followup peak=%d skipped=%s text=%q",
                     fpeak, tostring(fskip), tostring(ftext))
                -- Empty + energy → re-recognize once immediately.
                if empty_retry and (fskip or ftext == "" or ftext == nil)
                        and fpeak >= (iat_min_peak + 2000) then
                    logf("[wake_listen] followup empty peak=%d -> re-record now", fpeak)
                    ftext, fpeak, fskip = run_asr(4000, volume, {
                        min_peak = math.max(1200, math.floor(iat_min_peak * 0.6)),
                        pre_roll_ms = 100,
                        speak_prompt = false,
                        timeout_ms = 20000,
                        min_makeup_peak = 1200,
                    })
                    logf("[wake_listen] followup re-clip peak=%d skipped=%s text=%q",
                         fpeak, tostring(fskip), tostring(ftext))
                end
                if type(ftext) == "string" and ftext ~= "" and not fskip then
                    -- Follow-up may omit wake word (post-reply window), but only a real
                    -- wake word re-enters handle_wake_text; otherwise treat as command.
                    if match_wake_word(ftext, wake_words) then
                        logf("[wake_listen] followup text treated as turn: %q", ftext)
                        local ok_wake, action = call_handle(ftext)
                        if ok_wake and action == "exit" then
                            break
                        elseif ok_wake and action == "need_command" then
                            state = "command"
                        elseif ok_wake and action == "followup" then
                            -- stay in followup
                        else
                            state = "listening"
                        end
                    else
                        local ok_cmd, payload = is_valid_command(ftext, wake_words)
                        if not ok_cmd then
                            logf("[wake_listen] followup rejected (%s): %q", tostring(payload), tostring(ftext))
                        elseif not is_command_like(payload) and utf8_char_len(payload) < 4 then
                            logf("[wake_listen] followup too weak, ignore: %q", tostring(payload))
                        else
                            logf("[wake_listen] FOLLOWUP: %s", payload)
                            if handle_local_device and handle_local_device(payload) then
                                followup_until = system.millis() + followup_ms
                            elseif agent_and_tts(payload, agent_timeout, tts_volume) then
                                followup_until = system.millis() + followup_ms
                                logf("[wake_listen] follow-up extended %dms", followup_ms)
                            else
                                state = "listening"
                            end
                        end
                    end
                else
                    logf("[wake_listen] followup empty/quiet, keep window")
                end
            end
        end

        ::continue::
        -- Always-on polish: 60s heartbeat + clock refresh for IAT HMAC.
        local now_ms = system.millis()
        if (now_ms - last_beat) >= rollover_ms then
            last_beat = now_ms
            -- Refresh SNTP periodically so HMAC does not drift past ±300s.
            if (now_ms - last_heartbeat) >= (10 * rollover_ms) then
                last_heartbeat = now_ms
                time_synced = false
                pcall(function()
                    capability.call("get_current_time", { force = true }, { source_cap = "wake_listen" })
                end)
                time_synced = true
                logf("[wake_listen] rollover heartbeat elapsed=%dms state=%s woke=%d",
                     now_ms - t0, state, woke_count)
            else
                logf("[wake_listen] alive state=%s echo_guard=%s", state, tostring(echo_guard_active()))
            end
        end
        -- Always restore analyzer VAD when idle-listening after a turn.
        if state == "listening" and use_local_vad and (not vad) then
            vad = open_vad(volume)
            if vad then
                asr_peak_mode = false
                asr_quiet_streak = 0
            else
                asr_peak_mode = true
            end
        end
        delay.delay_ms(80)
    end

    close_vad(vad)
    logf("[wake_listen] done woke_count=%d elapsed_ms=%d", woke_count, system.millis() - t0)
    dump_log_tail()
    log_close()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    local msg = tostring(err or "unknown")
    local first = msg:match("([^\n]+)") or msg
    logf("[wake_listen] ERR: %s", first)
    log_close()
    error(first)
end
