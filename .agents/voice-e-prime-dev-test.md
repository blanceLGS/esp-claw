# 语音 E′ — 开发步骤与设备测试文档

**范围：** 固定/假文本 → Agent → SiliconFlow TTS → 播放  
**不在本阶段做：** 麦克风、讯飞 IAT、VAD、唤醒词「小依」

Phase 0（网页配置）已完成。E′ 用于验证这些配置端到端是否可用。

**产品路径已接（P2-B）：** IM → Agent → `out_message` → async `agent_then_tts(reply_text)`。  
**已知延迟：** 进线到出声约 20s+，主因云端 LLM；下一步只做 **B+D**（限制简单对话乱 activate、改进工作回复文案），A/C/E 与讯飞/唤醒一起做。详见 [`voice-interaction.md`](voice-interaction.md) §7.7。

相关：[`voice-interaction.md`](voice-interaction.md)

---

## 一、开发步骤（实现时逐项勾选）

### E′.1 Skill / 脚本骨架

- [ ] 新建 skill 或 Lua 脚本（例如 `voice_eprime`）
- [ ] 触发方式：CLI / Lua 运行 / Web IM 技能（建议先 **Lua 运行 + 简短 README**）
- [ ] 输入：一条固定文本，例如 `现在几点` 或 `用一句话介绍自己`
- [ ] 每个阶段打印开始/结束日志（含路径或请求 id）

### E′.2 调用 Agent

- [ ] 用现有路径提交固定文本（`claw_core` / 现有 capability）
- [ ] 拿到 **回复文本**
- [ ] 空回复 / 失败：打日志并正常退出，禁止崩溃
- [ ] 限制送入 TTS 的回复长度（建议 200～500 字），避免 MP3 过大  
- [ ] **长回复策略见** [`voice-interaction.md`](voice-interaction.md) **§7.6**：优先分句 + 前 N 句 + 字数兜底；`tts_only` 仅字符截断，`agent_then_tts` 用分句 + `reply_text`（不调 `agent_ask`）

### E′.3 读取 TTS 配置

**现状：** skill 通过 `voice_config_get` 自动读 NVS/内存配置；参数仅覆盖。  
串口 CLI：`voice`（掩码）/ `voice key`（完整 key）。

- [x] 从 app_config / NVS 自动读取：
  - `tts_api_key`
  - `tts_base_url`
  - `tts_model`
  - `tts_voice`
- [ ] 缺少 Key → 明确错误（已提示去网页 Voice/ASR 配置）
- [ ] 拼 URL：`{tts_base_url}/audio/speech`  
  - Base 已含 `/v1` 时 **不要再插一个 `/v1`**
  - 若用户填成不带 `/v1` 的地址，优先 **直接报错**（或按实现约定拼接，需在代码里写清）

### E′.4 SiliconFlow TTS 请求

- [ ] `POST` JSON：

```json
{
  "model": "<tts_model>",
  "input": "<回复文本>",
  "voice": "<tts_voice>",
  "response_format": "mp3"
}
```

- [ ] Header：`Authorization: Bearer <tts_api_key>`
- [ ] 保存到 DATA 路径，例如 `{root}/voice/tts.mp3`（目录不存在则创建）
- [ ] 优先复用已有 `http_request` + `save_path`，不要新写 HTTP 客户端
- [ ] 超时建议 ≥ 15～30 秒
- [ ] HTTP 失败：打状态码与响应片段，**不播放**

### E′.5 播放

- [ ] 用 board_manager / audio 打开输出设备
- [ ] `player:play(mp3_path, { wait = true })`（或等价阻塞播放）
- [ ] 播完：`player` / 输出设备按现有规范关闭
- [ ] 删除临时 MP3（或固定文件名每次覆盖，避免 FATFS 越堆越多）

### E′.6 配置前置检查

- [ ] 设备 SNTP 正常（TTS 不强依赖，但保持时钟正常）
- [ ] 若走 `http_request` 且开了 allowlist：`search_http_allowlist` 含 `api.siliconflow.cn`
- [ ] LLM 已配置（Agent 依赖）  
- [ ] 可选：**仅 TTS 模式**（跳过 Agent，用固定文案），方便单独测喇叭

**建议两种模式：**

| 模式 | 文本来源 | 用途 |
|---|---|---|
| `tts_only` | 固定文案 | 只测 TTS + 播放 |
| `agent_then_tts` | 已有 `reply_text`（不在 skill 内 `agent_ask`） | 播 Agent 已说的话 |

Agent 不稳定时，先做 `tts_only`。

### E′.7 文档

- [ ] README/SKILL：如何运行、需要哪些配置、预期日志
- [ ] 注明：本阶段 **无** 唤醒词 / IAT

---

## 二、实现提醒（尽量少写代码）

- 复用：`cap_http_request`、`lua_module_audio`、现有 Agent 调用
- E′ **不需要** 新建 C capability；一个 skill + 一段 Lua 即可
- 临时文件：固定文件名覆盖即可

---

## 三、设备测试文档（人工）

**板卡：** RLCD 4.2（烧录后常见 COM3）  
**固件：** 含 Phase 0 配置 + E′  
**测试人：** ________  日期：________

### 3.1 测试前置

| 编号 | 步骤 | 期望 | 通过 |
|---|---|---|---|
| P1 | 上电等待启动完成 | 串口日志稳定，无循环重启 | ☐ |
| P2 | 打开网页 → LLM 页 | 能看到「语音 / ASR」区域 | ☐ |
| P3 | ASR 方案 | 任意（E′ 不用 ASR） | ☐ |
| P4 | TTS API Key | 已填 SiliconFlow Key | ☐ |
| P5 | TTS Base URL | `https://api.siliconflow.cn/v1` | ☐ |
| P6 | TTS 模型 | 如 `FunAudioLLM/CosyVoice2-0.5B` | ☐ |
| P7 | TTS 音色 | 如 `FunAudioLLM/CosyVoice2-0.5B:alex` | ☐ |
| P8 | LLM 已配置 | Base URL / Key / 模型有效 | ☐ |
| P9 | HTTP 允许列表 | 含 `api.siliconflow.cn`（若启用 allowlist） | ☐ |
| P10 | 点「保存本页」 | 不再出现 Failed to save config | ☐ |
| P11 | 重启设备 | 重启后上述字段仍在 | ☐ |

### 3.2 仅 TTS 冒烟（若已实现）

| 编号 | 步骤 | 期望 | 通过 |
|---|---|---|---|
| T1 | 运行 E′，固定文案如 `你好，我是小依` | 日志 HTTP 成功，文件大小 > 0 | ☐ |
| T2 | 等待播放 | **喇叭能听到人声** | ☐ |
| T3 | 换一句文案再跑一次 | 能播第二段，内容有变化 | ☐ |
| T4 | 查临时文件 | 已删除或固定文件被覆盖，无堆积 | ☐ |
| T5 | 断电重启后再跑 | 不需重新烧录即可再播 | ☐ |

### 3.3 Agent → TTS 整轮

产品路径（P2-B）：IM → Agent → `out_message` → router `run_script` async → `agent_then_tts`。  
skill **只播成功回复**（`status=ok`）；`exclusive=tts` **排队**（等前一个播完，最长 60s）。  
**禁止** skill 内 `agent_ask`。

| 编号 | 步骤 | 期望 | 通过 |
|---|---|---|---|
| A1 | IM 发一句正常问题 | 先收到文字回复，随后喇叭播报 | ☐ |
| A2 | 听播报 | 内容与回复一致（截断范围内） | ☐ |
| A3 | 连续快速发 2～3 句 | **串行**播完，不叠音、不崩 | ☐ |
| A4 | Agent 失败/空回复 | 有 IM/日志；**不 TTS**；不重启 | ☐ |
| A5 | CLI `ask`（无 out_message） | 不误触发播报 | ☐ |
| A6 | 观察延迟（已知） | 进线→出声约 20s+，主因 LLM；见 §7.7 | ☐ 记录 |

**本阶段不做（记入 backlog）：** B 简单对话限制 `activate_skill`；D 工作回复文案；A/C/E 与讯飞/唤醒一起做。

### 3.4 异常与失败场景

| 编号 | 步骤 | 期望 | 通过 |
|---|---|---|---|
| N1 | 清空 TTS API Key 后保存并运行 | 提示未配置；不崩溃 | ☐ |
| N2 | TTS Key 填错 | 记录 HTTP 失败；不重启 | ☐ |
| N3 | 断开 Wi-Fi | 超时/失败可预期；恢复网络后可再试 | ☐ |
| N4 | TTS Base URL 缺 `/v1` | 按实现报错或可预期行为；不卡死 | ☐ |
| N5 | allowlist 未放行 SiliconFlow | 若走 allowlist 则有明确错误 | ☐ |

### 3.5 E′ 验收标准

- [ ] P1–P11 通过  
- [ ] TTS-only 或 agent_then_tts **至少成功播两次真实语音**  
- [ ] N1–N3 设备不崩溃  
- [ ] 多次运行后 FATFS 不持续膨胀  
- [ ] 串口日志顺序清晰：（Agent？）→ TTS HTTP → 播放  

**结果：** ☐ 通过   ☐ 失败  

**备注 / 关键串口日志：**

```
（粘贴日志）

```

---

## 四、E′ 之后（本阶段不实现）

顺序：**A′+B′**（麦克风 + 讯飞 IAT）→ **C′+D′**（唤醒「小依」+ Lua 事件）→ **E**（真语音整轮）。

---

## 五、签字

| 角色 | 姓名 | 日期 |
|---|---|---|
| 开发 | | |
| 测试 | | |
