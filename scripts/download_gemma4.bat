@echo off
REM ============================================================
REM EchoScript — Download: Gemma 4 E4B weights
REM Requires: setup_gemma4.bat to be run first.
REM NOTE: May require HuggingFace authentication.
REM   Run: venv\Scripts\huggingface-cli.exe login
REM ============================================================
setlocal

set "HF_HOME=c:\var\huggingface"
set "SCRIPT_DIR=%~dp0"
set "VENV_DIR=%SCRIPT_DIR%..\services\gemma4\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_gemma4.bat first.
    exit /b 1
)

echo [INFO] Downloading google/gemma-4-E4B ...
echo [INFO] Cache directory: %HF_HOME%
echo [INFO] If this model requires authentication, run:
echo        %VENV_DIR%\Scripts\huggingface-cli.exe login
echo.

"%VENV_DIR%\Scripts\python.exe" -c "from huggingface_hub import snapshot_download; snapshot_download('google/gemma-4-E4B')"
if errorlevel 1 (
    echo [ERROR] Download failed. You may need to authenticate first.
    exit /b 1
)

echo.
echo [OK] Gemma 4 E4B weights downloaded to %HF_HOME%

endlocal
