#!/usr/bin/env python3
"""esp-term — standalone ESP serial terminal (dark UI, session log, custom cmds).

Layout (all paths live next to this file):
  esp_term.py          this app
  config.json          port/log/macros prefs
  logs/                default session log directory
  launch.bat           Windows start script
"""

from __future__ import annotations

import json
import queue
import re
import sys
import threading
import time
import tkinter as tk
from collections import deque
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

try:
    import serial
    from serial.tools import list_ports
except ImportError as exc:
    raise SystemExit(
        "pyserial not found.\n"
        "Install: pip install pyserial\n"
        "Or use the bundled launch.bat (ESP-IDF venv python)."
    ) from exc

APP_DIR = Path(__file__).resolve().parent
# PyInstaller onefile: keep config/logs next to the .exe, not in _MEIPASS
if getattr(sys, "frozen", False):
    APP_DIR = Path(sys.executable).resolve().parent
APP_NAME = "esp-term"
APP_VERSION = "1.1.0"
# Keep RAM bounded: in-memory ring + matching Text widget cap
MAX_LOG_LINES = 2000
MAX_HIST = 50
# UI flood control: max lines applied to Text per pump tick
MAX_UI_BATCH = 250
# Port-presence scan is expensive on Windows; don't do it every tick
LINK_PORT_SCAN_S = 2.0

# Terminal palette
BG = "#0c0c0c"
BG2 = "#111111"
FG = "#cccccc"
DIM = "#6e7681"
BORDER = "#30363d"
ACCENT = "#3b8eea"
GREEN = "#3fb950"
YELLOW = "#d29922"
RED = "#f85149"
BLUE = "#58a6ff"
CYAN = "#39c5cf"
PURPLE = "#bc8cff"
GRAY = "#8b949e"

LOG_BG = "#010409"
TS = "#484f58"
LVL_E = "#ff7b72"
LVL_W = "#e3b341"
LVL_I = "#79c0ff"
LVL_D = "#8b949e"
TX_C = "#56d364"
RX_C = "#c9d1d9"
SYS_C = "#d2a8ff"
TAG_C = "#ffa657"

BAUDS = ["9600", "57600", "115200", "230400", "460800", "921600"]
LINE_ENDS = ["LF", "CRLF", "None"]
ESPRESSIF_VIDS = {0x303A, 0x10C4, 0x1A86, 0x0403}
LEVEL_RE = re.compile(r"^\s*([EWIDV])\s*\((\d+)\)\s*([^:]+):")
DEFAULT_MACROS = [
    {"label": "help", "cmd": "help"},
    {"label": "wifi", "cmd": "wifi status"},
    {"label": "caps", "cmd": "cap list"},
    {"label": "skills", "cmd": "skill list"},
    {"label": "mem", "cmd": "memory"},
    {"label": "reboot", "cmd": "restart"},
]

# Self-contained app paths
_DEFAULT_LOG_ROOT = APP_DIR / "logs"
_CFG_PATH = APP_DIR / "config.json"


def _fmt(n: int) -> str:
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n/1024:.1f}K"
    return f"{n/(1024*1024):.2f}M"


class SerialTerminal:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title(f"{APP_NAME} {APP_VERSION} — ESP Serial")
        self.root.geometry("1080x680")
        self.root.minsize(720, 420)
        self.root.configure(bg=BG)

        self._ui_cfg = self._load_ui_cfg()
        geo = self._ui_cfg.get("geometry") or "1080x680"
        try:
            self.root.geometry(geo)
        except tk.TclError:
            self.root.geometry("1080x680")

        self.ser: serial.Serial | None = None
        self.rx_q: queue.Queue[tuple[str, str]] = queue.Queue()
        self.stop_reader = threading.Event()
        self.reader: threading.Thread | None = None
        self.connected = False
        self.paused = False
        self.rx_bytes = self.tx_bytes = 0
        self.rate_window: deque = deque(maxlen=32)
        self._all: deque = deque(maxlen=MAX_LOG_LINES)
        self.hist: deque = deque(maxlen=MAX_HIST)
        self.hist_idx = -1
        self._pump_id: str | None = None
        self._tick_id: str | None = None
        self._trim_at = MAX_LOG_LINES
        self._last_port_scan = 0.0
        self._last_port_ok = True

        self.port_var = tk.StringVar()
        cfg = self._ui_cfg
        self.baud_var = tk.StringVar(value=str(cfg.get("baud", "115200")))
        self.eol_var = tk.StringVar(value=str(cfg.get("eol", "LF")))
        self.cmd_var = tk.StringVar()
        self.filter_var = tk.StringVar(value=str(cfg.get("filter", "")))
        self.show_ts = tk.BooleanVar(value=bool(cfg.get("show_ts", True)))
        self.autoscroll = tk.BooleanVar(value=bool(cfg.get("autoscroll", True)))
        self.wrap = tk.BooleanVar(value=bool(cfg.get("wrap", False)))
        # USB-Serial/JTAG: opening the port can leave RTS asserted and hold EN.
        # We only *release* DTR/RTS after open — never pulse reset unless the
        # user clicks RST (or explicitly enables rst-on-connect).
        self.reset_on_connect = tk.BooleanVar(value=bool(cfg.get("reset_on_connect", False)))
        self.rec_on_connect = tk.BooleanVar(value=bool(cfg.get("log_on_connect", True)))
        # SSCOM-style TX/RX options
        self.hex_display = tk.BooleanVar(value=bool(cfg.get("hex_display", False)))
        self._hex_mode = bool(cfg.get("hex_display", False))  # thread-safe for reader
        self.hex_send = tk.BooleanVar(value=bool(cfg.get("hex_send", False)))
        self.timed_send = tk.BooleanVar(value=False)  # never auto-start
        self.timed_ms = tk.StringVar(value=str(cfg.get("timed_ms", "1000")))
        self.add_eol = tk.BooleanVar(value=bool(cfg.get("add_eol", True)))
        self._timed_id: str | None = None
        self.recording = False
        self.rec_path: Path | None = None
        self._rec_fp = None
        self._rec_lock = threading.Lock()
        self.log_root = self._load_log_root()
        self.log_dir_var = tk.StringVar(value=str(self.log_root))
        self.macros = self._load_macros()
        self._connected_port: str | None = None
        self._link_lost = False
        self.lvl = {k: tk.BooleanVar(value=bool(cfg.get(f"lvl_{k}", True))) for k in "EWID"}
        # Master "全接收": show every line (incl. untagged), not just E/W/I/D
        self.lvl_all = tk.BooleanVar(value=bool(cfg.get("lvl_all", True)))
        # Lines without E/W/I/D prefix (raw UART / printf / ESP-ROM boot, etc.)
        self.lvl_raw = tk.BooleanVar(value=bool(cfg.get("lvl_raw", True)))
        self._last_port = str(cfg.get("port", ""))
        self.status_var = tk.StringVar(value="offline")
        self.led_color = {"on": False}

        self._style()
        self._build()
        self._refresh_ports()
        self._tick()
        self._pump_id = self.root.after(60, self._pump)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _load_log_root(self) -> Path:
        try:
            if _CFG_PATH.is_file():
                data = json.loads(_CFG_PATH.read_text(encoding="utf-8"))
                p = Path(data.get("log_dir", "")).expanduser()
                if str(p):
                    return p
        except Exception:  # noqa: BLE001
            pass
        return _DEFAULT_LOG_ROOT

    def _load_ui_cfg(self) -> dict:
        """Full prefs blob from config.json (empty dict if missing/corrupt)."""
        try:
            if _CFG_PATH.is_file():
                data = json.loads(_CFG_PATH.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    return data
        except Exception:  # noqa: BLE001
            pass
        return {}

    def _ui_snapshot(self) -> dict:
        """Current UI state for config.json (SSCOM-like session prefs)."""
        try:
            geo = self.root.geometry()
        except Exception:  # noqa: BLE001
            geo = "1080x680"
        port = self._port() or self._last_port or ""
        return {
            "log_dir": str(self.log_root),
            "macros": self.macros,
            "geometry": geo,
            "port": port,
            "baud": self.baud_var.get(),
            "eol": self.eol_var.get(),
            "add_eol": bool(self.add_eol.get()),
            "hex_display": bool(self.hex_display.get()),
            "hex_send": bool(self.hex_send.get()),
            "timed_ms": self.timed_ms.get(),
            "show_ts": bool(self.show_ts.get()),
            "autoscroll": bool(self.autoscroll.get()),
            "wrap": bool(self.wrap.get()),
            "filter": self.filter_var.get(),
            "reset_on_connect": bool(self.reset_on_connect.get()),
            "log_on_connect": bool(self.rec_on_connect.get()),
            "lvl_all": bool(self.lvl_all.get()),
            "lvl_raw": bool(self.lvl_raw.get()),
            **{f"lvl_{k}": bool(self.lvl[k].get()) for k in "EWID"},
        }

    def _load_macros(self) -> list[dict]:
        try:
            if _CFG_PATH.is_file():
                data = json.loads(_CFG_PATH.read_text(encoding="utf-8"))
                raw = data.get("macros")
                if isinstance(raw, list) and raw:
                    out = []
                    for item in raw:
                        if isinstance(item, dict) and item.get("label") and item.get("cmd") is not None:
                            out.append({"label": str(item["label"]), "cmd": str(item["cmd"])})
                    if out:
                        return out
        except Exception:  # noqa: BLE001
            pass
        return [dict(m) for m in DEFAULT_MACROS]

    def _save_cfg(self) -> None:
        try:
            payload = self._ui_snapshot()
            _CFG_PATH.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except OSError:
            pass

    def _apply_log_dir_entry(self, _event=None) -> None:
        raw = self.log_dir_var.get().strip()
        if not raw:
            return
        path = Path(raw).expanduser()
        try:
            path.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            messagebox.showerror("esp-term", f"Invalid log folder:\n{path}\n{exc}")
            self.log_dir_var.set(str(self.log_root))
            return
        if path != self.log_root:
            self.log_root = path
            self._save_cfg()
            self._append("sys", f"— log dir → {path} —")

    def _browse_log_dir(self) -> None:
        initial = str(self.log_root if self.log_root.exists() else _DEFAULT_LOG_ROOT)
        chosen = filedialog.askdirectory(title="Log folder", initialdir=initial, mustexist=False)
        if not chosen:
            return
        path = Path(chosen)
        try:
            path.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            messagebox.showerror("esp-term", f"Cannot create folder:\n{path}\n{exc}")
            return
        self.log_root = path
        self.log_dir_var.set(str(path))
        self._save_cfg()
        self._append("sys", f"— log dir → {path} —")

    # ── chrome ───────────────────────────────────────────────────────────
    def _style(self) -> None:
        st = ttk.Style(self.root)
        try:
            st.theme_use("clam")
        except tk.TclError:
            pass
        mono = ("Consolas", 10)
        st.configure(".", background=BG, foreground=FG, fieldbackground=BG2, bordercolor=BORDER)
        st.configure("TFrame", background=BG)
        st.configure("TLabel", background=BG, foreground=DIM, font=mono)
        st.configure("TButton", background=BG2, foreground=FG, borderwidth=1, padding=(8, 4), font=mono)
        st.map("TButton", background=[("active", BORDER), ("pressed", ACCENT)])
        st.configure("Go.TButton", background="#1f6feb", foreground="#fff")
        st.map("Go.TButton", background=[("active", "#388bfd"), ("pressed", "#1158c7")])
        st.configure("Stop.TButton", background="#da3633", foreground="#fff")
        st.map("Stop.TButton", background=[("active", "#f85149")])
        st.configure("TCombobox", fieldbackground=BG2, background=BG2, foreground=FG, arrowcolor=FG, font=mono)
        st.map("TCombobox", fieldbackground=[("readonly", BG2)], foreground=[("readonly", FG)])
        st.configure("TEntry", fieldbackground=BG2, foreground=FG, insertcolor=FG, font=mono)
        st.configure("TCheckbutton", background=BG, foreground=DIM, font=mono)
        st.map("TCheckbutton", background=[("active", BG)])

    def _pill(self, parent, key: str):
        var = self.lvl[key]
        color = {"E": LVL_E, "W": LVL_W, "I": LVL_I, "D": LVL_D}[key]
        btn = tk.Checkbutton(
            parent, text=key, variable=var, command=self._on_lvl_click,
            bg=BG2, fg=color, selectcolor=BG, activebackground=BG2, activeforeground=color,
            font=("Consolas", 9, "bold"), bd=0, padx=6, pady=1, highlightthickness=0,
        )
        return btn

    def _toggle_lvl_all(self) -> None:
        """全接收 on/off — syncs E/W/I/D and untagged (raw) lines."""
        on = self.lvl_all.get()
        for v in self.lvl.values():
            v.set(on)
        self.lvl_raw.set(on)
        self._redraw()

    def _on_lvl_click(self) -> None:
        all_on = all(v.get() for v in self.lvl.values()) and self.lvl_raw.get()
        self.lvl_all.set(all_on)
        self._redraw()

    # ── layout ───────────────────────────────────────────────────────────
    def _build(self) -> None:
        # One-line connection strip
        top = tk.Frame(self.root, bg=BG2, pady=4)
        top.pack(fill=tk.X, padx=1, pady=(1, 0))

        self.led = tk.Canvas(top, width=10, height=10, bg=BG2, highlightthickness=0)
        self.led.pack(side=tk.LEFT, padx=(10, 6))
        self._led_id = self.led.create_oval(1, 1, 9, 9, fill=RED, outline="")

        tk.Label(top, text="port", bg=BG2, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT)
        self.port_var.set("…")
        self.port_menu = tk.OptionMenu(top, self.port_var, "…")
        self.port_menu.configure(
            bg=BG2, fg=FG, activebackground=BORDER, activeforeground=FG,
            highlightthickness=1, highlightbackground=BORDER, highlightcolor=ACCENT,
            font=("Consolas", 10), bd=0, padx=8, pady=2, indicatoron=False, width=18,
        )
        self.port_menu["menu"].configure(bg=BG2, fg=FG, activebackground=ACCENT, activeforeground="#fff", font=("Consolas", 10))
        self.port_menu.pack(side=tk.LEFT, padx=(6, 4))
        ttk.Button(top, text="↻", width=3, command=self._refresh_ports).pack(side=tk.LEFT, padx=(0, 10))

        tk.Label(top, text="baud", bg=BG2, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT)
        self.baud_menu = tk.OptionMenu(top, self.baud_var, *BAUDS)
        self.baud_menu.configure(
            bg=BG2, fg=FG, activebackground=BORDER, activeforeground=FG,
            highlightthickness=1, highlightbackground=BORDER,
            font=("Consolas", 10), bd=0, padx=8, pady=2, indicatoron=False,
        )
        self.baud_menu["menu"].configure(bg=BG2, fg=FG, activebackground=ACCENT, activeforeground="#fff", font=("Consolas", 10))
        self.baud_menu.pack(side=tk.LEFT, padx=(6, 10))

        self.conn_btn = ttk.Button(top, text="Connect", style="Go.TButton", command=self._toggle)
        self.conn_btn.pack(side=tk.LEFT, padx=(0, 6))
        ttk.Button(top, text="RST", command=self._reset).pack(side=tk.LEFT, padx=2)
        tk.Checkbutton(
            top, text="rst-on-connect", variable=self.reset_on_connect,
            bg=BG2, fg=DIM, selectcolor=BG, activebackground=BG2,
            font=("Consolas", 8),
        ).pack(side=tk.LEFT, padx=(2, 4))
        self.rec_btn = tk.Button(
            top, text="● REC", command=self._toggle_rec,
            bg="#3a2228", fg=RED, activebackground="#5a3038",
            font=("Consolas", 9, "bold"), bd=0, padx=8, pady=2, relief=tk.FLAT,
            state=tk.DISABLED, disabledforeground="#555555",
        )
        self.rec_btn.pack(side=tk.LEFT, padx=(4, 2))
        tk.Checkbutton(
            top, text="log-on-connect", variable=self.rec_on_connect,
            bg=BG2, fg=DIM, selectcolor=BG, activebackground=BG2,
            font=("Consolas", 8),
        ).pack(side=tk.LEFT, padx=(0, 4))
        ttk.Button(top, text="⏸", width=3, command=self._toggle_pause).pack(side=tk.LEFT, padx=2)
        ttk.Button(top, text="×", width=3, command=self._clear).pack(side=tk.LEFT, padx=2)
        ttk.Button(top, text="⇩", width=3, command=self._save).pack(side=tk.LEFT, padx=(2, 0))

        self.conn_label = tk.Label(top, text=" offline ", bg=BG2, fg=DIM, font=("Consolas", 9))
        self.conn_label.pack(side=tk.RIGHT, padx=10)

        # Filter strip
        f = tk.Frame(self.root, bg=BG, pady=3)
        f.pack(fill=tk.X, padx=8)
        tk.Label(f, text="lvl", bg=BG, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT, padx=(2, 4))
        # 全接收 master toggle
        tk.Checkbutton(
            f, text="A", variable=self.lvl_all, command=self._toggle_lvl_all,
            bg=BG2, fg=ACCENT, selectcolor=BG, activebackground=BG2, activeforeground=ACCENT,
            font=("Consolas", 9, "bold"), bd=0, padx=6, pady=1, highlightthickness=0,
        ).pack(side=tk.LEFT, padx=1)
        tk.Label(f, text="全", bg=BG, fg=DIM, font=("Consolas", 8)).pack(side=tk.LEFT, padx=(0, 4))
        for k in "EWID":
            self._pill(f, k).pack(side=tk.LEFT, padx=1)
        # Untagged / raw UART lines (no E/W/I/D prefix)
        tk.Checkbutton(
            f, text="—", variable=self.lvl_raw, command=self._on_lvl_click,
            bg=BG2, fg=GRAY, selectcolor=BG, activebackground=BG2, activeforeground=GRAY,
            font=("Consolas", 9, "bold"), bd=0, padx=6, pady=1, highlightthickness=0,
        ).pack(side=tk.LEFT, padx=1)
        tk.Label(f, text="无标识", bg=BG, fg=DIM, font=("Consolas", 8)).pack(side=tk.LEFT, padx=(0, 6))
        tk.Checkbutton(f, text="ts", variable=self.show_ts, command=self._redraw, bg=BG, fg=DIM,
                       selectcolor=BG, activebackground=BG, font=("Consolas", 9)).pack(side=tk.LEFT, padx=(10, 2))
        tk.Checkbutton(f, text="scroll", variable=self.autoscroll, bg=BG, fg=DIM,
                       selectcolor=BG, activebackground=BG, font=("Consolas", 9)).pack(side=tk.LEFT, padx=2)
        tk.Checkbutton(f, text="wrap", variable=self.wrap, command=self._set_wrap, bg=BG, fg=DIM,
                       selectcolor=BG, activebackground=BG, font=("Consolas", 9)).pack(side=tk.LEFT, padx=2)
        tk.Label(f, text="log→", bg=BG, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT, padx=(12, 4))
        log_entry = tk.Entry(
            f, textvariable=self.log_dir_var, width=28,
            bg=BG2, fg=DIM, insertbackground=FG, font=("Consolas", 9),
            relief=tk.FLAT, highlightthickness=1, highlightbackground=BORDER,
        )
        log_entry.pack(side=tk.LEFT)
        log_entry.bind("<Return>", self._apply_log_dir_entry)
        log_entry.bind("<FocusOut>", self._apply_log_dir_entry)
        tk.Button(
            f, text="…", command=self._browse_log_dir,
            bg=BG2, fg=FG, activebackground=BORDER,
            font=("Consolas", 9), bd=0, padx=6, pady=1, relief=tk.FLAT,
        ).pack(side=tk.LEFT, padx=(2, 0))
        tk.Label(f, text="/", bg=BG, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT, padx=(12, 4))
        e = tk.Entry(
            f, textvariable=self.filter_var, width=24,
            bg=BG2, fg=FG, insertbackground=FG, font=("Consolas", 10),
            relief=tk.FLAT, highlightthickness=1, highlightbackground=BORDER, highlightcolor=ACCENT,
        )
        e.pack(side=tk.LEFT)
        e.bind("<KeyRelease>", lambda _e: self._redraw())

        # Terminal body
        st = ttk.Style(self.root)
        st.configure("Dark.Vertical.TScrollbar", background=BORDER, troughcolor=BG2, bordercolor=BG, arrowcolor=DIM)
        st.map("Dark.Vertical.TScrollbar", background=[("active", DIM)])
        st.configure("Dark.Horizontal.TScrollbar", background=BORDER, troughcolor=BG2, bordercolor=BG, arrowcolor=DIM)
        st.map("Dark.Horizontal.TScrollbar", background=[("active", DIM)])

        body = tk.Frame(self.root, bg=BORDER)
        body.pack(fill=tk.BOTH, expand=True, padx=1, pady=1)
        self.log = tk.Text(
            body, wrap="none", state=tk.DISABLED,
            bg=LOG_BG, fg=RX_C, insertbackground=FG,
            font=("Cascadia Mono", 11), relief=tk.FLAT,
            padx=10, pady=8, highlightthickness=0,
            spacing1=0, spacing3=0, cursor="xterm",
        )
        ys = ttk.Scrollbar(body, orient=tk.VERTICAL, command=self.log.yview, style="Dark.Vertical.TScrollbar")
        xs = ttk.Scrollbar(body, orient=tk.HORIZONTAL, command=self.log.xview, style="Dark.Horizontal.TScrollbar")
        self.log.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        self.log.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        body.rowconfigure(0, weight=1)
        body.columnconfigure(0, weight=1)

        for t, c in [
            ("ts", TS), ("rx", RX_C), ("tx", TX_C), ("sys", SYS_C), ("err", RED),
            ("E", LVL_E), ("W", LVL_W), ("I", LVL_I), ("D", LVL_D),
            ("raw", GRAY), ("tag", TAG_C), ("hl", YELLOW),
        ]:
            self.log.tag_configure(t, foreground=c)

        # Macros (SecureCRT Button Bar)
        self.macro_bar = tk.Frame(self.root, bg=BG)
        self.macro_bar.pack(fill=tk.X, padx=6, pady=(4, 0))
        self._rebuild_macro_bar()

        # TX/RX options (SSCOM-style)
        opt = tk.Frame(self.root, bg=BG2, pady=3)
        opt.pack(fill=tk.X, padx=1, pady=(2, 0))
        tk.Checkbutton(
            opt, text="HEX显示", variable=self.hex_display, command=self._on_hex_display,
            bg=BG2, fg=DIM, selectcolor=BG, activebackground=BG2, font=("Consolas", 9),
        ).pack(side=tk.LEFT, padx=(8, 2))
        tk.Checkbutton(
            opt, text="HEX发送", variable=self.hex_send,
            bg=BG2, fg=DIM, selectcolor=BG, activebackground=BG2, font=("Consolas", 9),
        ).pack(side=tk.LEFT, padx=2)
        tk.Checkbutton(
            opt, text="加回车换行", variable=self.add_eol,
            bg=BG2, fg=DIM, selectcolor=BG, activebackground=BG2, font=("Consolas", 9),
        ).pack(side=tk.LEFT, padx=2)
        tk.Checkbutton(
            opt, text="定时发送", variable=self.timed_send, command=self._toggle_timed_send,
            bg=BG2, fg=DIM, selectcolor=BG, activebackground=BG2, font=("Consolas", 9),
        ).pack(side=tk.LEFT, padx=(10, 2))
        tk.Entry(
            opt, textvariable=self.timed_ms, width=5,
            bg=BG, fg=FG, insertbackground=FG, font=("Consolas", 9),
            relief=tk.FLAT, highlightthickness=1, highlightbackground=BORDER,
        ).pack(side=tk.LEFT)
        tk.Label(opt, text="ms", bg=BG2, fg=DIM, font=("Consolas", 8)).pack(side=tk.LEFT, padx=(2, 8))
        tk.Label(
            opt, text="接收文件见 ● REC / log-on-connect",
            bg=BG2, fg=DIM, font=("Consolas", 8),
        ).pack(side=tk.RIGHT, padx=10)

        # Input line
        inp = tk.Frame(self.root, bg=BG2)
        inp.pack(fill=tk.X, padx=1, pady=1)
        tk.Label(inp, text=" ❯ ", bg=BG2, fg=GREEN, font=("Cascadia Mono", 12, "bold")).pack(side=tk.LEFT)
        self.entry = tk.Entry(
            inp, textvariable=self.cmd_var, bg=BG2, fg=FG, insertbackground=FG,
            font=("Cascadia Mono", 11), relief=tk.FLAT, highlightthickness=0,
        )
        self.entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 8), pady=6)
        self.entry.bind("<Return>", self._on_send)
        self.entry.bind("<Up>", self._hist_prev)
        self.entry.bind("<Down>", self._hist_next)
        tk.Label(inp, text="eol", bg=BG2, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT)
        eol_menu = tk.OptionMenu(inp, self.eol_var, *LINE_ENDS)
        eol_menu.configure(
            bg=BG2, fg=FG, activebackground=BORDER, activeforeground=FG,
            highlightthickness=1, highlightbackground=BORDER,
            font=("Consolas", 9), bd=0, padx=6, pady=2, indicatoron=False,
        )
        eol_menu["menu"].configure(bg=BG2, fg=FG, activebackground=ACCENT, font=("Consolas", 9))
        eol_menu.pack(side=tk.LEFT, padx=(4, 8))
        tk.Button(
            inp, text="Send ⏎", command=self._on_send,
            bg="#1f6feb", fg="#fff", activebackground="#388bfd",
            font=("Consolas", 10, "bold"), bd=0, padx=12, pady=4, relief=tk.FLAT,
        ).pack(side=tk.LEFT, padx=(0, 8))

        # Status bar
        sb = tk.Frame(self.root, bg=BG2, pady=2)
        sb.pack(fill=tk.X, side=tk.BOTTOM)
        self.stats = tk.Label(sb, text="", bg=BG2, fg=DIM, font=("Consolas", 9))
        self.stats.pack(side=tk.RIGHT, padx=10)
        tk.Label(sb, text=f"{APP_NAME} {APP_VERSION}", bg=BG2, fg=DIM, font=("Consolas", 9)).pack(side=tk.LEFT, padx=10)

    def _on_hex_display(self) -> None:
        self._hex_mode = bool(self.hex_display.get())
        # Defer full re-render so the checkbox click stays snappy
        self.root.after_idle(self._redraw)

    def _rx_text(self, raw: bytes) -> str:
        return raw.hex(" ") if self._hex_mode else raw.decode("utf-8", errors="replace")

    def _item_text(self, kind: str, text) -> str:
        if kind == "rx" and isinstance(text, (bytes, bytearray)):
            return self._rx_text(bytes(text))
        return text if isinstance(text, str) else str(text)

    def _set_wrap(self) -> None:
        self.log.configure(wrap="word" if self.wrap.get() else "none")

    # ── serial ───────────────────────────────────────────────────────────
    def _refresh_ports(self) -> None:
        items = []
        for p in list_ports.comports():
            star = " *" if p.vid in ESPRESSIF_VIDS else ""
            items.append((1 if star else 0, f"{p.device}{star}  {p.description}"))
        items.sort(reverse=True)
        labels = [x[1] for x in items]
        menu = self.port_menu["menu"]
        menu.delete(0, "end")
        self._port_map: dict[str, str] = {}
        for lab in labels:
            short = lab.split()[0] + (" *" if " *" in lab else "")
            self._port_map[short] = lab
            menu.add_command(label=short, command=lambda s=short: self.port_var.set(s))
        if labels:
            pref_full = next((x for x in labels if " *" in x), labels[0])
            # Prefer last used port if still present
            last = getattr(self, "_last_port", "") or ""
            if last:
                for lab in labels:
                    if lab.split()[0] == last:
                        pref_full = lab
                        break
            short = pref_full.split()[0] + (" *" if " *" in pref_full else "")
            self.port_var.set(short)
            self._last_port = short.split()[0]
            try:
                self.port_menu.configure(text=short)
            except tk.TclError:
                pass

    def _port(self) -> str | None:
        v = self.port_var.get()
        if not v or v == "…":
            return None
        return v.split()[0] if v else None

    def _toggle(self) -> None:
        self._disconnect() if self.connected else self._connect()

    def _connect(self) -> None:
        port = self._port()
        if not port:
            messagebox.showinfo("esp-term", "No serial port selected.")
            return
        try:
            baud = int(self.baud_var.get())
        except ValueError:
            return
        self._disconnect()
        try:
            # Configure *before* open: Windows CDC often opens with DTR=1.
            # Writing dtr=False *after* open creates a falling edge that the
            # ESP32 auto-download circuit treats as a reset. Setting the
            # desired idle state first makes open apply DTR=0, RTS=0 with
            # no pulse.
            ser = serial.Serial()
            ser.port = port
            ser.baudrate = baud
            ser.timeout = 0.04
            ser.write_timeout = 2
            ser.rtscts = False
            ser.dsrdtr = False
            ser.dtr = False
            ser.rts = False
            ser.open()
            self.ser = ser
        except serial.SerialException as exc:
            messagebox.showerror("esp-term", str(exc))
            return

        # Do not touch DTR/RTS after open — that can pulse EN / GPIO0.

        self.stop_reader.clear()
        self.reader = threading.Thread(target=self._reader, daemon=True)
        self.reader.start()
        self.connected = True
        self._connected_port = port
        self._link_lost = False
        self.conn_btn.configure(text="Disconnect", style="Stop.TButton")
        self.led.itemconfigure(self._led_id, fill=GREEN)
        self.conn_label.configure(text=f" {port} @ {baud} ", fg=GREEN)
        self._set_rec_enabled(True)
        self._append("sys", f"— connected {port} @ {baud} —")

        # Optional explicit hardware reset — off by default (UI must not
        # silently cycle EN). Use the RST button when you want a reboot.
        if self.reset_on_connect.get():
            self.root.after(50, self._reset)

        # Session logging (SecureCRT: start log upon connect)
        if self.rec_on_connect.get() and not self.recording:
            self._start_rec(auto=True)

        self.entry.focus_set()

    def _disconnect(self) -> None:
        if self.ser:
            try:
                self.ser.close()
            except Exception:  # noqa: BLE001
                pass
        self.ser = None
        self.stop_reader.set()
        if self.connected:
            self._append("sys", "— disconnected —")
        # Session ends → stop logging (file is kept on disk)
        if self.recording:
            self._stop_rec(reason="disconnect")
        if self.timed_send.get():
            self.timed_send.set(False)
            if self._timed_id:
                try:
                    self.root.after_cancel(self._timed_id)
                except Exception:  # noqa: BLE001
                    pass
                self._timed_id = None
        self.connected = False
        self._connected_port = None
        self._link_lost = False
        self.conn_btn.configure(text="Connect", style="Go.TButton")
        self.led.itemconfigure(self._led_id, fill=RED)
        self.conn_label.configure(text=" offline ", fg=DIM)
        self._set_rec_enabled(False)

    def _port_still_present(self, port: str) -> bool:
        try:
            return any(p.device == port for p in list_ports.comports())
        except Exception:  # noqa: BLE001
            return False

    def _check_link(self) -> None:
        """Watchdog: USB unplug / port gone → drop to offline (SecureCRT-like)."""
        if not self.connected or self._link_lost:
            return
        ser = self.ser
        if ser is None or not getattr(ser, "is_open", False):
            self._link_lost = True
            self.rx_q.put(("link", "port closed"))
            return
        # Cheap status first
        try:
            _ = ser.in_waiting
        except Exception:  # noqa: BLE001
            self._link_lost = True
            self.rx_q.put(("link", "port error"))
            return
        # Expensive Windows port scan, rate-limited
        now = time.monotonic()
        if now - self._last_port_scan < LINK_PORT_SCAN_S:
            return
        self._last_port_scan = now
        port = self._connected_port
        if port and not self._port_still_present(port):
            self._link_lost = True
            self.rx_q.put(("link", f"{port} disappeared"))

    def _handle_link_lost(self, reason: str) -> None:
        if not self.connected:
            return
        self._append("err", f"— serial disconnected ({reason}) —")
        try:
            if self.ser:
                self.ser.close()
        except Exception:  # noqa: BLE001
            pass
        self.ser = None
        self.stop_reader.set()
        if self.recording:
            self._stop_rec(reason="link-lost")
        if self.timed_send.get():
            self.timed_send.set(False)
            if self._timed_id:
                try:
                    self.root.after_cancel(self._timed_id)
                except Exception:  # noqa: BLE001
                    pass
                self._timed_id = None
        self.connected = False
        self._connected_port = None
        self._link_lost = False
        self.conn_btn.configure(text="Connect", style="Go.TButton")
        self.led.itemconfigure(self._led_id, fill=RED)
        self.conn_label.configure(text=" offline ", fg=DIM)
        self._set_rec_enabled(False)

    def _reset(self) -> None:
        """Hard reset via DTR/RTS (esptool USB-JTAG-Serial sequence).

        ESP32-S3 native USB-Serial/JTAG is picky: a short RTS pulse often
        does nothing. Use esptool's USBJTAGSerialReset timing; keep DTR
        idle so we do not enter download mode. Runs off the UI thread.
        """
        if not self.ser or not self.ser.is_open:
            self._append("err", "RST requires an open port")
            return
        ser = self.ser
        port = self._connected_port or self._port() or "?"

        def _pulse() -> None:
            try:
                ser.reset_input_buffer()
                ser.dtr = False
                ser.rts = False
                time.sleep(0.05)
                ser.rts = True   # EN low
                time.sleep(0.1)
                ser.rts = False  # EN high
                time.sleep(0.1)
                ser.dtr = False
                ser.rts = False
                self.rx_q.put(("sys", f"— hard reset ({port}) —"))
            except Exception as exc:  # noqa: BLE001
                self.rx_q.put(("err", f"RST failed: {exc}"))

        threading.Thread(target=_pulse, daemon=True).start()

    def _toggle_pause(self) -> None:
        self.paused = not self.paused
        self._append("sys", "— paused —" if self.paused else "— resumed —")

    # ── custom send buttons (SecureCRT Button Bar) ───────────────────────
    def _rebuild_macro_bar(self) -> None:
        for w in self.macro_bar.winfo_children():
            w.destroy()
        for item in self.macros:
            label, cmd = item["label"], item["cmd"]
            tk.Button(
                self.macro_bar, text=label,
                command=lambda c=cmd: self._send(c),
                bg=BG2, fg=DIM, activebackground=BORDER, activeforeground=FG,
                font=("Consolas", 9), bd=0, padx=8, pady=2, relief=tk.FLAT, cursor="hand2",
            ).pack(side=tk.LEFT, padx=2)
        tk.Button(
            self.macro_bar, text="⚙",
            command=self._edit_macros,
            bg=BG2, fg=ACCENT, activebackground=BORDER, activeforeground=FG,
            font=("Consolas", 9), bd=0, padx=8, pady=2, relief=tk.FLAT, cursor="hand2",
        ).pack(side=tk.LEFT, padx=(6, 2))
        tk.Label(self.macro_bar, text="cmds", bg=BG, fg=DIM, font=("Consolas", 8)).pack(side=tk.LEFT, padx=2)

    def _edit_macros(self) -> None:
        win = tk.Toplevel(self.root)
        win.title("Custom commands — Button Bar")
        win.configure(bg=BG)
        win.geometry("520x420")
        win.transient(self.root)
        win.grab_set()

        tk.Label(
            win, text="label | send string   (one per line)",
            bg=BG, fg=DIM, font=("Consolas", 9),
        ).pack(anchor="w", padx=10, pady=(10, 4))

        text = tk.Text(
            win, bg=BG2, fg=FG, insertbackground=FG,
            font=("Consolas", 10), relief=tk.FLAT, highlightthickness=1,
            highlightbackground=BORDER, highlightcolor=ACCENT,
            padx=8, pady=8, height=16,
        )
        text.pack(fill=tk.BOTH, expand=True, padx=10, pady=4)
        # Multi-line format: label | command
        for item in self.macros:
            text.insert("end", f"{item['label']} | {item['cmd']}\n")

        hint = tk.Label(
            win,
            text="Example:  reboot | restart\\nclear | clear\\nstat | status",
            bg=BG, fg=DIM, font=("Consolas", 8), justify=tk.LEFT,
        )
        hint.pack(anchor="w", padx=10, pady=(0, 6))

        bar = tk.Frame(win, bg=BG)
        bar.pack(fill=tk.X, padx=10, pady=(0, 10))

        def apply_and_close() -> None:
            lines = text.get("1.0", "end").splitlines()
            new_macros: list[dict] = []
            for line in lines:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "|" in line:
                    lab, cmd = line.split("|", 1)
                elif " " in line:
                    lab, cmd = line.split(" ", 1)
                else:
                    lab, cmd = line, line
                lab, cmd = lab.strip(), cmd.strip()
                if lab and cmd != "":
                    new_macros.append({"label": lab, "cmd": cmd})
            if new_macros:
                self.macros = new_macros
            else:
                self.macros = [dict(m) for m in DEFAULT_MACROS]
            self._save_cfg()
            self._rebuild_macro_bar()
            self._append("sys", f"— {len(self.macros)} custom cmd(s) saved —")
            win.destroy()

        def reset_defaults() -> None:
            self.macros = [dict(m) for m in DEFAULT_MACROS]
            self._save_cfg()
            self._rebuild_macro_bar()
            text.delete("1.0", "end")
            for item in self.macros:
                text.insert("end", f"{item['label']} | {item['cmd']}\n")

        tk.Button(
            bar, text="Save", command=apply_and_close,
            bg="#1f6feb", fg="#fff", activebackground="#388bfd",
            font=("Consolas", 10, "bold"), bd=0, padx=12, pady=4, relief=tk.FLAT,
        ).pack(side=tk.RIGHT, padx=4)
        tk.Button(
            bar, text="Defaults", command=reset_defaults,
            bg=BG2, fg=FG, activebackground=BORDER,
            font=("Consolas", 9), bd=0, padx=8, pady=4, relief=tk.FLAT,
        ).pack(side=tk.RIGHT, padx=4)
        tk.Button(
            bar, text="Cancel", command=win.destroy,
            bg=BG2, fg=DIM, activebackground=BORDER,
            font=("Consolas", 9), bd=0, padx=8, pady=4, relief=tk.FLAT,
        ).pack(side=tk.RIGHT, padx=4)

    # ── session log (SecureCRT-style: only while connected) ──────────────
    def _set_rec_enabled(self, on: bool) -> None:
        """REC is only available for an active session (like SecureCRT)."""
        if on and not self.recording:
            self.rec_btn.configure(state=tk.NORMAL, text="● REC", bg="#3a2228", fg=RED)
        elif on and self.recording:
            self.rec_btn.configure(state=tk.NORMAL, text="■ STOP", bg="#1f6feb", fg="#fff")
        else:
            self.rec_btn.configure(
                state=tk.DISABLED, text="● REC", bg="#2a2a2a", fg="#666666",
                disabledforeground="#555555",
            )

    def _start_rec(self, auto: bool = False) -> None:
        # SecureCRT: logging is a property of the connected session
        if not self.connected:
            self._append("err", "log requires an active connection")
            return
        if self.recording:
            return
        try:
            self.log_root.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            messagebox.showerror("esp-term", f"Cannot create log dir:\n{self.log_root}\n{exc}")
            return
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        port = self._port() or "port"
        path = self.log_root / f"esp_{port}_{stamp}.log"
        try:
            fp = path.open("w", encoding="utf-8", buffering=1)  # line-buffered, new session
        except OSError as exc:
            messagebox.showerror("esp-term", str(exc))
            return
        with self._rec_lock:
            self._rec_fp = fp
            self.rec_path = path
            self.recording = True
            fp.write(
                f"# esp-term session log\n"
                f"# started={datetime.now().isoformat(timespec='seconds')} "
                f"port={port} baud={self.baud_var.get()} auto={auto}\n"
            )
        self._set_rec_enabled(True)
        self._append("sys", f"— logging → {path.name} —")

    def _stop_rec(self, reason: str = "") -> None:
        with self._rec_lock:
            fp = self._rec_fp
            self._rec_fp = None
            self.recording = False
            path = self.rec_path
        if fp:
            try:
                fp.write(f"# stopped={datetime.now().isoformat(timespec='seconds')} reason={reason}\n")
                fp.flush()
                fp.close()
            except Exception:  # noqa: BLE001
                pass
        self._set_rec_enabled(self.connected)
        if path:
            self._append("sys", f"— log closed {path.name} —")

    def _toggle_rec(self) -> None:
        if not self.connected:
            return
        if self.recording:
            self._stop_rec(reason="manual")
        else:
            self._start_rec()

    def _write_rec(self, kind: str, text: str) -> None:
        """Append to session log while connected (UI pause does not stop file I/O)."""
        if not self.recording:
            return
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        line = f"{ts} [{kind}] {text}\n"
        with self._rec_lock:
            fp = self._rec_fp
            if not fp:
                return
            try:
                fp.write(line)
            except Exception:  # noqa: BLE001
                pass

    def _reader(self) -> None:
        """Read serial; write session log off the UI thread; queue display lines."""
        buf = bytearray()
        while not self.stop_reader.is_set():
            ser = self.ser
            if ser is None or not ser.is_open:
                break
            try:
                chunk = ser.read(4096)
            except (serial.SerialException, OSError, TypeError):
                self.rx_q.put(("link", "serial read error"))
                break
            if not chunk:
                continue
            self.rx_bytes += len(chunk)
            self.rate_window.append((time.monotonic(), len(chunk)))
            buf.extend(chunk)
            while True:
                n = buf.find(b"\n")
                r = buf.find(b"\r")
                if n < 0 and r < 0:
                    break
                if n < 0:
                    idx, skip = r, 1
                elif r < 0:
                    idx, skip = n, 1
                else:
                    if r + 1 == n:
                        idx, skip = r, 2
                    elif n < r:
                        idx, skip = n, 1
                    else:
                        idx, skip = r, 1
                raw = bytes(buf[:idx])
                del buf[: idx + skip]
                # Disk log: decode now; UI: keep raw bytes for HEX toggle
                if self._hex_mode:
                    self._write_rec("rx", raw.hex(" "))
                else:
                    self._write_rec("rx", raw.decode("utf-8", errors="replace"))
                self.rx_q.put(("rx", raw))

    def _pump(self) -> None:
        """Apply at most MAX_UI_BATCH lines per tick (keeps UI responsive)."""
        batch: list[tuple[str, str]] = []
        link_msg = None
        try:
            while len(batch) < MAX_UI_BATCH:
                kind, text = self.rx_q.get_nowait()
                if kind == "link":
                    link_msg = text
                    break
                # rx is already a display string from the reader thread
                if kind == "rx" and isinstance(text, (bytes, bytearray)):
                    raw = bytes(text)
                    text = raw.hex(" ") if self.hex_display.get() else raw.decode(
                        "utf-8", errors="replace"
                    )
                batch.append((kind, text))
        except queue.Empty:
            pass

        if link_msg is not None:
            self._handle_link_lost(link_msg)

        if batch:
            self._apply_batch(batch)
        # Drain rest quickly if queue is still full (next tick soon)
        backlog = self.rx_q.qsize()
        delay = 15 if backlog > MAX_UI_BATCH else 50
        self._pump_id = self.root.after(delay, self._pump)

    def _apply_batch(self, batch: list[tuple[str, str]]) -> None:
        show_ts = self.show_ts.get()
        q = self.filter_var.get().strip()
        qlow = q.lower() if q else ""
        hex_mode = self.hex_display.get()
        lvl_all = self.lvl_all.get()
        lvl_raw = self.lvl_raw.get()
        lvl = {k: v.get() for k, v in self.lvl.items()}
        paused = self.paused

        inserted = 0
        self.log.configure(state=tk.NORMAL)
        for kind, text in batch:
            if kind == "rx":
                raw = bytes(text) if isinstance(text, (bytes, bytearray)) else text.encode("utf-8", errors="replace")
                self._all.append(("rx", raw))
                text = self._rx_text(raw)
            else:
                self._write_rec(kind, text)
                self._all.append((kind, text))
            if paused and kind == "rx":
                continue
            # filter
            if q and qlow not in text.lower():
                continue
            if kind == "rx":
                if not lvl_all:
                    m = LEVEL_RE.match(text)
                    lv = m.group(1) if m else None
                    if lv and lv in lvl:
                        if not lvl[lv]:
                            continue
                    elif not lvl_raw:
                        continue
            tag = kind
            if kind == "rx":
                m = LEVEL_RE.match(text)
                if m and m.group(1) in lvl:
                    tag = m.group(1)
                else:
                    tag = "raw"
            if show_ts:
                ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
                self.log.insert(tk.END, f"{ts}  ", "ts")
            if q:
                # only highlight when filter is short; high-rate path skips complex split
                if len(text) < 400:
                    low = text.lower()
                    i = 0
                    while True:
                        j = low.find(qlow, i)
                        if j < 0:
                            self.log.insert(tk.END, text[i:], tag)
                            break
                        self.log.insert(tk.END, text[i:j], tag)
                        self.log.insert(tk.END, text[j : j + len(q)], "hl")
                        i = j + len(q)
                else:
                    self.log.insert(tk.END, text, tag)
            else:
                self.log.insert(tk.END, text, tag)
            self.log.insert(tk.END, "\n")
            inserted += 1
        self.log.configure(state=tk.DISABLED)
        if inserted:
            self._trim_text_widget()
            if self.autoscroll.get():
                self.log.see(tk.END)

    def _tick(self) -> None:
        self._check_link()
        now = time.monotonic()
        while self.rate_window and now - self.rate_window[0][0] > 1.0:
            self.rate_window.popleft()
        rate = sum(n for _, n in self.rate_window)
        state = "ON " if self.connected else "OFF"
        self.stats.configure(
            text=f"{state}  rx {_fmt(self.rx_bytes)}  tx {_fmt(self.tx_bytes)}  {_fmt(rate)}/s  n={len(self._all)}"
            + ("  ●REC" if self.recording else "")
        )
        self._tick_id = self.root.after(800, self._tick)

    # ── log ──────────────────────────────────────────────────────────────
    def _level(self, text: str):
        m = LEVEL_RE.match(text)
        return (m.group(1), m.group(3).strip()) if m else (None, None)

    def _ok(self, kind: str, text: str) -> bool:
        q = self.filter_var.get().strip().lower()
        if q and q not in text.lower():
            return False
        if kind != "rx":
            return True
        # 全接收: every RX line, including ones without E/W/I/D prefix
        if self.lvl_all.get():
            return True
        lv, _ = self._level(text)
        if lv and lv in self.lvl:
            return self.lvl[lv].get()
        # Untagged line (raw UART / printf / boot ROM) — own switch
        return self.lvl_raw.get()

    def _append(self, kind: str, text: str) -> None:
        # UI-only lines (sys/tx) also go to the live log file
        if kind != "rx":
            self._write_rec(kind, text)
        self._all.append((kind, text))  # deque(maxlen) drops oldest automatically
        if self._ok(kind, text):
            self._draw(kind, text)
            self._trim_text_widget()

    def _trim_text_widget(self) -> None:
        """Drop oldest lines from the Text widget when it grows past MAX_LOG_LINES."""
        try:
            end_line = int(float(self.log.index("end-1c")))
        except tk.TclError:
            return
        if end_line <= self._trim_at + 80:
            return
        keep_from = end_line - self._trim_at
        self.log.configure(state=tk.NORMAL)
        self.log.delete("1.0", f"{keep_from}.0")
        self.log.configure(state=tk.DISABLED)

    def _draw(self, kind: str, text: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        tag = kind
        tagname = None
        if kind == "rx":
            lv, tagname = self._level(text)
            if lv in self.lvl:
                tag = lv
            else:
                tag = "raw"  # no E/W/I/D prefix
        self.log.configure(state=tk.NORMAL)
        if self.show_ts.get():
            self.log.insert(tk.END, f"{ts}  ", "ts")
        q = self.filter_var.get().strip()
        if q:
            low, needle, i = text.lower(), q.lower(), 0
            while True:
                j = low.find(needle, i)
                if j < 0:
                    self.log.insert(tk.END, text[i:], tag)
                    break
                self.log.insert(tk.END, text[i:j], tag)
                self.log.insert(tk.END, text[j:j + len(q)], "hl")
                i = j + len(q)
        else:
            self.log.insert(tk.END, text, tag)
        if tagname and f" {tagname}:" in f" {text}":
            pass  # keep single-tag coloring simple
        self.log.insert(tk.END, "\n")
        self.log.configure(state=tk.DISABLED)
        if self.autoscroll.get():
            self.log.see(tk.END)

    def _redraw(self) -> None:
        """Fast full re-render (used after filter / HEX / level changes)."""
        wrap = "word" if self.wrap.get() else "none"
        show_ts = self.show_ts.get()
        q = self.filter_var.get().strip()
        qlow = q.lower() if q else ""
        lvl_all = self.lvl_all.get()
        lvl_raw = self.lvl_raw.get()
        lvl = {k: v.get() for k, v in self.lvl.items()}

        self.log.configure(state=tk.NORMAL, wrap=wrap)
        self.log.delete("1.0", tk.END)
        # Avoid per-line see() during rebuild
        for kind, payload in self._all:
            text = self._item_text(kind, payload)
            if q and qlow not in text.lower():
                continue
            if kind == "rx" and not lvl_all:
                m = LEVEL_RE.match(text)
                lv = m.group(1) if m else None
                if lv and lv in lvl:
                    if not lvl[lv]:
                        continue
                elif not lvl_raw:
                    continue
            tag = kind
            if kind == "rx":
                m = LEVEL_RE.match(text)
                tag = m.group(1) if (m and m.group(1) in lvl) else "raw"
            if show_ts:
                self.log.insert(tk.END, f"{datetime.now().strftime('%H:%M:%S.%f')[:-3]}  ", "ts")
            self.log.insert(tk.END, text, tag)
            self.log.insert(tk.END, "\n")
        self.log.configure(state=tk.DISABLED)
        if self.autoscroll.get():
            self.log.see(tk.END)

    def _save(self) -> None:
        path = filedialog.asksaveasfilename(
            defaultextension=".log",
            filetypes=[("Log", "*.log"), ("Text", "*.txt"), ("All", "*.*")],
            initialfile=f"esp_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log",
        )
        if not path:
            return
        lines = [self._item_text(k, t) for k, t in self._all]
        Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._append("sys", f"— saved {len(self._all)} → {Path(path).name} —")

    def _clear(self) -> None:
        self._all.clear()
        self.log.configure(state=tk.NORMAL)
        self.log.delete("1.0", tk.END)
        self.log.configure(state=tk.DISABLED)

    # ── send ─────────────────────────────────────────────────────────────
    def _eol(self) -> bytes:
        if not self.add_eol.get():
            return b""
        return {"LF": b"\n", "CRLF": b"\r\n", "None": b""}.get(self.eol_var.get(), b"\n")

    def _send(self, text: str) -> None:
        self.cmd_var.set(text)
        self._on_send()

    @staticmethod
    def _parse_hex_payload(text: str) -> bytes | None:
        """Parse 'AA BB 0D0A' / 'AA,BB' / 'aabb' into bytes. None if invalid."""
        cleaned = re.sub(r"[^0-9a-fA-F]", "", text)
        if not cleaned or len(cleaned) % 2:
            return None
        try:
            return bytes.fromhex(cleaned)
        except ValueError:
            return None

    def _toggle_timed_send(self) -> None:
        if self.timed_send.get():
            if not self.connected:
                self._append("err", "timed send requires connection")
                self.timed_send.set(False)
                return
            try:
                ms = max(50, int(self.timed_ms.get()))
            except ValueError:
                ms = 1000
                self.timed_ms.set("1000")
            self._append("sys", f"— timed send every {ms} ms —")
            self._schedule_timed(ms)
        else:
            if self._timed_id:
                try:
                    self.root.after_cancel(self._timed_id)
                except Exception:  # noqa: BLE001
                    pass
                self._timed_id = None
            self._append("sys", "— timed send off —")

    def _schedule_timed(self, ms: int) -> None:
        if not self.timed_send.get() or not self.connected:
            self.timed_send.set(False)
            self._timed_id = None
            return
        self._on_send(keep_input=True)
        self._timed_id = self.root.after(ms, lambda: self._schedule_timed(ms))

    def _on_send(self, _e=None, keep_input: bool = False):
        text = self.cmd_var.get()
        if not text:
            return "break"
        if not self.ser or not self.ser.is_open:
            self._append("err", "not connected")
            return "break"

        if self.hex_send.get():
            payload = self._parse_hex_payload(text)
            if payload is None:
                self._append("err", "invalid hex (need even digits, e.g. AA 0D 0A)")
                return "break"
            data = payload
            show = "TX[hex] " + data.hex(" ")
        else:
            data = text.encode("utf-8") + self._eol()
            show = f"❯ {text}"

        try:
            self.ser.write(data)
            self.ser.flush()
        except Exception as exc:  # noqa: BLE001
            self._append("err", f"tx fail: {exc}")
            return "break"
        self.tx_bytes += len(data)
        self._append("tx", show)
        if not keep_input:
            self.hist.append(text)
            self.hist_idx = len(self.hist)
            self.cmd_var.set("")
        return "break"

    def _hist_prev(self, _e=None):
        if not self.hist:
            return "break"
        self.hist_idx = max(0, self.hist_idx - 1)
        self.cmd_var.set(self.hist[self.hist_idx])
        return "break"

    def _hist_next(self, _e=None):
        if not self.hist:
            return "break"
        self.hist_idx = min(len(self.hist), self.hist_idx + 1)
        self.cmd_var.set(self.hist[self.hist_idx] if self.hist_idx < len(self.hist) else "")
        return "break"

    def _on_close(self) -> None:
        if self.timed_send.get():
            self.timed_send.set(False)
            if self._timed_id:
                try:
                    self.root.after_cancel(self._timed_id)
                except Exception:  # noqa: BLE001
                    pass
                self._timed_id = None
        self._disconnect()
        if self.recording:
            self._stop_rec(reason="exit")
        # Persist session prefs (baud/port/layout/macros/...)
        self._save_cfg()
        for after_id in (self._pump_id, self._tick_id):
            if after_id:
                try:
                    self.root.after_cancel(after_id)
                except Exception:  # noqa: BLE001
                    pass
        self._pump_id = self._tick_id = None
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    SerialTerminal(root)
    root.mainloop()


if __name__ == "__main__":
    main()
