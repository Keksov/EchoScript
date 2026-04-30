@echo off
REM ============================================================
REM EchoScript — Setup all services and orchestrator
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%env.bat"

echo ============================================================
echo  EchoScript — Full Setup
echo ============================================================
echo.

echo --- [1/8] Orchestrator (Bun) ---
call "%SCRIPT_DIR%setup_orchestrator.bat"
if errorlevel 1 echo [WARN] Orchestrator setup had issues. & echo.

echo --- [2/8] Whisper Podlodka ---
call "%SCRIPT_DIR%setup_whisper_podlodka.bat"
if errorlevel 1 echo [WARN] whisper_podlodka setup had issues. & echo.

echo --- [3/8] Borealis ---
call "%SCRIPT_DIR%setup_borealis.bat"
if errorlevel 1 echo [WARN] borealis setup had issues. & echo.

echo --- [4/8] Gemma4 ---
call "%SCRIPT_DIR%setup_gemma4.bat"
if errorlevel 1 echo [WARN] gemma4 setup had issues. & echo.

echo --- [5/8] VibeVoice ---
call "%SCRIPT_DIR%setup_vibevoice.bat"
if errorlevel 1 echo [WARN] vibevoice setup had issues. & echo.

echo --- [6/8] Vosk RU ---
call "%SCRIPT_DIR%setup_vosk_ru.bat"
if errorlevel 1 echo [WARN] vosk_ru setup had issues. & echo.

echo --- [7/8] Vosk RU Command ---
call "%SCRIPT_DIR%setup_vosk_ru_cmd.bat"
if errorlevel 1 echo [WARN] vosk_ru_cmd setup had issues. & echo.

echo --- [8/8] Vosk EN ---
call "%SCRIPT_DIR%setup_vosk_en.bat"
if errorlevel 1 echo [WARN] vosk_en setup had issues. & echo.

echo ============================================================
echo  Setup complete.
echo  Model weights are NOT downloaded yet.
echo  Use scripts\download_*.bat to download models individually.
echo ============================================================

endlocal
