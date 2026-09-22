@echo off
setlocal
set "APP_DIR=%~dp0"
set "VENV=%APP_DIR%build\venv\Scripts\python.exe"
if not exist "%VENV%" (
  echo [build] venv missing. Creating...
  "C:\Espressif\tools\python\v5.5.4\venv\Scripts\python.exe" -m venv "%APP_DIR%build\venv"
  "%VENV%" -m pip install --upgrade pip -q
  "%VENV%" -m pip install pyinstaller pyserial -q
)
echo [build] PyInstaller onefile (windowed)...
"%VENV%" -m PyInstaller --noconfirm --clean --windowed --onefile ^
  --name esp-term ^
  --distpath "%APP_DIR%dist" ^
  --workpath "%APP_DIR%build\pyi" ^
  --specpath "%APP_DIR%" ^
  --paths "%APP_DIR%" ^
  --hidden-import serial ^
  --hidden-import serial.tools.list_ports ^
  --collect-all serial ^
  "%APP_DIR%esp_term.py"
if errorlevel 1 (
  echo [build] FAILED
  exit /b 1
)
echo [build] OK -> %APP_DIR%dist\esp-term.exe
endlocal
