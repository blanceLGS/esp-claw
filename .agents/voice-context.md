# ESP-Claw 语音交互 — 上下文记忆

> 用途：会话上下文快照，供新会话快速恢复状态。
> 更新日期：2026-09-13

---

## 项目目标

**小依 AI 桌面**（基于 Waveshare ESP32-S3-RLCD-4.2）：
常开麦克风 → 唤醒词「小依」→ 讯飞 IAT ASR → Agent → SiliconFlow TTS → 喇叭。
架构：**C 核心 + Lua 薄封装**（C 管 WSS/HMAC/帧/VAD，Lua 管 agent/TTS/播放编排）。

---

## 板卡硬件（双麦）

| 通道 | 芯片 | 角色 |
|------|------|------|
| `audio_adc` | ES7210（I2C 0x40，mask `0011`） | MIC1 = L（主拾音），MIC2 = R（参考降噪） |
| `audio_dac` | ES8311（I2C 0x18） | 喇叭播放 |

- ES7210 驱动在 init 时硬编码 PGA 30 dB（`adc_init_gain: 0` 不再叠加）。
- 双麦近距同向：稳态环境噪声 MIC1/MIC2 同时收到，`L − 0.5·R` 可消噪。

---

## 讯飞 IAT 接口

| 项 | 值 |
|----|----|
| 端点（中英，当前使用） | `wss://iat.xf-yun.com/v1` |
| 端点（多语种，已澄清不用） | `wss://iat.cn-huabei-1.xf-yun.com/v1` |
| 鉴权 | HMAC-SHA256 + RFC1123 GMT date（±300 s，需 SNTP） |
| 音频 | 16 kHz / 16-bit / mono / PCM（`raw`） |
| 帧节奏 | 40 ms / 1280 B；首帧 status=0 带全 parameter，末帧 status=2 audio 空 |
| 时长上限 | 60 s/会话 |
| 结果 | base64 → JSON → `ws[].cw[].w`；`ls=true` 为 FINAL |

**用户澄清（2026-09-13）**：ASR 保持中英接口（`zh_cn` + `iat.xf-yun.com/v1`），**不改多语种**。

---

## 双麦处理（asr_iat_file.lua）

```
L（MIC1）  R（MIC2）
  ↓          ↓
speech = L − RATIO × R   （RATIO = 0.5，未标定，可试 0.3/0.7/1.0）
```

- 每 1024 帧 `delay_ms(1)` yield，防止 task_wdt 饿死 IDLE0。
- 旧版「取更响通道」的 `stereo_pick_mono` 仍保留作快速诊断。

---

## 自动增益（record_once）

```
录 6 s → 算 mono peak
if peak < 3000 and volume < 100:
    volume += 20，重录一次
```

- 默认 `volume=100`（30 dB PGA），PGA 正常时不触发。
- PGA 漂移（peak < 3000）时自动升档；若已到 100 仍低，需固件层复位 ES7210 0x21/0x22。

---

## 调用路径

```
asr_once.lua   → 流式录 6 s → IAT → 打印 FINAL（最常用）
asr_iat_file.lua（path=...）→ 文件模式，IAT 识别本地 WAV
voice_turn.lua → ASR → agent_ask → agent_then_tts（完整手动闭环，CLI 调试用）
```

产品路径（非 CLI）：IM → Agent → `out_message` → router `run_script` async →
`agent_then_tts(reply_text)`；**skill 内禁止 `agent_ask`**（deadlock）。

---

## 关键文件

| 路径 | 说明 |
|------|------|
| `components/lua_modules/lua_module_audio/skills/asr_iat/scripts/asr_iat_file.lua` | IAT 客户端核心（544 行） |
| `components/lua_modules/lua_module_audio/skills/asr_once/scripts/asr_once.lua` | 流式入口（28 行） |
| `components/lua_modules/lua_module_audio/skills/voice_turn/scripts/voice_turn.lua` | 完整闭环（74 行） |
| `application/edge_agent/boards/waveshare/waveshare_ESP32_S3_RLCD_4_2/board_devices.yaml` | 双麦 mask 定义 |
| `.agents/voice-interaction.md` | 完整开发计划（594 行） |
| `.agents/voice-progress.md` | 进度快照（本次新建） |
| `.agents/voice-issues.md` | 问题跟踪（本次新建） |

---

## 编译烧录

```powershell
# 激活 ESP-IDF（同进程）
. "C:\Espressif\tools\Microsoft.v5.5.4.PowerShell_profile.ps1"
Set-Location "D:\A-Studen\GITHUB\esp-claw\application\edge_agent"
idf.py bmgr -c ./boards -b waveshare_ESP32_S3_RLCD_4_2
idf.py build

# 烧录（COM3 需先关 esp-term）
Set-Location build
esptool.py --chip esp32s3 -p COM3 -b 460800 --before default_reset --after hard_reset `
  write_flash --flash_mode dio --flash_size 16MB --flash_freq 80m "@flash_args"
```

串口抓日志：`tools/serial_log.py -p COM3 -t 30`（需 ESP-IDF venv 的 pyserial）。

---

## 已知待做（不阻塞当前 A′+B′ 验证）

1. `RATIO` 标定（实测 0.3/0.5/0.7/1.0）
2. C′ 唤醒词「小依」+ VAD（当前是固定 6 s 窗口，非常开）
3. E 完整闭环（真语音）：`voice_turn.lua` 路径，需外部 `reply_text`
4. 固件层 ES7210 PGA 寄存器复位（`setup_device.c`，volume=100 时 peak 仍低才需要）
5. 多语种接口（已澄清不用，若将来要改用 `mul_cn` + `iat.cn-huabei-1.xf-yun.com/v1`）
