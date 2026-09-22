#!/usr/bin/env python3
"""Backward-compatible launcher — real app lives in tools/esp-term/."""
from __future__ import annotations

import runpy
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent / "esp-term" / "esp_term.py"
if not APP.is_file():
    raise SystemExit(f"esp-term not found: {APP}")
sys.argv[0] = str(APP)
runpy.run_path(str(APP), run_name="__main__")
