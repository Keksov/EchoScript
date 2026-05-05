@echo off
REM ============================================================
REM EchoScript — Download: Borealis-5b-it weights
REM Requires: setup_borealis.bat to be run first.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\..\scripts\env.bat"
set "VENV_DIR=%SCRIPT_DIR%..\venv"

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [ERROR] Virtual environment not found. Run setup_borealis.bat first.
    exit /b 1
)

echo [INFO] Downloading Vikhrmodels/Borealis-5b-it ...
echo [INFO] Cache directory: %HF_HUB_CACHE%
echo.

"%VENV_DIR%\Scripts\python.exe" -c "import os; from huggingface_hub import snapshot_download; snapshot_download('Vikhrmodels/Borealis-5b-it', cache_dir=os.environ['HF_HUB_CACHE'])"
if errorlevel 1 (
    echo [ERROR] Download failed.
    exit /b 1
)

echo.
echo [OK] Borealis-5b-it weights downloaded to %HF_HUB_CACHE%

endlocal