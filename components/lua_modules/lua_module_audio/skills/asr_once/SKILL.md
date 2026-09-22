---
{
  "name": "asr_once",
  "description": "A'+B' smoke: record a short mic clip then run iFlytek IAT and print final text. No wake/VAD. Uses voice_config_get for ASR secrets.",
  "metadata": {
    "cap_groups": [
      "cap_lua",
      "cap_voice_config"
    ],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/asr_once.lua"
  }
}
---

# ASR Once（麦 → 讯飞）

1. 录固定时长 WAV（默认 4s，16k/16bit/mono）到 `/ramfs/asr_in.wav`  
2. 调 IAT 文件听写，打印 `FINAL:` 文字  

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `duration_ms` | 录音时长 | `4000` |
| `path` | 输出 WAV | `/ramfs/asr_in.wav` |
| `timeout_ms` | IAT 超时 | `30000` |

ASR 密钥从网页 Voice/ASR 读取。

## 验收

对麦说话 → 串口 `FINAL:` 出现对应中文。  
