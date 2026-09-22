---
{
  "name": "diag_gain",
  "description": "Diagnostic: test ES7210 PGA gain response at different volume levels. Records short clips at volume=30/60/80/100 and prints peak values. CLI only.",
  "metadata": {
    "cap_groups": ["cap_lua"],
    "manage_mode": "readonly"
  },
  "execution": {
    "entry": "scripts/diag_gain.lua"
  }
}
---

# Diag Gain（ES7210 PGA 增益诊断）

测试 ES7210 PGA 是否对 volume 参数正确响应。

## 测试方法

对麦克风**持续说话**（不要停），脚本会在 volume=30/60/80/100 各录 3 秒。

## 预期结果

- PGA 正确响应：peak 随 volume 增加而显著增加（比例 >5×）
- PGA 未响应：peak 变化不大（比例 <2×），说明增益卡在 0dB

## 调用

```bash
lua --run --path /system/skills/diag_gain/scripts/diag_gain.lua --timeout-ms 60000
```
