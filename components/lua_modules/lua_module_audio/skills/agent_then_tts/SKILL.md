---
{
  "name": "agent_then_tts",
  "description": "Speak an existing agent reply via SiliconFlow TTS. Pass reply_text (the text already answered). Does not call agent_ask. Prefer lua_run_script_async from agent tools. No mic/ASR/wake.",
  "metadata": {
    "cap_groups": [
      "cap_lua",
      "cap_http_request",
      "cap_voice_config"
    ],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/agent_then_tts.lua"
  }
}
---

# Agent Then TTS（播已有回复）

把 **已经生成的 Agent 回复** 截短后 SiliconFlow TTS 合成并播放。

**不要**在本 skill 里 `agent_ask`：root agent 单线程，工具回调里再提交同一 root 会超时。  
产品路径：Agent 工具传入本条 `reply_text`，用 **`lua_run_script_async`** 后台播放。

**不含** 麦克风、讯飞、唤醒词。TTS 参数自动读 NVS（网页 Voice/ASR），参数可覆盖。

## 参数

| 参数 | 说明 | 默认 |
|---|---|---|
| `reply_text` | 要念的 Agent 回复（必填；兼容别名 `text`） | 必填 |
| `tts_api_key` | SiliconFlow Key | 读设备 NVS |
| `tts_base_url` | 含 `/v1` | 设备配置 / `https://api.siliconflow.cn/v1` |
| `tts_model` | 模型 | 设备配置 / `FunAudioLLM/CosyVoice2-0.5B` |
| `tts_voice` | 音色 | 设备配置 / `FunAudioLLM/CosyVoice2-0.5B:alex` |
| `tts_volume` | 音量 0–100 | 设备配置 / `80` |
| `tts_http_timeout_ms` | TTS HTTP | `30000` |
| `tts_max_sentences` | 念前几句 | `6` |
| `tts_max_chars` | 字数上限（整句截断，不切半句） | `400` |
| `tts_stream` | 边下边播（`stream:true` + 达阈值开播） | `true` |
| `tts_min_play_bytes` | 开播前最少字节 | `49152` |

## 行为

1. 读 `reply_text`（无则报错）  
2. §7.6 分句截短  
3. **流式（默认）**：后台 `POST`（body `stream:true`，`save_direct`）写 `/ramfs/tts_live.mp3`；文件 ≥ `tts_min_play_bytes` 即开播，下载并行  
4. **非流式**（`tts_stream=false`）：整包下到 `{DATA}/voice/tts.mp3` 再播  
5. `audio.player` 阻塞播放  

## 验收

- 传入非空 `reply_text` 能听到人声  
- 长文本只念前几句  
- 缺 `reply_text` / TTS 失败有错误、不重启  
- 从 Agent 工具 **async** 触发时，外层对话不被卡死  
- 流式：日志有 `ttfb_to_play_ms`，长文应明显小于整包下载时间  
