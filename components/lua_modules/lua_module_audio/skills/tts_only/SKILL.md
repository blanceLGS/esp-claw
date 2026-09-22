---
{
  "name": "tts_only",
  "description": "E' smoke: send fixed text to SiliconFlow TTS and play the MP3 on the board speaker. Use for voice pipeline bring-up before ASR/wake. Does not use the microphone or iFlytek.",
  "metadata": {
    "cap_groups": [
      "cap_lua",
      "cap_http_request",
      "cap_voice_config"
    ],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/tts_only.lua"
  }
}
---

# TTS Only（E′ 冒烟）

把一句固定文本用 **SiliconFlow TTS** 合成 MP3，并在板子喇叭上播放。  
**不含** 麦克风、讯飞 ASR、唤醒词。

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `text` | 要合成的文本 | `你好，我是小依` |
| `tts_api_key` | SiliconFlow Bearer Key | 读设备 NVS（网页 Voice/ASR） |
| `tts_base_url` | API 根，含 `/v1` | 设备配置 / `https://api.siliconflow.cn/v1` |
| `tts_model` | 模型名 | 设备配置 / `FunAudioLLM/CosyVoice2-0.5B` |
| `tts_voice` | 音色 | 设备配置 / `FunAudioLLM/CosyVoice2-0.5B:alex` |
| `tts_volume` | 本机播放音量 0–100 | 设备配置 / `80` |
| `timeout_ms` | HTTP 超时 | `30000` |

TTS 参数会先调用 `voice_config_get` 读 NVS/内存中的网页配置；参数仅作覆盖。  
串口 CLI 可用 `voice` / `voice key` 查看。

## 行为

1. `POST {tts_base_url}/audio/speech`（不要再拼一层 `/v1`）  
2. 响应二进制存到 `{storage root}/voice/tts.mp3`  
3. `audio.player` 阻塞播放  
4. 结束后关闭 player/output  

## 失败

- 缺 `tts_api_key` → 直接报错  
- HTTP 非成功 → 报错并打印响应片段  
- 播放失败 → 报错  

## 验收（E′ T1–T3）

- 能听到人声  
- 换 `text` 后内容变化  
- 不重启设备  
