-- wake_smoke.lua
-- C' acceptance: wake-only, bounded, SPEAK_NOW each clip, log to /ramfs/wake_listen.log

args = {
    wake_only = true,
    exit_on_wake = true,
    max_iterations = 10,
    vad_wait_ms = 0,
    listen_window_ms = 8000,
    vad_threshold = 2800,
    wake_record_ms = 4000,
    volume = 100,
    use_local_vad = false,
}

dofile("/system/skills/wake_listen/scripts/wake_listen.lua")
