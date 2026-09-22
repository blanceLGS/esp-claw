-- debug_vad.lua
-- Print system.millis and run a few analyzer polls to see levels.
local system = require("system")
local audio = require("audio")
local bm = require("board_manager")
local delay = require("delay")

print("[dbg] millis=" .. tostring(system.millis()))
print("[dbg] type(system.millis)=" .. type(system.millis))

local codec, rate, ch, bits = bm.get_audio_codec_input_params("audio_adc")
print(string.format("[dbg] codec=%s rate=%s ch=%s bits=%s", tostring(codec), tostring(rate), tostring(ch), tostring(bits)))

local inp = assert(audio.new_input({ codec, rate, ch, bits, volume = 100 }))
local an = assert(audio.analyzer({ input = inp }))
for i = 1, 6 do
    local ok, level = pcall(function()
        return an:read_level({ duration_ms = 80 })
    end)
    if ok and type(level) == "table" then
        print(string.format("[dbg] poll#%d rms=%s peak=%s millis=%s", i, tostring(level.rms), tostring(level.peak), tostring(system.millis())))
    else
        print(string.format("[dbg] poll#%d ERR %s", i, tostring(level)))
    end
    delay.delay_ms(100)
end
pcall(function() an:close() end)
pcall(function() inp:close() end)
print("[dbg] done")
