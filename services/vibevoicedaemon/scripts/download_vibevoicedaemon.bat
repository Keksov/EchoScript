@echo off
REM ============================================================
REM EchoScript — Download: vibevoicedaemon weights
REM Requires: setup_vibevoicedaemon.bat to be run first.
REM Downloads:
REM   - microsoft/VibeVoice-ASR
REM   - Qwen/Qwen2.5-7B (vendor demo tokenizer dependency)
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_vibevoicedaemon.bat first.
    exit /b 1
)

echo [INFO] Downloading vibevoicedaemon model dependencies ...
echo [INFO] Cache directory: %HF_HUB_CACHE%
echo [INFO] Models:
echo        - microsoft/VibeVoice-ASR
echo        - Qwen/Qwen2.5-7B
echo.

"%VENV_DIR%\Scripts\python.exe" -c "import os; from huggingface_hub import snapshot_download; cache_dir = os.environ['HF_HUB_CACHE']; snapshot_download('microsoft/VibeVoice-ASR', cache_dir=cache_dir); snapshot_download('Qwen/Qwen2.5-7B', cache_dir=cache_dir)"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [OK] VibeVoice-ASR and Qwen/Qwen2.5-7B downloaded to %HF_HUB_CACHE%

endlocal