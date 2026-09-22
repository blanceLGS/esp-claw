---
{
  "name": "voice_turn",
  "description": "Manual voice turn (no wake): record mic -> iFlytek IAT -> agent_ask -> SiliconFlow TTS play. Trigger from CLI/local lua, not from inside the root agent tool callback.",
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
    "entry": "scripts/voice_turn.lua"
  }
}
---

# Voice Turn（手动一问一答）

串行链路：录音 → 讯飞 IAT → `agent_ask` → `agent_then_tts` 播报。

**不要**从 root agent 工具回调里 `activate_skill voice_turn`：内部会再调 `agent_ask`，会重入死锁。  
产品路径用 CLI / 本地 `lua --run`，或后续 C′ 唤醒后再接。

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `duration_ms` | 录音时长 | `6000` |
| `volume` | 麦克风音量 0–100 | `100` |
| `timeout_ms` | IAT 总超时 | `60000` |
| `agent_timeout_ms` | agent_ask 等待 | `90000` |
| `tts_volume` | 播报音量 | 读 NVS / `80` |

## 验收

对麦说话 → 串口出现 `FINAL:` → Agent 回复 → 扬声器有声。
