---
{
  "name": "wake_listen",
  "description": "C' wake word + VAD listener. Local audio.analyzer energy gate, iFlytek IAT v2 ASR, wake word match (default 小依 from voice_wake_words CSV + aliases), command mode, then agent_ask + agent_then_tts. CLI only — do NOT activate from root agent tool callback (agent_ask re-entrancy deadlock).",
  "metadata": {
    "cap_groups": [
      "cap_lua",
      "cap_voice_config",
      "cap_http_request",
      "cap_agent_mgr"
    ],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/wake_listen.lua"
  }
}
---

# Wake Listen（唤醒词「小依」+ VAD）

C′ 切片：本地能量 VAD + 讯飞 IAT v2 + 唤醒词匹配 + 命令模式。

**不要**从 root agent 工具回调里 `activate_skill wake_listen`：内部会调 `agent_ask`，会重入死锁。  
产品/调试路径用串口 CLI：`lua --run`。

## 流程

```
audio.analyzer 本地能量轮询 (vad_check_ms)
  → peak/rms >= vad_threshold 判定为人声
  → 关闭 analyzer，录 wake_record_ms
  → peak < vad_threshold 则跳过云端 (VAD_SKIP)
  → 否则送 iFlytek IAT v2
  → 匹配唤醒词 (voice_wake_words CSV，默认 小依 + 常见误识别别名)
  → 无唤醒词：仅高精度本地动词（音量/静音/开关语音），不进 Agent
  → 同一句含命令 → agent_ask → agent_then_tts
  → 只有唤醒词 → 命令模式，录 cmd_record_ms
  → 回到 VAD 监听
```

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `vad_threshold` | 本地能量峰值阈值 | `2000` |
| `local_hold_ms` | 能量需持续多久才算人声 | `350` |
| `iat_min_peak` | 录音 peak 低于此不连云端 | `2500` |
| `vad_check_ms` | VAD 轮询间隔 | `80` |
| `vad_wait_ms` | 单次 VAD 等待上限（0=30s 轮询后重试） | `0` |
| `wake_record_ms` | 唤醒词识别录音时长 | `4500` |
| `cmd_record_ms` | 命令录音时长 | `6000` |
| `volume` | 麦克风音量 0–100 | `100` |
| `use_local_vad` | 是否启用 analyzer 本地 VAD | `true` |
| `wake_only` | 只测唤醒，不调 agent/TTS | `false` |
| `exit_on_wake` | 检测到唤醒词后退出（便于脚本验收） | `false` |
| `max_iterations` | 最大循环次数（0=无限） | `0` |
| `agent_timeout_ms` | agent_ask 等待 | `90000` |
| `tts_volume` | 播报音量 | 读 NVS / `80` |

## 唤醒词

从网页 Voice/ASR 配置读取 `voice_wake_words`（CSV，默认 `小依`）。

匹配时自动扩展常见误识别：`小一/小衣/小医/晓依/小伊/...`。

支持：
- 「小依今天天气怎么样」→ 唤醒 + 命令同一句
- 「小依」→ 唤醒后进入命令模式，等下一句
- 「小依，今天天气怎么样」→ 自动去掉唤醒词和标点

## 电平参考（RLCD + ES7210 PGA 37.5dB）

| 场景 | 典型 peak |
|---|---|
| 安静底噪 | 800–1000 |
| 环境闲聊/电视 | 1200–1800 |
| 正常人声（靠近麦） | 2000+ |
| `vad_threshold` 默认 | **2000**（压掉闲聊，保留近讲人声） |

若环境噪，调高 `vad_threshold`；若说话识别不到，调低或靠近麦克风。

## 日志完整性（重要）

`lua --run` 的 `print` 会写入 **4KiB 捕获缓冲**，命令结束时 CLI 只回放尾部（甚至只打 `[output truncated]`）。  
串口若中途断开/缓冲被冲掉，也会看起来「日志不全」。

本 skill 额外写入设备文件：

```
/ramfs/wake_listen.log
```

测完后查看完整日志：

```
lua --run --path /system/skills/wake_listen/scripts/wake_dump_log.lua
```

结束时脚本也会自动打印 log tail。

**注意：** 不带参数直接跑 `wake_listen.lua` 时，为避免无限循环被 `--timeout-ms` 强杀导致看不到 `done`，默认自动 `max_iterations=20`。真正常开请传 args 设 `max_iterations=0`。

## 验收

```bash
# 1) 只测唤醒词（推荐）
lua --run --path /system/skills/wake_listen/scripts/wake_smoke.lua --timeout-ms 120000
# 测完看完整日志
lua --run --path /system/skills/wake_listen/scripts/wake_dump_log.lua

# 2) 完整闭环（有限次，默认自动限 20 轮）
lua --run --path /system/skills/wake_listen/scripts/wake_listen.lua --timeout-ms 300000
lua --run --path /system/skills/wake_listen/scripts/wake_dump_log.lua
```

期望日志：
1. `ASR-peak poll` / `SPEAK_NOW`
2. `clip done: peak=... text="...小依..."`（peak 应 >2800）
3. `WAKE WORD DETECTED: 小依`
4.（完整模式）`COMMAND:` → `agent_ask` → `REPLY:` → TTS
5. `done woke_count=...` + log tail
