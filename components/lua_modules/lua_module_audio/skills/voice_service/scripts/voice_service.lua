-- voice_service.lua
-- Phase-1 product entry: run wake_listen in SERVICE (resident) mode.
-- Prefer starting via voice_keepalive.lua (async job name=voice_wake, timeout_ms=0).
-- Direct CLI: lua --run --path .../voice_service.lua --timeout-ms 0  (if supported)
-- or rely on keepalive/router startup rules.

args = {
    service = true,
    max_iterations = 0,
    vad_wait_ms = 0,
    wake_only = false,
    exit_on_wake = false,
    use_local_vad = true,
    followup_ms = 20000,
    -- Local-first: stricter energy before any iFlytek IAT call.
    vad_threshold = 1200,
    local_hold_ms = 200,
    iat_min_peak = 2500,
    wake_ack = true,
    empty_retry = true,
    wake_record_ms = 4500,
    cmd_record_ms = 7000,
    volume = 100,
}

dofile("/system/skills/wake_listen/scripts/wake_listen.lua")
