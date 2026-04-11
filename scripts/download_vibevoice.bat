@echo off
REM ============================================================
REM EchoScript — Download: VibeVoice-ASR weights
REM Requires: setup_vibevoice.bat to be run first.
REM ============================================================
setlocal

set "HF_HOME=c:\var\huggingface"
set "SCRIPT_DIR=%~dp0"
set "VENV_DIR=%SCRIPT_DIR%..\services\vibevoice\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_vibevoice.bat first.
    exit /b 1
)

echo [INFO] Downloading microsoft/VibeVoice-ASR ...
echo [INFO] Cache directory: %HF_HOME%
echo.

"%VENV_DIR%\Scripts\python.exe" -c "from huggingface_hub import snapshot_download; snapshot_download('microsoft/VibeVoice-ASR')"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [OK] VibeVoice-ASR weights downloaded to %HF_HOME%

endlocal
