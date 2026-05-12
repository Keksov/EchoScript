@echo off
REM ============================================================
REM EchoScript — Setup: Bun orchestrator
REM Installs Bun (if missing) and project dependencies.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%..\..\scripts\env.bat"
set "ORCH_DIR=%SCRIPT_DIR%.."

REM --- Check if bun is available ---
where bun >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Bun not found. Installing ...
    pwsh -ExecutionPolicy Bypass -Command "irm bun.sh/install.ps1 | iex"
    if errorlevel 1 (
        echo [ERROR] Bun installation failed.
        exit /b 1
    )
    echo [INFO] Bun installed. You may need to restart your terminal for PATH changes.
    echo        Then re-run this script.
    exit /b 0
) else (
    echo [INFO] Bun found:
    bun --version
)

REM --- Install dependencies ---
echo [INFO] Installing orchestrator dependencies ...
pushd "%ORCH_DIR%"
bun install
if errorlevel 1 (
    echo [ERROR] bun install failed.
    popd
    exit /b 1
)
popd

echo.
echo [OK] Orchestrator setup complete.
echo      Start with: cd orchestrator ^&^& bun run dev

endlocal