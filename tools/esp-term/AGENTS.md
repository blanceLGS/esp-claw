# AGENTS — esp-term (standalone ESP serial terminal)

This folder is a **self-contained** Windows GUI serial terminal for ESP32-class boards
(especially ESP32-S3 USB-Serial/JTAG). Copy the directory anywhere; paths are
relative to `esp_term.py`.

## Layout

```
tools/esp-term/
  esp_term.py        # main app (tkinter + pyserial)
  launch.vbs         # double-click, no console (pythonw)
  launch.bat         # CLI start
  build_exe.bat      # PyInstaller → dist/esp-term.exe
  requirements.txt   # pyserial (runtime); pyinstaller only for packaging
  config.json        # full session prefs (see schema)
  logs/              # default session log dir
  dist/esp-term.exe  # packaged Windows GUI (~11 MB)
```

Optional sibling (non-GUI, for agents): `tools/serial_log.py` — capture N seconds
of serial output without a TTY.

Related MiMo skill: `.mimocode/skills/esp-serial-debug/`

## How to run

**Preferred:** double-click `dist\esp-term.exe` (no Python install).

```bat
tools\esp-term\launch.vbs
tools\esp-term\build_exe.bat
```

```powershell
& "C:\Espressif\tools\python\v5.5.4\venv\Scripts\pythonw.exe" `
  "D:\A-Studen\GITHUB\esp-claw\tools\esp-term\esp_term.py"
```

Runtime: `pyserial` only (bundled in the exe).

## What it does

| Area | Behavior |
|---|---|
| Ports | Dropdown; Espressif VID `0x303A` marked `*` |
| Connect | Opens port **before** setting DTR/RTS idle (`dtr=0,rts=0`) so open does not pulse reset |
| Link watch | ~0.8s: port gone / read error → auto offline + stop session log |
| RST | Manual EN pulse via RTS (esptool USB-JTAG timing). **Only when user clicks** |
| rst-on-connect | **Default OFF.** Enabling it pulses reset after Connect |
| Session log | Only while connected (SecureCRT-style). `log-on-connect` or `● REC` |
| Log file | `<log_dir>/esp_<port>_<YYYYMMDD_HHMMSS>.log`, line-buffered |
| UI filter | `A 全` / `E W I D` / `— 无标识` + search highlight |
| CR/LF | `\r\n`, `\n`, and lone `\r` all break lines in the view |
| TX | ASCII + EOL (LF/CRLF/None); optional **加回车换行** off = raw |
| HEX TX/RX | SSCOM-style checkboxes |
| Timed send | Interval ms; auto-stop on disconnect |
| Custom cmds | Button bar; edit via `⚙`; stored in `config.json` |
| RAM | In-memory ring `MAX_LOG_LINES=2000`; full capture still goes to disk if REC on |

## Hardware rules (important for other agents)

1. **Do not** treat opening the COM port as permission to reset the chip.
2. Default path: Connect → idle DTR/RTS → user may click RST if they want a reboot.
3. ESP32-S3 native USB-Serial/JTAG: a **falling DTR edge after open** can look like
   reset. Always set `dtr=False,rts=False` **before** `Serial.open()`.
4. `RST` / `rst-on-connect` are the only intentional EN pulses. Never fire them
   “to get logs” unless the user asked.
5. USB unplug → tool drops to offline; do not assume the port stays valid.

## config.json schema

Written on close / log-dir change / macro save. Key fields:

```json
{
  "log_dir": "C:\\logs",
  "macros": [{ "label": "help", "cmd": "help" }],
  "geometry": "1080x680",
  "port": "COM3",
  "baud": "115200",
  "eol": "LF",
  "add_eol": true,
  "hex_display": false,
  "hex_send": false,
  "timed_ms": "1000",
  "show_ts": true,
  "autoscroll": true,
  "wrap": false,
  "reset_on_connect": false,
  "log_on_connect": true,
  "lvl_all": true,
  "lvl_raw": true,
  "lvl_E": true, "lvl_W": true, "lvl_I": true, "lvl_D": true
}
```

Frozen exe reads/writes config next to `esp-term.exe`. `timed_send` is never restored ON.

## Session log format

```
# esp-term session log
# started=2026-09-11T19:18:00 port=COM3 baud=115200 auto=True
19:18:00.123 [sys] — connected COM3 @ 115200 —
19:18:00.200 [rx] I (24) boot: ESP-IDF v5.5.4 ...
19:18:01.000 [tx] ❯ help
# stopped=2026-09-11T19:20:00 reason=disconnect
```

Kinds: `rx` | `tx` | `sys` | `err` | `link` (link is handled in UI, may not hit file).

## Agent automation (headless)

GUI is **not** suitable for unattended capture. Use:

```powershell
$py = "C:\Espressif\tools\python\v5.5.4\venv\Scripts\python.exe"
& $py "D:\A-Studen\GITHUB\esp-claw\tools\serial_log.py" --list
& $py "D:\A-Studen\GITHUB\esp-claw\tools\serial_log.py" -p COM3 --reset -t 15 -o build\boot.log
```

Do **not** run interactive `idf.py monitor` in a non-TTY agent shell.

To open the GUI for the user:

```powershell
Start-Process -FilePath "D:\A-Studen\GITHUB\esp-claw\tools\esp-term\launch.bat"
# confirm:
Get-Process python | Where-Object { $_.MainWindowTitle -match "esp-term" }
```

## Typical flows

- User: 打开串口终端 → `launch.bat` / `Start-Process` launch.bat
- User: 抓启动日志 → `serial_log.py --reset -t 15` (or GUI Connect + RST)
- User: 交互 CLI → GUI Connect → bottom `❯` + Enter / custom buttons
- User: 长会话落盘 → Connect with **log-on-connect** on; files under `log_dir`

## Gotchas

| Symptom | Cause / fix |
|---|---|
| Connect 时板子重启 | Old tool wrote DTR after open; fixed by pre-open idle. If still resets, USB-JTAG + Windows CDC may still toggle lines on open |
| RST 无效 | Port must be open; some S3 USB-JTAG paths ignore RTS; use board EN key or firmware `restart` |
| pyserial missing | Use ESP-IDF venv python or `pip install pyserial` in a venv the user owns |
| Port busy | Close other terminals / old esp-term instances before Connect |
| Logs grow RAM | UI ring is 2000 lines; file log is unlimited while REC is on |
| Window title check | Match `esp-term` (versioned title `esp-term 1.0.0 — ESP Serial`) |

## Extending

- Keep **all** new paths under `APP_DIR`.
- Persist UI state only in `config.json` (same schema keys).
- Do not add silent hardware side effects (reset, baud change on plug, flash).
- Prefer `tools/serial_log.py` for agent-side capture; keep GUI for humans.

## Version

`APP_VERSION` in `esp_term.py` (currently `1.0.0`). Update when shipping breaking
UI or config changes.
