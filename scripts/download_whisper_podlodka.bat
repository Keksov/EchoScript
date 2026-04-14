@echo off
REM ============================================================
REM EchoScript — Download: whisper-podlodka-turbo weights
REM Requires: setup_whisper_podlodka.bat to be run first.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\services\whisper_podlodka\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_whisper_podlodka.bat first.
    exit /b 1
)

echo [INFO] Downloading bond005/whisper-podlodka-turbo ...
echo [INFO] Cache directory: %HF_HUB_CACHE%
echo.

"%VENV_DIR%\Scripts\python.exe" -c "import os; from huggingface_hub import snapshot_download; snapshot_download('bond005/whisper-podlodka-turbo', cache_dir=os.environ['HF_HUB_CACHE'])"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [OK] whisper-podlodka-turbo weights downloaded to %HF_HUB_CACHE%

endlocal
