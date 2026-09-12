#!/usr/bin/env python3
"""Capture ESP-IDF serial logs without an interactive TTY.

Examples:
  serial_log.py                     # auto-detect Espressif port, 15s capture
  serial_log.py -p COM3 -t 30       # fixed port, 30s
  serial_log.py -p COM3 --reset -t 20
  serial_log.py --list              # list candidate ports
"""

from __future__ import annotations

import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    print("pyserial not found. Activate ESP-IDF python venv first.", file=sys.stderr)
    sys.exit(1)


ESPRESSIF_VIDS = {0x303A, 0x10C4, 0x1A86, 0x0403}


def list_candidate_ports():
    ports = []
    for p in list_ports.comports():
        vid = p.vid
        score = 0
        if vid in ESPRESSIF_VIDS:
            score += 10
        name = (p.description or "") + " " + (p.hwid or "")
        if "JTAG" in name.upper() or "USB" in name.upper():
            score += 2
        if score:
            ports.append((score, p.device, p.description, p.hwid, vid))
    ports.sort(reverse=True)
    return ports


def pick_port() -> str:
    ports = list_candidate_ports()
    if not ports:
        all_ports = [(0, p.device, p.description, p.hwid, p.vid) for p in list_ports.comports()]
        if not all_ports:
            raise SystemExit("No serial ports found.")
        return all_ports[0][1]
    return ports[0][1]


def hard_reset(port: serial.Serial) -> None:
    """Pulse DTR/RTS like esptool default_reset (USB-Serial/JTAG friendly)."""
    try:
        port.dtr = False
        port.rts = True
        time.sleep(0.1)
        port.rts = False
        time.sleep(0.1)
    except Exception as exc:  # noqa: BLE001 - reset is best-effort
        print(f"[serial_log] reset warning: {exc}", file=sys.stderr)


def capture(
    port: str,
    duration: float,
    baud: int,
    do_reset: bool,
    out_path: Path | None,
    raw: bool,
) -> int:
    ser = serial.Serial()
    ser.port = port
    ser.baudrate = baud
    ser.timeout = 0.2
    ser.rtscts = False
    ser.dsrdtr = False

    try:
        ser.open()
    except serial.SerialException as exc:
        print(f"Failed to open {port}: {exc}", file=sys.stderr)
        return 1

    if do_reset:
        hard_reset(ser)

    start = time.monotonic()
    deadline = start + duration
    lines: list[str] = []
    buf = bytearray()

    print(f"[serial_log] listening {port} @ {baud} for {duration:.0f}s", flush=True)

    try:
        while time.monotonic() < deadline:
            chunk = ser.read(4096)
            if not chunk:
                continue
            buf.extend(chunk)
            if not raw:
                while True:
                    idx = buf.find(b"\n")
                    if idx < 0:
                        break
                    line = bytes(buf[:idx]).decode("utf-8", errors="replace").rstrip("\r")
                    del buf[: idx + 1]
                    text = f"{time.monotonic() - start:7.3f}s | {line}"
                    lines.append(text)
                    print(text, flush=True)
            else:
                text = chunk.decode("utf-8", errors="replace")
                lines.append(text)
                print(text, end="", flush=True)
    except KeyboardInterrupt:
        print("\n[serial_log] interrupted", flush=True)
    finally:
        try:
            ser.close()
        except Exception:  # noqa: BLE001
            pass

    if buf and not raw:
        tail = bytes(buf).decode("utf-8", errors="replace")
        if tail:
            lines.append(tail)
            print(tail, flush=True)

    if out_path is not None:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        header = (
            f"# serial_log {datetime.now().isoformat(timespec='seconds')}\n"
            f"# port={port} baud={baud} duration={duration}s reset={do_reset}\n"
        )
        out_path.write_text(header + "\n".join(lines) + "\n", encoding="utf-8")
        print(f"[serial_log] saved {len(lines)} lines -> {out_path}", flush=True)

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Capture ESP-IDF serial logs (non-interactive).")
    ap.add_argument("-p", "--port", help="Serial port, e.g. COM3 or /dev/ttyUSB0")
    ap.add_argument("-t", "--time", type=float, default=15.0, help="Capture seconds (default 15)")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="Baud rate (default 115200)")
    ap.add_argument("--reset", action="store_true", help="Pulse DTR/RTS to reset the chip")
    ap.add_argument("-o", "--output", help="Save captured log to this file")
    ap.add_argument("--raw", action="store_true", help="Do not split lines; print raw bytes")
    ap.add_argument("--list", action="store_true", help="List candidate serial ports and exit")
    args = ap.parse_args()

    if args.list:
        ports = list_candidate_ports()
        if not ports:
            ports = [(0, p.device, p.description, p.hwid, p.vid) for p in list_ports.comports()]
        if not ports:
            print("No serial ports found.")
            return 0
        for score, dev, desc, hwid, vid in ports:
            vid_s = f"vid=0x{vid:04X}" if vid else "vid=?"
            print(f"{dev:12} score={score:2}  {desc}  ({hwid})  {vid_s}")
        return 0

    port = args.port or pick_port()
    out_path = Path(args.output) if args.output else None
    return capture(
        port=port,
        duration=args.time,
        baud=args.baud,
        do_reset=args.reset,
        out_path=out_path,
        raw=args.raw,
    )


if __name__ == "__main__":
    sys.exit(main())
