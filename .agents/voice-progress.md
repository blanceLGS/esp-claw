# ESP-Claw 语音交互 — 工作进度

> 更新日期：2026-09-19
> 板卡：Waveshare ESP32-S3-RLCD-4.2（COM3）
> 固件分支：`3afe72d` 之后（含未提交的 ASR 双麦改动 + IAT v2 协议 + wake_listen skill + PGA 37.5dB）

---

## 当前进度快照

| 切片 | 状态 | 备注 |
|------|------|------|
| Phase 0 网页配置（ASR/TTS 字段） | ✅ 完成 | T17–T18 |
| E′ 固定文本 TTS 播放 | ✅ 完成 | T20–T26 |
| B+D 延迟优化 | ✅ 完成 | T28 |
| S1 SiliconFlow stream API 主机侧验证 | ✅ 完成 | T29 |
| S2 设备侧流式 TTS | ✅ 完成 | T30–T34 |
| A′+B′ 讯飞 IAT + 麦克风 | ✅ **软件链路已通** | T35–T36，IAT v2 协议已修复 |
| **C′ 唤醒词「小依」+ VAD** | ✅ **验收通过（wake_smoke）** | peak=12962，IAT「小一」→ 别名命中，woke_count=1 |
| 完整语音闭环（常驻） | ✅ **2026-09-21 10:12 日志验证** | 小q → 我在 → 中文 REPLY → TTS；**无唤醒不再进 Agent**（2026-09-22 收紧） |
| keepalive | ✅ `already alive status=running` | 无误杀 |
| 误触发收紧 | ✅ 2026-09-22/23 | 无唤醒仅本地动词；VAD 2000/350 |
| 唤醒词截断 | ✅ 2026-09-23 | hit/soft_hit 即录；同句命令跳过「我在」 |
| TTS job_id 空等 | ✅ 2026-09-23 | 解析 `Started Lua job <id>`，不再卡 30s |
| **实时 ASR（边录边推）** | ✅ 2026-09-23 | 400ms 切片、`PARTIAL:`、静音收尾 |
| 云端额度泄漏 | 🔄 **已改待烧录** | soft_hit 不再立刻连云；peak≥min_peak 才开 WS；quiet 2s 本地丢弃 |
| 仍待改进 | 识别歪句 / 无实时搜索 | ASR 听写误差；语音路径禁 web_search，新闻/天气会反问 |
| 「一直聆听」刷屏 | 🔄 **已改待烧录** | asr_peak 先本地 1.2s 探测；安静不 SPEAK_NOW/不上云；6 次安静后回 analyzer |
| 语气词当命令 | 🔄 **已改待烧录** | UTF-8 字数门槛；「好/好的/行…」不进 Agent |

---

## 本次会话（2026-09-18~19）已修复

### 1. IAT 协议版本错误（10106 根因）

旧代码用 Spark LLM 的 `header/parameter/payload` 格式 + `wss://iat.xf-yun.com/v1`，
但讯飞语音听写（voicedictation）的官方 WebAPI 是 **IAT v2**：
- 端点：`wss://iat-api.xfyun.cn/v2/iat`
- JSON：`common/business/data` 格式
- 响应：`data.result.ws[].cw[].w`（明文 JSON，非 base64）

**修复**：
- `send_frame()` 改为 IAT v2 格式（`common.app_id` + `business` + `data`）
- `extract_finals()` 改为解析 `data.result.ws[].cw[].w`
- `DEFAULT_ENDPOINT` 改为 `wss://iat-api.xfyun.cn/v2/iat`
- `normalize_asr_endpoint()` 更新以匹配新端点

### 2. IAT v2 文本累积 bug

IAT v2 按 `sn` 分段返回结果，旧代码每次覆盖前一段，最终只保留最后一段。

**修复**：`drain_iat()` 增加 `state.accum` 累积字段，拼接所有分段。

### 3. domain 参数错误（10404 根因）

`domain=iat` 返回 10404（未开通），`domain=slm` 返回 code=0（已开通）。

**修复**：`send_frame()` 首帧 parameter 使用 `domain="slm"`。

### 4. 设备时钟漂移（HMAC 403 根因）

设备时钟漂移 669 秒，超过讯飞 ±300s HMAC 窗口。

**修复**：
- `cap_system.c` 的 `get_current_time` 新增 `force=true` 参数
- `asr_iat_file.lua` 签名前强制 SNTP 同步
- 新增 `skip_time_sync` 参数，wake_listen 循环中只同步一次

### 5. wake_listen skill（C′，T44）

**文件**：
- `components/lua_modules/lua_module_audio/skills/wake_listen/SKILL.md`
- `components/lua_modules/lua_module_audio/skills/wake_listen/scripts/wake_listen.lua`
- `components/lua_modules/lua_module_audio/skills/asr_iat/scripts/asr_iat_file.lua`

**架构**：
- 本地 VAD：`audio.analyzer` 轮询能量（warmup 丢弃 I2S 饱和读数）
- 门控：ASR `min_peak`（默认 `vad_threshold=1400`），静音不连云端
- 唤醒词：`voice_wake_words` + 别名（小一/晓依/小伊…）
- 测试模式：`wake_only` / `exit_on_wake`（先测唤醒，不跑 agent）
- 命令模式：唤醒后录 6s → `agent_ask` → `agent_then_tts`

### 6. PGA 增益上限提升

`AUDIO_INPUT_GAIN_DB_MAX` 从 30.0f 提升到 37.5f（ES7210 硬件上限）。

### 7. 数字化妆阈值调整

- `MIN_USEFUL_PEAK`：500 → 200（适配低电平麦克风）
- 缩放上限：150x（避免噪声爆炸）
- 清理了重复的 scale cap 代码

---

### ✅ C′ wake_smoke 验收（2026-09-19 10:15）

日志：`abc/esp_COM3_20260919_101515.log`

| 项 | 结果 |
|----|------|
| 麦克风 peak | **12962**（阈值 2800） |
| IAT FINAL | `小一。`（讯飞误听「小依」） |
| 唤醒匹配 | **WAKE WORD DETECTED: 小一**（别名表生效） |
| 结束 | `done woke_count=1` + log tail 完整 |

结论：ASR→VAD 门控→唤醒词匹配链路 **已通**。下一步：完整闭环（命令 + agent + TTS）。

### 验收命令

```bash
lua --run --path /system/skills/wake_listen/scripts/wake_smoke.lua --timeout-ms 120000
lua --run --path /system/skills/wake_listen/scripts/wake_dump_log.lua

# 完整闭环（含 agent + TTS）
lua --run --path /system/skills/wake_listen/scripts/wake_listen.lua --timeout-ms 300000
```

### ✅ 软件链路已全通

| 环节 | 状态 | 日志证据 |
|------|------|----------|
| IAT v2 endpoint | ✅ | `endpoint=wss://iat-api.xfyun.cn/v2/iat` |
| SNTP 时钟同步 | ✅ | `time_synced=2026-09-19 01:15:57 CST` |
| WSS 握手 | ✅ | `connected to wss://iat-api.xfyun.cn/v2/iat?authorization=...` |
| HMAC 签名 | ✅ | 握手成功，无 403 |
| 首帧 ACK | ✅ | `rx1: {"code":0,"message":"success"}` |
| 音频帧发送 | ✅ | `sent_frames=75`（3s × 16kHz） |
| domain 路由 | ✅ | `domain=slm` 返回 code=0 |
| IAT v2 响应解析 | ✅ | `data.result.ws[].cw[].w` 正确解析 |
| skip_time_sync | ✅ | 循环中 `time_sync=skipped` |
| wake_listen 循环 | ✅ | 多次迭代正常运行 |

### ✅ ASR 识别有结果

多次测试识别出了内容：
- `FINAL: 嗯，他说一下。`
- `FINAL: 归谁归谁。`
- `FINAL: 因为只能彻底租下来了，没搬。`
- `FINAL: ，手机上放松。`
- `FINAL: ，一会呢。`

**软件链路已完全打通，ASR 能识别出中文内容。**

### ⏳ 待验证：麦克风电平

**现象**：`mono peak` 波动大，从 **129 到 4641**，取决于说话音量和距离。

**诊断要点**：
- 正常人声（靠近麦克风）应让 `Lpeak > 1500`
- 当前波动大，部分测试 Lpeak=129-321（噪音电平），部分测试 Lpeak=1243-4641（人声）
- 唤醒词「小依」未被识别到（可能用户未说，或说的时候电平不够）

**下一步**：
- [ ] 用户**靠近麦克风大声说「小依」**后立刻跑 wake_listen
- [ ] 确认 `Lpeak > 1500` 时 FINAL 是否有「小依」
- [ ] 若仍低，检查 ES7210 硬件（MIC1/MIC2 接线、I2C、PGA 寄存器）
- [ ] 考虑在 `setup_device.c` 提高硬件 PGA 或加前置放大

---

## 阶段 1：常驻 / 自动重启（T45，2026-09-19）

目标：**不靠串口 `lua --run`**，开机后语音监听作为服务常驻；被杀后自动再拉起。

### 设计要点

| 项 | 策略 |
|----|------|
| 服务循环 | `wake_listen` `service=true`：`max_iterations=0`，不因 CLI 演示自动限 20 轮 |
| 任务超时 | async `timeout_ms=0`（直到取消）；单次 IAT/Agent/TTS 仍各自超时，失败回 listening |
| Job | `name=voice_wake`，`exclusive=voice`，`replace=true`，`log_bytes=8192` |
| 保活 | scheduler 每 60s → router → `voice_keepalive.lua` |
| 冷启动 | router `startup`/`boot_completed` → `voice_keepalive.lua`（reason=boot） |
| 防抖 | `/ramfs/voice_wake.keepalive`，15s 内不重复 start |
| 禁用 | `scheduler --pause --id voice_keepalive`；关 router 规则；若 NVS 有 `voice_enable=false` 则 keepalive 直接 return |

### 新增/修改文件

| 文件 | 说明 |
|------|------|
| `skills/voice_service/scripts/voice_keepalive.lua` | 查/启 `voice_wake` |
| `skills/voice_service/scripts/voice_service.lua` | 产品参数直接跑 wake_listen |
| `skills/voice_service/SKILL.md` | 启用/禁用说明 |
| `skills/wake_listen/scripts/wake_listen.lua` | `service=true` 常驻模式 |
| `.recovery/router_rules/router_rules.json` | `voice_service_startup` + `voice_keepalive_check` |
| `.recovery/scheduler/schedules.json` | `voice_keepalive` interval 60s enabled |

### Recovery vs 现有 DATA

`/system/.recovery` **仅在 DATA 缺失时**拷贝。已有 `/fatfs/router_rules` 与 `schedules.json` 的设备需手动合并。

**串口启用 scheduler：**

```
scheduler --add --json "{\"id\":\"voice_keepalive\",\"enabled\":true,\"kind\":\"interval\",\"interval_ms\":60000,\"event_type\":\"schedule\",\"event_key\":\"voice_keepalive\",\"text\":\"voice_keepalive\"}"
scheduler --reload
```

**Router 规则**（并入 `/fatfs/router_rules/router_rules.json` 后 reload，或按项目惯例导入）：

- `voice_service_startup`：match `app_claw` / `startup` / `boot_completed` → `run_script` async `voice_keepalive.lua` args `{reason:boot}`
- `voice_keepalive_check`：match `schedule` / `voice_keepalive` → 同上 `reason:scheduler`

### 验收（设备）

1. 烧录含 `voice_service` skill 的 `system.bin`
2. 启用 scheduler + router 规则
3. 重启：无串口命令时日志出现 `[voice_keepalive] started` / `SERVICE mode`
4. `lua --jobs` 或 keepalive 日志可见 running `voice_wake`
5. 手动 stop 该 job → ≤60s 内被再次拉起
6. 唤醒「小Q/小依」→ 命令 → TTS 仍可用

### 启用工具（串口占用时不可用）

```
python tools/esp_voice_service_enable.py
```

将发送 `scheduler --add` / `reload` / `list`，并手动跑一次 `voice_keepalive`。  
**Router 规则**仍须并入 `/fatfs/router_rules/router_rules.json`（或仅依赖 scheduler→事件→已有规则时需确认 `voice_keepalive_check` 是否在 DATA 中）。

### 状态快照（2026-09-20 设备日志分析）

| 项 | 状态 |
|----|------|
| 开机自启 | ✅ `Loaded 10 router rules` → `matched rule=voice_service_startup` → keepalive reason=boot |
| Scheduler 保活 | ✅ `matched rule=voice_keepalive_check` 每 60s 触发 |
| `voice_wake` SERVICE | ✅ 能启动并进入 VAD/ASR |
| keepalive 误判 | ✅ **已修并烧录** | 仅 `status=running/queued` 算存活 |
| **RAMFS 占满导致 TTS 失败** | ✅ **已修并烧录** | 常驻日志无限增长 + WAV 未删 → `used=524288 max=524288` |
| 唤醒+Agent | ✅ 日志已验证 | `WAKE WORD DETECTED: 小q` → `REPLY: 悠悠这操作...` |

**RAMFS 修复：**

- `wake_listen.log` **32KB 轮转**（超限截断重开）
- 启动时清理 `/ramfs/asr_stream.wav`、`tts_live.mp3`
- IAT 解析后 **删除** WAV
- TTS 播放失败时删除 mp3
- VAD 刷屏日志降频

**验收：** 再触发「小Q」→ 应有 `REPLY` + TTS 播放；不应再刷屏 `ramfs: resize failed`。

## 阶段 1 收尾（T46，2026-09-21）

| 项 | 处理 |
|----|------|
| 命令门槛 | `is_valid_command`：剥唤醒词后过短 / 仍是唤醒词 / 纯标点 / 语气词 → **不进 Agent** |
| 路径覆盖 | 同句唤醒、命令模式、follow-up 统一校验 |
| 产品开关 | keepalive：`/fatfs/voice_enable` 为 `0/false/off` 或 NVS `voice_enable=false` → 不启动 |
| 手动关闭 | `scheduler --pause --id voice_keepalive` + router voice 规则 `enabled=false` |
| 挂机 | 日志轮转 + ramfs 清理（已烧录） |
| 语音调音量 | **不纳入阶段 1**（阶段 2 本地 capability） |

**阶段 1 验收清单：**

- [x] 代码：常驻 SERVICE、keepalive 判活、RAMFS、命令门槛、voice_enable 文件开关
- [x] 已烧录 system 分区（含 T46 门槛）
- [x] 日志：`WAKE WORD DETECTED: 小q` + `same-utterance command rejected (punct-only)`（门槛生效）
- [x] keepalive：`already alive status=running`（无 Replace 误杀）
- [x] 体验补丁：唤醒后 TTS「我在」；命令空则 **重试一次**；命令结束重开 VAD
- [ ] 设备：听到「我在」后立刻说命令 → Agent + TTS
- [ ] 挂机无 ramfs 报错

**阶段 2（T47/T48–T51，2026-09-21 代码完成，已烧录，待设备验收）**

| 项 | 状态 |
|----|------|
| 音量/大声/小声/静音 | 本地执行，不进 Agent；TTS 播「音量已调到…」；写入 DATA `voice_tts_volume` |
| 几点/日期 | 本地 `get_current_time`，不进 Agent |
| 关闭/打开语音 | 写 DATA `voice_enable` + stop / keepalive |
| 天气/新闻… | **直调** `web_search` 短句 TTS；失败再回落 agent + 可搜索 prompt |
| 闲聊 | 仍禁搜索，中文短答 |
| 网页开关 | LLM 页「常驻语音监听」`voice_enable`；保存后写 DATA 并生成 `voice_wake.cmd` |
| keepalive | disable 时 stop 在跑任务；支持 `voice_wake.cmd=restart/stop/start`；读音量文件 |
| 文档 | 本文件 + `voice_service/SKILL.md` + T47 |

### 阶段 2 验收（设备，2026-09-22 09:40 日志）

| 项 | 结果 |
|----|------|
| 唤醒「小姨」→「我在」 | ✅ `WAKE WORD DETECTED: 小姨` + TTS |
| keepalive | ✅ 多次 `already alive status=running` |
| 天气命令 → 直调搜索 | ✅ `查询一下今天的天气` → `live web_search` → `SPOKEN` → 播放 |
| loose-wake 天气 | ✅ 旧行为；**2026-09-22 起无唤醒不进 Agent** |
| 挂机 / ramfs | ✅ 无 resize 报错，`tts_live.mp3` 有 cleaned |
| 安静 VAD | ✅ `VAD window silent, keep analyzer listening` |
| 双次「我在」 | ✅ 已修并验证（`ack already played`） |
| ASR 断线杀服务 | ✅ `run_asr` pcall，失败回 listening |
| 天气/休斯敦 SEO | ✅ Open-Meteo + 城市表（含厦门）+ 地理编码兜底 |
| 搜索摘要脏 | ✅ 过滤 SEO 标题 |
| 「请开始说话」时已说完 | ✅ 去掉 pre_roll 延迟；VAD 命中即录；不再播 SPEAK_NOW（用户确认效果可以） |
| 「厦门天气」仍查北京 | ✅ 命令抽城市 + 表/地理编码（用户确认效果可以） |
| 音量/几点/关闭语音 | ✅ UTF-8 修复后本地指令可用 |
| 网页开关保存热同步 | ⏳ 可选，未测 |
| 音量/几点/关闭语音 | ⏳ 本轮日志未测 |
| 网页开关保存热同步 | ⏳ 本轮未测 |

**待补测：** 「大声点」「现在几点」「关闭语音」；网页关「常驻语音监听」。

### 烧录说明

- 仅 skill 逻辑：`system.bin` @ `0xa20000` 即可测本地指令 + 搜索直调
- **网页 voice_enable / 保存热同步**：需完整固件（app_config + http_server + frontend 嵌入）
- **2026-09-21 11:01 已烧录**：`edge_agent.bin` @ `0x20000` + `system.bin` @ `0xa20000`（未写 storage.bin，保留 DATA）

**CLI 测试 vs 产品**

- 串口 `lua --run wake_listen`：仍可能自动有限轮次（便于日志收尾）
- 产品路径：keepalive 以 `service=true` 启动，**无限循环**直至 job 被取消

**历史问题备忘（keepalive 曾每分钟 replace）：** `lua_get_async_job` 为多行文本 `status=running`，不得用 JSON-only 解析判死。

**验收（设备）：**

1. tick：`[voice_keepalive] already alive status=running`
2. boot：`starting` → `[wake_listen] SERVICE mode` + VAD
3. 说 **小Q/小依** → `WAKE WORD DETECTED`
4. 无效句 → `command rejected`，无 Agent
5. 无 `Replacing conflicting job`、无 ramfs 刷屏

若仍无 VAD 日志：串口执行  
`lua --run --path /system/skills/voice_service/scripts/voice_keepalive.lua --timeout-ms 20000`  
并把输出发回。

### CLI 测试 vs 产品

- 串口 `lua --run wake_listen`：仍可能自动 `max_iterations=20`（便于日志收尾）
- 产品路径：keepalive 以 `service=true` 启动，**无限循环**直至 job 被取消

---

## Phase 3 Always-on polish（T52–T54，原 voice-interaction.md §6）

| 项 | 状态 |
|----|------|
| 半双工防回声 | TTS 前后 `echo_guard_ms`（默认 500ms），VAD 忽略 `echo`；「我在」后等 ring-out 再开命令窗 |
| IAT 重连 | `websocket.connect` 重试 3 次；发送失败清 socket 后以首帧重连重试 1 次 |
| 60s 存活滚动 | 服务循环 `rollover_ms=60000` 打点；约 10 分钟强制 SNTP（HMAC 防时钟漂移） |
| 热词 dhw/res_id | 📋 未做（可选） |
| SiliconFlow ASR 调试路径 | 📋 未做（可选；定位为 file debug，非流式） |
| 中英识别大模型 | 🔄 协议已通（`engine=slm` code=0）；**base64 解包已修待测**（曾 FINAL 空）；dhw 改为 `dhw=utf-8;词\|词` |
| 设备验收大模型 | ⏳ 再对麦一句中文，看 `FINAL:` 是否有字 |

### TTS 边下边播（T31/T32，2026-09-22）

- `save_direct` 边下边写 `/ramfs/tts_live.mp3`；约 8–16KB 开播。
- 播放到当前 EOF 后若 HTTP 未完：从 `consumed` 切尾段（对齐 `0xFF` 帧同步）**续播**，直到 job 结束。
- 修复厦门天气截断：勿把 HTTP 停顿当「整包就绪」。

### 误触发收紧（2026-09-22 13:57 / 15:26 日志）

| 误触发 | 原因 | 修复 |
|--------|------|------|
| `达到100%` → 调音量 | 裸 `(N)%` 匹配 | 仅「音量」语境下的百分比 |
| `你这大声音` → 调音量 | 裸「大声」 | 仅「大声点/大点声/音量大…」 |
| `1今天天气` → 查天气 | loose-wake 过松 | 无唤醒仅高精度本地动词 |
| `厦门天气怎么样？` / `现在几点？` / `网易云音乐点击播放` / 长闲聊含「时间」→ Agent | `is_command_like` short_keys 日常词短路 | **去掉 loose-wake 进 Agent**；无唤醒只留音量/静音/开关语音 |
| 环境闲聊大量 VAD hit 进 ASR | `vad_threshold=1200` + `hold=200ms` 过松 | 默认/产品入口改为 **2000 / 350ms**（`voice_service` + `voice_keepalive` + `wake_listen`） |
| 说「小依天气怎么样」ASR 只有「天气怎么样」 | VAD hit 后再等 `hold=350ms` 才开录，截掉句首唤醒词 | **hit 立刻开录**；强起音（peak≥thr+800）单次 poll 即 hit |

无唤醒可执行：关闭/打开语音、静音、**音量/大声点/小声点**。天气/时间/播放/Agent **必须**带「小依/小Q」。follow-up 窗口内仍可免唤醒续句。

**额度评估（2026-09-23 22:54 日志，约 2 分钟）**：`ws connected`≈13 次，真正 FINAL 仅 6；大量 soft_hit（peak 1k–2k 环境声）也开云端。实时本身不是主因，**过早 connect** 才是。已本地门控后再连云。

**离线 ASR 评估结论**：
- Whisper / Vosk / sherpa 自由句：**放不进** ESP32-S3（模型 30MB+，实时算力不够）
- **ESP-SR WakeNet + MultiNet**：**可行**，官方为 S3+PSRAM；唤醒离线 + 固定指令集离线；自由句仍上云
- 推荐混合：本地门控省额度（已做）→ WakeNet 离线唤醒 → MultiNet 覆盖「天气/时间/音量」→ 其余才 cloud ASR

**唤醒词被截（2026-09-23 21:45/22:03 日志）**：`FINAL` 只有「天气怎么样？/明天气怎么样？」无「小依」。原因：(1) hit 后等 hold 再开录；(2) 无 pre-roll。已改 hit/soft_hit 即录 + 同句命令跳过「我在」。另：`thread.start` 返回整段 `job_id=...` 文本被当成 id，`thread.get` 永远查不到 → TTS 卡满 30s 超时；已解析 `job_id=`。若连贯说仍丢词，两步：「小依」→「我在」→「天气怎么样」。

- 网页「识别引擎」听写 ↔ 中英大模型：**兼容可互切**（协议/endpoint/结果解析自动分支）。
- SiliconFlow 档位**未实现客户端**，不可当第三引擎。
- SLM：`text` base64 需补 padding；`dhw=utf-8;词1|词2`；`dwa=wpgs` 可选。

### ASR 引擎评估备忘（2026-09-22，只讨论）

- 听写流式：`wss://iat-api.xfyun.cn/v2/iat`，`common/business/data`，domain `iat` — **现用主路径**
- 中英大模型：`wss://iat.xf-yun.com/v1`，`header/parameter/payload`，domain **`slm`**，`payload.result.text` base64；202 方言 + dwa/dhw/res_id — **值得网页可选**
- SiliconFlow：HTTP transcriptions 文件上传 — **不做流式主路径**

**参数：** `echo_guard_ms`（100–3000，默认 500）、`rollover_ms`（默认 60000）。

---

## 关键文件

| 文件 | 说明 |
|------|------|
| `components/lua_modules/lua_module_audio/skills/asr_iat/scripts/asr_iat_file.lua` | IAT v2 客户端核心 |
| `components/lua_modules/lua_module_audio/skills/wake_listen/scripts/wake_listen.lua` | 唤醒词 + VAD 监听（`service=true` 常驻；无唤醒不进 Agent） |
| `components/lua_modules/lua_module_audio/skills/voice_service/scripts/voice_keepalive.lua` | 阶段1 保活/自动重启 |
| `components/lua_modules/lua_module_audio/skills/voice_service/scripts/voice_setup_scheduler.lua` | 写入 DATA scheduler 保活项 |
| `components/lua_modules/lua_module_audio/skills/voice_service/scripts/voice_setup_router.lua` | 写入 DATA router 开机/保活规则 |
| `tools/voice_service_router_rules_snippet.json` | 开机/保活 router 规则片段（并入 DATA） |
| `application/edge_agent/fatfs_image/system/.recovery/router_rules/router_rules.json` | 开机/调度拉起语音服务（仅新 DATA） |
| `components/lua_modules/lua_module_audio/skills/voice_turn/scripts/voice_turn.lua` | 手动语音闭环 |
| `components/claw_capabilities/cap_system/src/cap_system.c` | `get_current_time` 新增 `force` 参数 |
| `components/lua_modules/lua_module_audio/src/audio_private.h` | `AUDIO_INPUT_GAIN_DB_MAX=37.5f` |
| `tools/run_wake.py` | wake_listen 测试脚本（支持长超时） |
| `.agents/voice-interaction.md` | 完整开发计划 |
| `.agents/voice-issues.md` | 问题跟踪 |

---

## 测试命令

```bash
# ASR 单次测试
lua --run --path /system/skills/asr_once/scripts/asr_once.lua

# C' 只测唤醒词（推荐先跑这个）
lua --run --path /system/skills/wake_listen/scripts/wake_listen.lua --args-json "{\"wake_only\":true,\"exit_on_wake\":true,\"max_iterations\":20,\"vad_wait_ms\":60000}"

# 或主机脚本
python tools/run_wake.py 120000 '{"wake_only":true,"exit_on_wake":true,"max_iterations":15}'

# 完整闭环：唤醒 → 命令 → Agent → TTS
python tools/run_wake.py 300000
```

---

## 尚未做 / 下一步

1. **烧录 + 验收 C′**：编译烧录后，先跑 `wake_only`，靠近麦说「小依」，看 `VAD hit` / `WAKE WORD DETECTED`。
2. **调 `vad_threshold`**：漏检调低，环境噪声误触发调高（默认 2000，产品入口 voice_service/keepalive 同步）。
3. **E 完整闭环（真语音）**：唤醒 + 命令 + agent + TTS；产品路径禁止 skill 内嵌套 `agent_ask`。
4. **双麦 `RATIO` 标定**：当前直接取 L 声道，优先级降低。
