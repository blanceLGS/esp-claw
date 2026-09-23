# ESP-Claw 语音交互 — 问题跟踪

> 更新日期：2026-09-19
> 状态标记：✅ 已修复 · 🔄 进行中 · ⏳ 待验证 · 📋 已知待做

---

## 0. IAT 协议版本错误导致 10106（T36，已修）

### 现象

WSS 连接成功，首帧 ACK code=0，但后续帧返回 `code:10106 "wrapper output data invalid(key or type)"`。

### 根因

旧代码用 Spark LLM 的 `header/parameter/payload` 格式 + `wss://iat.xf-yun.com/v1`，
但讯飞语音听写（voicedictation）的官方 WebAPI 是 **IAT v2**：
- 端点：`wss://iat-api.xfyun.cn/v2/iat`
- JSON：`common/business/data` 格式
- 响应：`data.result.ws[].cw[].w`（明文 JSON，非 base64）

### 已修

- ✅ `send_frame()` 改为 IAT v2 格式
- ✅ `extract_finals()` 改为解析 `data.result.ws[].cw[].w`
- ✅ `DEFAULT_ENDPOINT` 改为 `wss://iat-api.xfyun.cn/v2/iat`
- ✅ 实测：`sent_frames=75`，无 10106，`FINAL: 嗯，他说一下。`

---

## 0b. IAT v2 文本累积 bug（T36，已修）

### 现象

IAT v2 按 `sn` 分段返回结果，旧代码每次覆盖前一段，最终只保留最后一段。

### 已修

- ✅ `drain_iat()` 增加 `state.accum` 累积字段，拼接所有分段

---

## 0c. domain / endpoint 路由（10404，T36，已修）

### 现象

旧端点 `wss://iat.xf-yun.com/v1` + `domain=iat` → 10404 "no category route found"。

### 根因

旧端点是 Spark LLM 路由；语音听写官方 WebAPI 是 **IAT v2**：
`wss://iat-api.xfyun.cn/v2/iat` + `domain=iat`（日常用语/听写）。

### 已修

- ✅ 端点改为 `wss://iat-api.xfyun.cn/v2/iat`
- ✅ `send_frame()` 使用 `domain=iat` + IAT v2 `common/business/data` 格式
- ✅ 实测识别成功（`FINAL: 嗯，他说一下。` 等）

---

## 0d. 设备时钟漂移（HMAC 403 根因，T36，已修）

### 现象

WSS 握手返回 403，`Sec-WebSocket-Accept not found`。

### 根因

设备时钟漂移 669 秒，超过讯飞 ±300s HMAC 窗口。

### 已修

- ✅ `cap_system.c` 的 `get_current_time` 新增 `force=true` 参数
- ✅ `asr_iat_file.lua` 签名前强制 SNTP 同步
- ✅ 新增 `skip_time_sync` 参数，wake_listen 循环中只同步一次

---

## 0e. 唤醒词 + VAD（C′，T44，🔄 进行中）

### 现象

ASR 链路已通，但唤醒词「小依」尚未在设备上闭环验证；麦克风 peak 随音量/距离波动（约 800 底噪 ~ 2000+ 人声）。

### 已做（T44）

- ✅ `asr_iat_file.lua`：`min_peak` 本地能量门控（低于阈值不连云端 IAT）
- ✅ `asr_iat_file.lua`：`pre_roll_ms` / `speak_prompt`；末帧结果累积修复；去掉重复 SNTP
- ✅ `wake_listen.lua`：`audio.analyzer` 本地 VAD 轮询 + IAT 唤醒词匹配
- ✅ 唤醒词别名（小一/小衣/晓依…）；`wake_only` / `exit_on_wake` 测试模式
- ✅ 默认 `vad_threshold=1400`（底噪 800–1000 与人声 2000+ 之间）

### 下一步

- [ ] 编译烧录后跑 `wake_only` 验收：靠近麦大声说「小依」
- [ ] 确认串口出现 `VAD hit` + `WAKE WORD DETECTED`
- [ ] 再跑完整闭环（agent + TTS）
- [ ] 若 VAD 误触发/漏触发，微调 `vad_threshold`

---

## 1. 讯飞 IAT 识别失败（T36，历史）

### 1.1 电平漂移导致空 FINAL

**现象**：同一块板，08:29 成功识别（peak≈1500–1700），14:50 后全部空（peak≈500–899）。

**已修**：
- ✅ 自动增益：`peak < 3000` 且 `volume < 100` 时自动升 20 档重录
- ✅ 数字化妆增益：`peak < 26000` 时按比例放大 PCM
- ✅ 新增 `MIN_USEFUL_PEAK=200` 阈值，低于此值跳过化妆

### 1.2 WDT 复位（IDLE0 饿死）

**已修**：✅ yield 间隔从 4096 收到 1024 帧。

### 1.3 讯飞 10106 错误

**已修**：✅ 同 1.2 的 WDT 修复 + IAT v2 协议修复。

---

## 2. ASR 接口配置

### 2.1 多语种 vs 中英接口

**澄清（用户 2026-09-13）**：ASR 保持中英接口（`zh_cn`），不改多语种。

**状态**：✅ 澄清完毕，无需改动。

### 2.2 LLM 页 ASR 配置字段

**状态**：✅ 已完成（T17–T18）。

---

## 3. 双麦语义

**设计意图**：MIC1 = 主拾音，MIC2 = 参考降噪。

**当前实现**：直接取 L 声道（近距同向双麦，平均无增益）。

**待做（📋）**：实测不同 `RATIO` 对 SNR 的影响。

---

## 4. voice_turn 嵌套调用限制

**状态**：✅ 已知限制，有绕行方案（`reply_text` 外部路径）。

---

## 0f. 阶段1 常驻/自动重启（T45，🔄 进行中）

### 背景

此前仅能 `lua --run wake_listen`，受 CLI timeout / max_iterations 限制，不能实际使用。

### 已做（代码 + 设备）

- ✅ 常驻 SERVICE + keepalive 判活修复（running 识别 / 空结果启动）
- ✅ **RAMFS 满**（`used=524288`）：`wake_listen.log` 无限增长 + WAV 残留 → TTS `stream timeout: only 0 bytes`
- ✅ 修复：日志 32KB 轮转、启动清理 ramfs、IAT 后删 WAV、TTS 失败删 mp3
- ✅ 日志实测：`WAKE WORD DETECTED: 小q` + Agent `REPLY` 成功；TTS 因 ramfs 失败（已修待重测）

### 待做

- [ ] 烧录后重测：唤醒 → 命令 → **喇叭有声**
- [ ] 长时间挂机后不应再出现 ramfs resize failed

### 文档

- `.agents/voice-progress.md`「阶段 1：常驻 / 自动重启」

### 文档

- `.agents/voice-progress.md`「阶段 1：常驻 / 自动重启」
- `tools/esp_voice_service_enable.py`
- `tools/voice_service_router_rules_snippet.json`

---

## 汇总（按优先级）

| # | 问题 | 状态 | 下一步 |
|---|------|------|--------|
| 1 | IAT 协议版本错误 | ✅ 已修 | — |
| 2 | IAT v2 文本累积 | ✅ 已修 | — |
| 3 | domain 参数错误 | ✅ 已修 | — |
| 4 | 时钟漂移 HMAC 403 | ✅ 已修 | — |
| 5 | **麦克风电平过低** | 🔄 **进行中** | 靠近麦克风大声说话验证 |
| 6 | WDT IDLE0 饿死 | ✅ 已修 | — |
| 7 | 10106 JSON 损坏 | ✅ 已修 | — |
| 8 | `RATIO=0.5` 未标定 | 📋 待做 | 实测 0.3/0.5/0.7/1.0 |
| 9 | voice_turn 嵌套 deadlock | ✅ 绕行 | 无需再修 |
| 10 | **阶段1 常驻/自动重启** | ✅ **功能通；收尾 T46** | 命令门槛 + voice_enable + 挂机验收 |
| 11 | 阶段2 本地指令 + 搜索/天气 + 产品化 | ✅ **核心验收通过** | 2026-09-22 用户确认：抓取时机 + 厦门天气 OK；网页开关可选未测 |
| 12 | Phase3 Always-on（防回声/重连/60s） | ✅ 已烧录验证 | echo_guard + IAT 重连 + rollover 心跳 |
| 13 | 无唤醒误触发（电视/闲聊） | 🔄 **已收紧待复测** | 「达到100%」「你这大声音」「1今天天气」曾误调音量/查天气 |
| 14 | TTS 无声/截断 | 🔄 **边下边播+续播已烧录** | 3KB/13KB 开播遇 EOF 截断；已帧对齐续播 |
