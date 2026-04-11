@echo off
REM ============================================================
REM EchoScript — Download: Borealis-5b-it weights
REM Requires: setup_borealis.bat to be run first.
REM ============================================================
setlocal

set "HF_HOME=c:\var\huggingface"
set "SCRIPT_DIR=%~dp0"
set "VENV_DIR=%SCRIPT_DIR%..\services\borealis\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_borealis.bat first.
    exit /b 1
)

echo [INFO] Downloading Vikhrmodels/Borealis-5b-it ...
echo [INFO] Cache directory: %HF_HOME%
echo.

"%VENV_DIR%\Scripts\python.exe" -c "from huggingface_hub import snapshot_download; snapshot_download('Vikhrmodels/Borealis-5b-it')"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [OK] Borealis-5b-it weights downloaded to %HF_HOME%

endlocal
