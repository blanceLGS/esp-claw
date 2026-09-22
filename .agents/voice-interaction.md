# Voice Interaction Development Plan

Status: **product + Phase 0 config decisions locked**; runtime = **C core + Lua thin** (not implemented yet).  
Goal: **always-on mic + keyword wake** → ASR (primary: **iFlytek Spark IAT**) → agent → TTS (SiliconFlow) → speaker.

Related: [`design.md`](design.md) · [`spec/lua-module-spec.md`](spec/lua-module-spec.md) · [`spec/claw-skill-spec.md`](spec/claw-skill-spec.md)

---

## Locked product decisions

| Topic | Decision |
|---|---|
| **UI** | Single **Voice / ASR** block on the existing **LLM** page (not a new top-level tab) |
| **Provider switch** | Switching ASR provider **does not clear** the other provider’s stored keys/fields |
| **Default wake words** | **`小依`** (CSV; user may add more) |
| **TTS in same config pass** | **Yes** — SiliconFlow **Key + voice** (and model) configurable alongside ASR |
| **iFlytek IAT endpoint default** | **`wss://iat.xf-yun.com/v1`** (accept `ws://` for non-TLS debug; product default **wss**) |

---

## 0. Product trigger (decided direction)

**Always recording; wake on spoken keyword** (default **`小依`**), then take the following utterance as the command.

IAT itself is **not** a wake-word engine. Two-stage design:

| Stage | What runs | Goal |
|---|---|---|
| **Idle** | Local **energy VAD** on 16 kHz PCM (no cloud) | Speech start; skip silence |
| **Utterance** | Stream PCM to **iFlytek IAT** (WebSocket) | Partial + final text |
| **Wake check** | Match keyword list in ASR text | Enter command window |
| **Command** | Same stream / next final after wake | User request |
| **Respond** | Agent + SiliconFlow TTS MP3 → play | Half-duplex; **mute mic during TTS** |

**Fallback (still useful):**

- **(b) File path** — debug ASR/TTS without mic loop.  
- **(a) IM command** — manual start when wake off.  
- **(c) VAD without keyword** — optional, not default.

IAT sessions cap **≤60 s** audio; always-on **cloud** streaming is not free — use local VAD.

---

## 1. Product goal

1. Mic PCM (16 kHz / 16-bit / mono).  
2. Local VAD + keyword wake (post-ASR text match for MVP).  
3. iFlytek IAT → command text.  
4. Existing agent (`claw_core` / session / skills).  
5. Reply text → SiliconFlow TTS → MP3.  
6. `audio.player` playback; reopen mic after TTS.

**MVP:** wake on IAT **final** text.  
**Later:** partial-result wake, `res_id` / `dhw` hotword boost.

---

## 2. What already exists

| Building block | Location | Notes |
|---|---|---|
| Board audio | RLCD 4.2: ES8311 DAC + ES7210 ADC | Init on boot |
| Lua audio | `lua_module_audio` | `recorder` → WAV/AAC; `analyzer`; `player` plays MP3 |
| WebSocket client | `lua_module_websocket` | Prototype IAT WSS |
| HTTP + multipart | `cap_http_request` | TTS POST + `save_path` |
| Agent / LLM | `claw_core` | Prefer agent path |
| Config | `app_claw` + `http_server` | `asr_*` partially present; extend + TTS + wake |
| Session recovery | local `/session` | Oversized-history safety |

---

## 3. iFlytek Spark IAT (中英识别大模型)

Doc: <https://www.xfyun.cn/doc/spark/spark_zh_iat.html>

| Item | Value |
|---|---|
| Protocol | **WSS** `wss://iat.xf-yun.com/v1` |
| Auth | Query `authorization` + `date` + `host` (HMAC-SHA256, base64) |
| Clock skew | **±300 s** vs UTC; **SNTP required** |
| Audio | **16 kHz or 8 kHz**, **16-bit**, **mono** |
| Encoding | `raw` (PCM) or `lame` (MP3; strip ID3) |
| Max length | **60 s** per session |
| Stream cadence | **40 ms / 1280 bytes** recommended |
| Result | base64 `payload.result.text` → JSON `{sn,ls,ws[]}` |
| Domain | `domain=slm`, `language=zh_cn`, `accent=mandarin` |

Wake-related server options (not a substitute for local VAD):

- `parameter.iat.dhw` — session hotwords, e.g. `dhw=utf-8;小依`
- `header.res_id` — console hotword resource
- `parameter.iat.eos` — silence stop (ms), e.g. 2000–6000

**PCM 16 kHz mono is first-class on IAT** → **no on-device MP3 encode required** for iFlytek ASR.  
SiliconFlow TTS still returns **MP3** for playback.

---

## 3b. ASR provider comparison

| | iFlytek IAT (**default**) | SiliconFlow transcriptions |
|---|---|---|
| Transport | WebSocket streaming | HTTP multipart |
| Auth | HMAC-SHA256 + date/host | Bearer |
| Format | PCM/WAV preferred | MP3-only (device encode if used) |
| Always-on | Stream only while speaking | File upload per clip |
| Role | **Primary** | Optional / file debug |

TTS remains **SiliconFlow** unless later ported.

---

## 4. Always-on + keyword architecture

```
mic 16k PCM
    → Local energy VAD
    → IAT WSS (PCM @40ms, dhw/res_id = wake list)
    → Wake matcher (config CSV, default 小依)
    → Command utterance
    → Agent
    → SiliconFlow TTS → MP3
    → player:play(wait) → reopen mic
```

### 4.1 IAT session / frames

- First frame: `header.status=0` + full `parameter` + audio.  
- Mid: `status=1` + audio.  
- End: `status=2` + empty audio.  
- New WSS session after 60 s, silence, or network error.  
- Honor `eos`.

### 4.2 Wake matching

1. Post-ASR text match on finals (MVP).  
2. Config CSV; default **`小依`**.  
3. On hit: command mode; strip keyword; if empty remainder, wait next final (timeout).

Not MVP: 讯飞离线「语音唤醒」SDK.

### 4.3 VAD

- `audio.analyzer` energy / RMS.  
- Open IAT only after N frames above threshold; close on trailing silence.

### 4.4 Half-duplex

- Stop recorder/IAT while TTS plays.  
- Reopen mic after playback.

---

## 5. Config (web) — Phase 0

### 5.1 UI placement

One **Voice / ASR** collapsible block on the **LLM** page.

### 5.2 Behavior on provider switch

- Dropdown: `不启用` | `SiliconFlow` | `讯飞（iFlytek）`.  
- Show only the active provider’s field set.  
- **Do not clear** the inactive provider’s stored values when switching.

### 5.3 Field catalogue

| Key | UI | Default / notes |
|---|---|---|
| `asr_provider` | ASR 方案 | `""` / `siliconflow` / `iflytek` |
| `voice_wake_words` | 唤醒提示词 | **`小依`**; CSV |
| **SiliconFlow ASR** | | |
| `asr_api_key` | API Key | Bearer |
| `asr_model` | ASR 模型 | e.g. `FunAudioLLM/SenseVoiceSmall` |
| `asr_endpoint` | 接口地址 | **`https://api.siliconflow.cn/v1`** (base only) |
| **iFlytek ASR** | | |
| `asr_app_id` | APPID | 讯飞 APPID |
| `asr_api_key` | API Key | 讯飞 APIKey |
| `asr_api_secret` | API Secret | HMAC secret |
| `asr_endpoint` | IAT 地址 | **`wss://iat.xf-yun.com/v1`** (full WSS URL; **no path suffix**) |
| **SiliconFlow TTS** | | **in same block** |
| `tts_api_key` | TTS API Key | May equal ASR key; store separately |
| `tts_base_url` | TTS Base URL | **`https://api.siliconflow.cn/v1`** (base only) |
| `tts_model` | TTS 模型 | e.g. `FunAudioLLM/CosyVoice2-0.5B` |
| `tts_voice` | TTS 音色 | e.g. `FunAudioLLM/CosyVoice2-0.5B:alex` |
| `tts_volume` | TTS 音量 | `0`–`100`（本机喇叭；默认 `80`） |
| **Runtime (optional later)** | | |
| `voice_wake_timeout_ms` | — | default `4000` |
| `voice_vad_threshold` | — | energy gate |
| `voice_eos_ms` | — | default `3000` |
| `voice_enable` | — | master switch |
| `search_http_allowlist` | existing | Must include SiliconFlow HTTP host; IAT is **WSS** |

**Security:** SNTP for date skew; mask secrets in UI where possible; never log full secrets.

**Runtime access:** Lua skills call capability `voice_config_get` (group `cap_voice_config`) to read these fields from `app_claw_get_config()` (NVS-backed RAM). Serial CLI: `voice` / `voice key`.

### 5.3.1 URL construction (SiliconFlow)

Store **API base** only (includes `/v1`). Runtime **appends the path** — do not put the operation path in config.

| Provider | Config value | Built request URL |
|---|---|---|
| SiliconFlow ASR | `asr_endpoint` = `https://api.siliconflow.cn/v1` | `{asr_endpoint}/audio/transcriptions` |
| SiliconFlow TTS | `tts_base_url` = `https://api.siliconflow.cn/v1` | `{tts_base_url}/audio/speech` |
| iFlytek IAT | `asr_endpoint` = `wss://iat.xf-yun.com/v1` | **as-is**; no extra suffix |

Rules:

- SiliconFlow: join base + `/audio/transcriptions` or `/audio/speech` in code (avoid double `/v1` or double slashes).  
- iFlytek: use the configured WSS URL unchanged (query auth params are added at connect time).  
- UI placeholders: ASR `https://api.siliconflow.cn/v1`, TTS `https://api.siliconflow.cn/v1`, IAT `wss://iat.xf-yun.com/v1`.

### 5.4 Persistence / sync

```
LLM page → POST config (groups: llm + voice)
  → app_config NVS
  → app_config_to_claw → app_claw_config
  → later: voice / IAT / TTS runtime
```

**MVP:** save + reload round-trip is enough; hot-reconnect IAT is Phase 1+.

---

## 6. Implementation phases

### Phase 0 — Config + time + allowlist

- Fields + **LLM page** UI + save/load.  
- SNTP on boot.  
- **Exit:** switch ASR provider without wiping other secrets; wake default `小依`; TTS key/voice saved; reboot keeps config.

### Phase 1 — IAT client (file or short burst)

- WSS + HMAC auth.  
- PCM 16 kHz mono from file or one recorder burst.  
- Parse base64 result JSON.  
- **Exit:** known PCM → correct Chinese text in logs.

### Phase 2 — Wake + command + TTS loop

- VAD + IAT; match **`小依`** (config CSV); agent; SiliconFlow TTS; play.  
- **Exit:** say wake word + command; hear reply.

### Phase 3 — Always-on polish

- Reconnect, 60 s rollover, echo-safe half-duplex.  
- Hotwords `dhw` / `res_id`.  
- Optional SiliconFlow ASR file debug path.

**Note:** Shine MP3 encode **not required** for iFlytek PCM path; optional later for SiliconFlow ASR fallback.

---

## 7. Runtime architecture — C core + Lua thin wrapper

**Decision:** C owns always-on audio/IAT; Lua owns orchestration (agent / TTS / play).

| Layer | Module | Owns |
|---|---|---|
| Hardware | ES7210 / ES8311 | Capture / playback |
| C core | `voice_iat` (recommended: C inside a `lua_module_*` component) | VAD, IAT WSS, HMAC, frames, wake FSM, half-duplex, reconnect |
| Lua thin | `require("voice_iat")` | `configure` / `start` / `stop` / `pause` / `resume` + events |
| Skill | e.g. `voice_chat` | command text → agent → TTS → player |
| Config | `app_config` + LLM page | provider, credentials, wake words, TTS |
| Existing | `cap_http_request`, `audio.player`, `claw_core` | TTS HTTP, MP3 play, chat |

**Rule:** exactly one owner of the mic. Pause/play is driven by C; skill must not open a second recorder.

### 7.1 Tasks and buffers

| Item | Recommendation |
|---|---|
| IAT task | Dedicated FreeRTOS task; stack **8–12 KiB**, prefer PSRAM |
| PCM ring | 2–4 × 1280 B frames in PSRAM |
| TX buffer | Single reused buffer (PCM → base64 → JSON); **no per-frame malloc** |
| Event queue | C → Lua text events; cap depth; **drop partials, keep finals** |

Avoid per-40 ms Lua strings on the always-on path (memory / GC jitter).

### 7.2 Wake + command state machine (C)

```
IDLE
  → VAD speech → LISTENING
LISTENING
  → final contains wake word → WAIT_CMD
  → silence/eos → IDLE
  → 60 s / disconnect → REOPEN → LISTENING or IDLE
WAIT_CMD
  → final non-empty (after strip) → COMMAND
  → wake_timeout → IDLE
COMMAND
  → emit command text → BUSY (wait skill)
BUSY
  → tts/play done → IDLE
any
  → auth/network error → RECONNECT (backoff)
```

MVP defaults:

- Match **final** text only (not partial).
- Strip keyword from utterance; if remainder empty, wait next final until timeout.
- `dhw` optional; default wake list is **config CSV only** (`小依`).

### 7.3 Lua thin API (draft)

```lua
local voice = require("voice_iat")

voice.configure({
  provider = "iflytek",
  app_id = ..., api_key = ..., api_secret = ...,
  endpoint = "wss://iat.xf-yun.com/v1",
  wake_words = { "小依" },
  eos_ms = 3000,
})

voice.set_handler(function(ev)
  -- ev.type = "connected"|"closed"|"error"|"partial"|"final"|"wake"
end)

voice.start()
voice.pause()   -- TTS playback
voice.resume()
voice.stop()
```

Lua must not implement WSS/HMAC/40 ms loop.

### 7.4 Skill glue (E)

```
on final (command text)
  if empty → return
  agent(text)                 -- claw_core
  voice.pause()
  http_request TTS → {DATA}/voice/tts.mp3
  audio.player play(wait)
  delete temp
  voice.resume()
```

SiliconFlow TTS: `POST {tts_base_url}/audio/speech` (`tts_base_url` already ends with `/v1`; do **not** insert another `/v1`). JSON: `model`, `input`, `voice`, `response_format=mp3`; use `save_path`.

**Before TTS:** apply **TTS length policy** (§7.6). Full reply stays in text/IM; only the spoken subset is synthesized.

### 7.5 Why C vs Lua+websocket (memory)

- Lua+WS: fine for **prototype**; higher peak (base64 JSON + queues + GC).
- C core: fixed ring buffers, fewer copies, stable always-on footprint.
- Product target: **C core + Lua thin**.

### 7.6 TTS length policy (long replies)

Long agent replies break voice UX if spoken in full: long playback, half-duplex lock, HTTP timeout, large MP3, cost. **TTS is for short spoken replies, not full articles.**

**Policy (device-side; model output is not trusted to stay short):**

1. Split reply into sentences on `。！？；…` and newlines (basic CJK/Latin punctuation).  
2. Keep only the **first N sentences** (device default now **N=6**; can lower).  
3. Hard cap characters (device default now **400**; can lower).  
4. **Never slice mid-sentence** when a later sentence does not fit — drop the remainder (avoids “cut-off” speech). Only hard-cut if a single sentence exceeds the char cap.  
5. Drop the remainder; **full text remains in IM/text**. Optional short suffix e.g. `…更多内容见文字` — product switch; default **off**.

```
reply → split_sentences → take first N that fit max_chars → TTS only that
```

**Implemented defaults (`agent_then_tts`):**

| Key | Default |
|---|---|
| `tts_max_sentences` | 6 |
| `tts_max_chars` | 400 |

**Also:** prefer prompt-side “short spoken answer” in agent system prompt; still enforce policy on device.  
**Do not** paste multi-turn history into one TTS `input`; one turn → one short spoken reply.

**Current gap:** `tts_only` skill uses a simple char truncate (`MAX_TEXT_CHARS`), not sentence-first policy. `agent_then_tts` speaks caller-supplied `reply_text` (no nested `agent_ask`) with sentence-first trim; prefer `lua_run_script_async` from agent tools.

---

## 7.7 IM product TTS path — latency (measured) and next steps

**Path (P2-B, shipped):** IM text → Agent → `out_message` → router `run_script` async → `agent_then_tts(reply_text)` with `exclusive=tts` queue; only `status=ok` is spoken.

**Measured after B+D (Feishu, RLCD, CosyVoice2):**

| Stage | Typical |
|---|---|
| Inbound → working reply | ~1.0 s |
| Agent LLM final (simple chat, no extra skills) | **~8 s** |
| Extra `activate_skill` rounds | avoided for plain chat (B) |
| TTS HTTP (full file) | ~5–6 s |
| Inbound → first audible speech | **~16 s** |
| Playback (~250 chars) | ~17 s |

Users feel “slow” mainly from **cloud LLM + full-file TTS**, not local decode/play.

### 7.7.1 SiliconFlow TTS streaming spike (2026-09, host curl — **device unchanged**)

**Endpoint:** `POST https://api.siliconflow.cn/v1/audio/speech`  
**Docs:** <https://api-docs.siliconflow.cn/docs/api/audio-speech-post> — body field **`stream`**: `false | true` for both `FunAudioLLM/CosyVoice2-0.5B` and `fnlp/MOSS-TTSD-v0.5`. Response is binary audio (`audio/mpeg` for mp3). HTTP may still use `Transfer-Encoding: chunked`.

**Method:** host curl/HttpWebRequest; measure first body byte (TTFB) vs full body; multi-round average.

**CosyVoice2 + voice `FunAudioLLM/CosyVoice2-0.5B:alex`:**

| Input | `stream` | TTFB (avg) | Total (avg) | Notes |
|---|---|---|---|---|
| ~232 CJK chars (3 rounds) | `false` | **~4.07 s** | ~4.27 s | TTFB ≈ almost full generate time |
| ~232 CJK chars (3 rounds) | `true` | **~0.33 s** | ~3.66 s | chunk gaps ~8 ms; true incremental |
| ~464 CJK chars (2 rounds) | `false` | **~7.92 s** | ~8.05 s | TTFB scales with length |
| ~464 CJK chars (2 rounds) | `true` | **~0.36 s** | ~7.26 s | TTFB stays ~0.3 s |

**MOSS-TTSD + voice `fnlp/MOSS-TTSD-v0.5:alex` (dialogue `[S1]`/`[S2]` sample):**

| Input | `stream` | TTFB | Total |
|---|---|---|---|
| Short dialogue | `false` | ~2.2 s | ~2.2 s |
| Short dialogue | `true` | ~1.9 s | ~1.9 s |

Earlier long-plain-text MOSS runs (no speaker tags) had much higher TTFB (~5–8 s); prefer official `[S1]`/`[S2]` dialogue format for MOSS.

**Spike conclusions:**

1. **`stream:true` is documented and works** on `/audio/speech` (Cosy + MOSS).  
2. **CosyVoice2 long-text win is large:** without stream, TTFB ≈ full synthesis (~4 s @232 chars, ~8 s @464 chars). With stream, **TTFB stays ~0.3–0.4 s** regardless of length; remaining time is “how long until the last byte.”  
3. **Short text** already has low TTFB; stream gain is small.  
4. **Device path does not use stream today:** `cap_http_request` + `save_path` downloads the **entire** MP3 (`.tmp` then rename), then `player:play(local file)`. Host TTFB gains do **not** appear on device until download-then-play changes.  
5. **MOSS voice id** must be `fnlp/MOSS-TTSD-v0.5:alex` (lowercase). Wrong voice → HTTP 400. Default stay **CosyVoice2** unless product wants MOSS quality.  
6. Optional: Cosy `sample_rate` mp3 supports 32000/44100 (docs); current device path does not set it (server default).

### 7.7.2 Device stream verification (2026-09, RLCD)

**Implemented (S2 minimal):**

- `http_request` **`save_direct`**: write final path immediately + `fflush` per chunk (no `.tmp` rename).
- `agent_then_tts` **`tts_stream=true` (default)**: `thread.start` worker POSTs with `stream:true` + `save_direct` to `/ramfs/tts_live.mp3`; parent polls until **`tts_min_play_bytes` (default 48 KiB)** + **~120 ms size settle**, then `player:play` while download continues.
- Fallback: `tts_stream=false` keeps full-file download to `{DATA}/voice/tts.mp3` (correct, no TTFB win).

**On-device smoke (serial CLI):**

| Case | Result |
|---|---|
| Short `hello_stream_test` (16 KiB start) | Played; TTFB ~1 s — may sound glitchy |
| English ~182 chars (16 KiB start) | User heard **word repeat** — torn MP3 frames |
| Same English (48 KiB + 120 ms settle) | Play starts @ ~52 KB; download continues to ~380 KB |
| Chinese `你好，我是小依。…` **full download** | Correct speech (~100 KB file) |
| Chinese same text **stream 48 KiB** | Correct speech; `ttfb_to_play_ms≈1548`; file grew 51→90 KB during play |

**Conclusion:** play-while-download works if the decoder gets enough complete frames first. Default **`tts_min_play_bytes=49152`** + short settle. 16 KiB was too small (repeat/garble).

**Notes / follow-ups:**

- CLI line tokenizer still splits on spaces — long JSON args need `\u0020` or a written Lua file.
- `thread.get` status wait after play is best-effort; playback itself completed.
- FATFS concurrent RW is unsafe; stream path uses **RAMFS**.
- True ring-buffer / GMF custom IO would allow earlier start without tearing (S2 proper).
- Sentence-level pipeline (S4) and mute-during-TTS still wait for iFlytek/wake.

### 7.7.3 Streaming backlog (record only)

| ID | Work | Depends on | When |
|---|---|---|---|
| **S1** | Host spike: `stream:true`, TTFB, voice ids | — | **Done 2026-09** |
| **S2** | Device: POST stream + play-while-download | — | **Done 2026-09 (minimal)** |
| **S3** | Optional model switch MOSS-TTSD (`…:alex`) | Product quality/cost | Later |
| **S4** | Sentence-level LLM→TTS pipeline | Stream-friendly LLM + S2 | With **E** live voice |
| **S5** | Faster LLM / tighter tools | Model/provider work | With A / later |

**Decision (unchanged):** ship B+D first (done); **do not implement S2–S5** until **iFlytek ASR + wake** so streaming, mute, and queue share one design.

**Do not** call `agent_ask` from inside the same root Agent tool path (deadlock); product path uses `reply_text` only.

---

## 8. Vertical slices (XiaoZhi-aligned)

Reference pattern: prove audio → protocol → wake → glue → full turn.  
Architecture is **not** “one cloud WS does ASR+LLM+TTS”; ESP-Claw is **IAT WSS + on-device agent + SF TTS HTTP**.

| Slice | Proves | Exit |
|---|---|---|
| **A′** | Local mic/playback | 1 s record can play back |
| **B′** | IAT WSS + HMAC + frames | Known PCM → Chinese text in log |
| **C′** | VAD + wake **小依** | Wake → WAIT_CMD |
| **D′** | Lua configure/handler | Skill receives `final` |
| **E′** | **Half-E**: mock/fixed text → agent → TTS → play | Audible reply without live ASR |
| **E** | C′+D′ wired to E′ | Full live voice turn |

**E′ can run in parallel with B′** so TTS/play issues do not block IAT bring-up.

Shine MP3 encode: **not required** for iFlytek PCM path; only if SiliconFlow ASR fallback is used.

---

## 9. Failure / recovery matrix

| Failure | Behavior |
|---|---|
| No network / IAT reject | Backoff reconnect; optional short local beep |
| Clock skew / no SNTP | Delay `start`; retry HMAC |
| 60 s session cap | Finish utterance; open new session |
| No final | Timeout → IDLE |
| Agent empty/fail | Fixed error tone or IM text; back to IDLE |
| TTS fail | One retry; then fail path; resume mic |
| TTS/playback echo | `pause()` before play; no capture during BUSY |
| FATFS full | Delete old tts/temps; cap retention |
| Secrets | Mask in UI; never log full keys |

---

## 10. Risks (summary)

| Risk | Mitigation |
|---|---|
| HMAC + 300 s skew | SNTP; retry connect |
| 60 s IAT cap | Session rollover |
| Always-on cost | Local VAD; stream only while speaking |
| Echo / self-wake | Mute during TTS; longer phrases |
| WSS vs HTTP allowlist | IAT is WSS; SF TTS is HTTPS |
| RAM | Fixed PCM chunks; C core on hot path |
| Wake false positive | Debounce + min command length |
| Secrets | Mask UI; no secret logs |

---

## 11. Acceptance (MVP = Phase 2 / slice E)

1. LLM page: ASR provider + iFlytek three secrets **or** SF key/model; **TTS key/voice**; wake **小依** (editable).  
2. Switching provider does **not** wipe the other side’s secrets.  
3. SNTP; IAT WSS connect.  
4. Idle does not spam cloud (VAD gate).  
5. Say **小依** + command → agent reply → TTS audible.  
6. Failures logged; device stays up; temps cleaned.

---

## 12. Locked implementation defaults

| Topic | Default |
|---|---|
| Architecture | **C core + Lua thin wrapper** |
| SiliconFlow URL | Base includes `/v1`; code appends `/audio/transcriptions` or `/audio/speech` |
| iFlytek URL | Full WSS URL in config; no path suffix |
| Wake match | **Final** text only (MVP) |
| `dhw` | Optional; **not** required for MVP (CSV list only) |
| Prototype vehicle | Lua+WS only for bring-up; product loop = C core |
| SF ASR | Optional debug path behind provider select |
| E′ | Allowed early; does not replace live E |

---

## 13. Remaining open items (not blocking Phase 0)

1. WAIT_CMD: accept remainder **in the same final** as wake, or strictly two utterances (doc says both OK; pick one in Phase 2).  
2. `res_id` console hotword vs `dhw` only.  
3. Exact VAD threshold / hangover constants (tune on hardware).  
4. Whether IM/`(b)` file mode remains first-class after E is done.

---

## 14. Out of scope

- 讯飞离线「语音唤醒」SDK  
- Full-duplex AEC / barge-in  
- Speaker diarization / long voice-only memory

---

## 15. Delivery plan (full product)

1. **Phase 0** — config + LLM-page Voice/ASR + SNTP (no live pipeline).  
2. **E′** — mock text → agent → SF TTS → play.  
3. **A′ + B′** — PCM + IAT client.  
4. **C′ + D′** — wake **小依** + Lua events.  
5. **E** — live voice turn.  
6. **Phase 3** — reconnect, 60 s rollover, optional `dhw`/`res_id`.

E′ checklist and device test sheet: [`voice-e-prime-dev-test.md`](voice-e-prime-dev-test.md).

---

## 16. Next step

Implement **Phase 0** only until on-device config round-trip is verified; then Phase 1 / E′ per §15.

