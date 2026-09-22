---
{
  "name": "asr_iat",
  "description": "iFlytek Spark IAT: stream a 16kHz mono WAV/PCM file over WSS and return final Chinese text. No mic capture in this skill.",
  "metadata": {
    "cap_groups": [
      "cap_lua",
      "cap_voice_config"
    ],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/asr_iat_file.lua"
  }
}
---

# iFlytek IAT（文件听写）

把设备上的 **16 kHz / 16-bit / mono** WAV（或 raw PCM）通过 **WSS** 送给讯飞 IAT，打印 `final` 文字。

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `path` | WAV/PCM 路径 | 必填 |
| `asr_app_id` | 讯飞 APPID | 读 NVS |
| `asr_api_key` | APIKey | 读 NVS |
| `asr_api_secret` | APISecret | 读 NVS |
| `asr_endpoint` | 完整 WSS URL | NVS / `wss://iat.xf-yun.com/v1` |
| `frame_ms` | 每帧音频时长 | `40` |
| `timeout_ms` | 整段超时 | `30000` |

## 行为

1. 读配置（`voice_config_get`）  
2. HMAC-SHA256 生成鉴权 query  
3. `websocket.connect` → 首帧/续帧/结束帧  
4. 收 `payload.result.text`，base64 解码拼 `final`  

## 验收

- 已知中文 WAV → 串口出现对应文字  
- 缺密钥 / 时钟偏移 / 断网 → 明确错误，不重启  
