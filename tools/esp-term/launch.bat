@echo off
setlocal EnableExtensions
REM Prefer pythonw (no console). Double-click flash: use launch.vbs instead.
set "APP_DIR=%~dp0"
set "PY="

set "VENV_PYW=C:\Espressif\tools\python\v5.5.4\venv\Scripts\pythonw.exe"
set "VENV_PY=C:\Espressif\tools\python\v5.5.4\venv\Scripts\python.exe"
set "SYS_PYW=C:\Espressif\tools\python\pythonw.exe"

if exist "%VENV_PYW%" (
  set "PY=%VENV_PYW%"
) else if exist "%SYS_PYW%" (
  set "PY=%SYS_PYW%"
) else if exist "%VENV_PY%" (
  set "PY=%VENV_PY%"
) else (
  for /f "delims=" %%I in ('where pythonw 2^>nul') do if not defined PY set "PY=%%I"
)
if not defined PY (
  for /f "delims=" %%I in ('where python 2^>nul') do if not defined PY set "PY=%%I"
)

if not defined PY (
  echo [esp-term] Python not found.
  pause
  exit /b 1
)

start "" "%PY%" "%APP_DIR%esp_term.py" %*
endlocal
exit /b 0
