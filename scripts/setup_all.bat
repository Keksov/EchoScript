@echo off
REM ============================================================
REM EchoScript — Setup all services and orchestrator
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"

echo ============================================================
echo  EchoScript — Full Setup
echo ============================================================
echo.

echo --- [1/5] Orchestrator (Bun) ---
call "%SCRIPT_DIR%setup_orchestrator.bat"
if errorlevel 1 echo [WARN] Orchestrator setup had issues. & echo.

echo --- [2/5] Whisper Podlodka ---
call "%SCRIPT_DIR%setup_whisper_podlodka.bat"
if errorlevel 1 echo [WARN] whisper_podlodka setup had issues. & echo.

echo --- [3/5] Borealis ---
call "%SCRIPT_DIR%setup_borealis.bat"
if errorlevel 1 echo [WARN] borealis setup had issues. & echo.

echo --- [4/5] Gemma4 ---
call "%SCRIPT_DIR%setup_gemma4.bat"
if errorlevel 1 echo [WARN] gemma4 setup had issues. & echo.

echo --- [5/5] VibeVoice ---
call "%SCRIPT_DIR%setup_vibevoice.bat"
if errorlevel 1 echo [WARN] vibevoice setup had issues. & echo.

echo ============================================================
echo  Setup complete.
echo  Model weights are NOT downloaded yet.
echo  Use scripts\download_*.bat to download models individually.
echo ============================================================

endlocal
