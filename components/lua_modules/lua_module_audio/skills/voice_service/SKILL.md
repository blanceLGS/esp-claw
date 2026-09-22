---
{
  "name": "voice_service",
  "description": "Phase-1 resident voice: product defaults for wake_listen (service mode) plus voice_keepalive that restarts async job voice_wake if missing. Keepalive is short-lived; call from router startup/schedule events, not from root agent tools.",
  "metadata": {
    "cap_groups": [
      "cap_lua",
      "cap_voice_config"
    ],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/voice_keepalive.lua"
  }
}
---

# Voice Service（阶段 1 常驻 / 阶段 2 产品开关）

## 组件

| 脚本 | 作用 |
|------|------|
| `voice_keepalive.lua` | 查 `voice_wake` 是否 running；启用则拉起，禁用则停止 |
| `voice_service.lua` | 产品参数下直接跑 `wake_listen`（`service=true`） |
| `wake_listen` `service=true` | **不**自动 `max_iterations=20`，常驻循环 |

## 任务参数（keepalive 拉起时）

- `timeout_ms=0`（直到取消）
- `name=voice_wake`
- `exclusive=voice`
- `service=true`, `max_iterations=0`

单次 ASR/Agent/TTS 仍有各自超时，失败回到 listening，不结束整个服务。

## DATA 控制文件（阶段 2）

| 文件（DATA 根） | 含义 |
|-----------------|------|
| `voice_enable` | `0/false/off/no` → 不启动；若任务在跑则 **停止** |
| `voice_tts_volume` | `0–100`，keepalive 启动 wake_listen 时传入 `tts_volume` |
| `voice_wake.cmd` | `restart` / `stop` / `start`；keepalive 读后删除并执行 |
| `voice_weather_city` | 城市名（北京/上海/广州…）或 `纬度,经度`；默认北京 |

网页保存语音配置时，固件会写入上述文件；keepalive（≤60s）或语音指令会处理。

## 语音口令（本地，不进 Agent）

- 「大声点 / 小声点 / 音量调到80 / 静音」→ 改音量并写入 `voice_tts_volume`
- 「几点 / 今天几号」→ 本地 `get_current_time`
- 「关闭语音 / 打开语音」→ 写 `voice_enable` 并 stop/keepalive
- 「今天天气 / 上海天气」→ **Open-Meteo** 本地化短句（默认北京，或命令里带城市）
- 「新闻…」→ 直接 `web_search` 后短句 TTS（失败再回落 agent）

## 设备侧启用（已有 DATA 配置时需手动）

```
scheduler --add --json "{\"id\":\"voice_keepalive\",\"enabled\":true,\"kind\":\"interval\",\"interval_ms\":60000,\"event_type\":\"schedule\",\"event_key\":\"voice_keepalive\",\"text\":\"voice_keepalive\"}"
```

Router 规则见 `.agents/voice-progress.md`。

## 禁用

```
scheduler --pause --id voice_keepalive
```

并把 router 规则 `voice_service_startup` / `voice_keepalive_check` 的 `enabled` 设为 `false`。

或写 DATA `voice_enable=0` / 网页关闭「常驻语音监听」/ NVS `voice_enable=false`。

## 禁止

- 从 root agent 工具回调 `activate_skill voice_service` / `wake_listen`（`agent_ask` 重入死锁）
- 同时用串口 `lua --run wake_listen` 与 keepalive 拉起的常驻任务抢麦（调试前先 stop job）

## 手动启动一次

```
lua --run --path /system/skills/voice_service/scripts/voice_keepalive.lua --timeout-ms 20000
```

## 热重启 / 立刻生效

```
# 串口或脚本写 DATA 根文件
# voice_wake.cmd 内容为 restart
```

或对麦说「关闭语音」「打开语音」。
