@echo off
REM ============================================================
REM EchoScript — Download: whisper-podlodka-turbo weights
REM Requires: setup_whisper_podlodka.bat to be run first.
REM ============================================================
setlocal

set "HF_HOME=c:\var\huggingface"
set "SCRIPT_DIR=%~dp0"
set "VENV_DIR=%SCRIPT_DIR%..\services\whisper_podlodka\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_whisper_podlodka.bat first.
    exit /b 1
)

echo [INFO] Downloading bond005/whisper-podlodka-turbo ...
echo [INFO] Cache directory: %HF_HOME%
echo.

"%VENV_DIR%\Scripts\python.exe" -c "from huggingface_hub import snapshot_download; snapshot_download('bond005/whisper-podlodka-turbo')"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [OK] whisper-podlodka-turbo weights downloaded to %HF_HOME%

endlocal
